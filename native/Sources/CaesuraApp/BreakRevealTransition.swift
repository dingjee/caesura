import AppKit
import CaesuraCore

/// The radial reveal of a break: the shared, short-lived driver that moves
/// every window of one break on ONE global origin, radius and monotonic
/// timeline.
///
/// All participating windows (the content screens and the blank overlays)
/// are masked with the same plan, so a single wave crosses display boundaries
/// instead of restarting on each screen. The centre of the wave is the
/// pointer: it is read once per frame, so the wave follows the cursor while
/// it runs, and every window of the break shares that one centre. The
/// covering radius is measured from the centre again on every frame, so the
/// wave always reaches the last corner of the last display — however far the
/// pointer moved.
///
/// The driver lives only while the wave runs — entry (~900 ms), an optional
/// dismissal tail (~700 ms) and nothing in between — and owns its timer and
/// its mask rasters; everything is disposed when the animation settles (see
/// `settle()` and `finishExit()`). Between the waves there is no timer and no
/// pointer read at all: an idle break costs nothing.
final class BreakRevealDriver {
    /// How a window is revealed: a radial mask for the borderless overlay, a
    /// plain opacity fade where a radial frame would be inappropriate
    /// (regular titled windows) or where the system asks for less movement.
    private enum Style {
        case radial
        case opacity
    }

    /// One window's share of the wave.
    private struct Entry {
        /// The index of the window in the break (the lifecycle probe reports it).
        let index: Int
        let window: BreakWindow
    }

    /// The tail of the last closed break.
    ///
    /// The tail outlives the session that started it: it keeps its windows
    /// alive until the last frame. A new break (or a relayout) discards it at
    /// once, so a stale tail can never touch the windows of the next break.
    private static var pendingTail: BreakRevealDriver?

    /// Discards the tail of the last closed break, if it still runs.
    static func discardPendingTail() {
        pendingTail?.cancel()
        pendingTail = nil
    }

    /// The frames (in the shared global space) of every window that joins the
    /// wave: the covering radius is measured from the centre against them.
    private let targetFrames: [GlobalRect]
    private let style: Style
    private let reduceMotion: Bool
    /// Where the centre of the wave comes from. The default reads the real
    /// pointer; the offscreen probe injects its own, so the behaviour can be
    /// checked without moving the mouse of the user.
    private let pointer: () -> NSPoint
    /// The clock of the animation: monotonic, never the wall clock, so a
    /// network time correction cannot stutter the wave. The offscreen probe
    /// injects its own, so the frames of the wave are deterministic.
    private let now: () -> Int64
    private var entries: [Entry] = []
    private var timer: Timer?
    /// The global centre of the wave: the pointer, read once per frame.
    private var origin: GlobalPoint

    private var phase: Phase = .idle
    private enum Phase {
        case idle
        case entering
        case exiting
    }

    /// The live animation: progress is the eased fraction of the plan radius
    /// (0 = fully hidden, 1 = fully revealed); dismissal starts from wherever
    /// the entry currently is, so an early exit reverses without a flash.
    private var animFrom: Double = 0
    private var animTo: Double = 1
    private var animStartedAt: Int64 = 0
    private var animDurationMillis: Int64 = 0
    /// Settles the driver once the exit tail is done; invoked with the last
    /// frame, after the windows are ordered out and the masks are gone.
    private var exitCompletion: (() -> Void)?
    /// The dismissal outlives the break session that started it (the
    /// coordinator releases the session right after `close()`): the driver
    /// keeps itself — and its windows — alive until the last frame.
    private var selfRetain: BreakRevealDriver?
    /// True once the entry has completed and the masks have been removed.
    private(set) var isSettled = false
    /// True while the tail owns the windows: it orders them out itself.
    private var ownsWindows = false
    /// Reports a window that is about to be discarded (development-only probe).
    var onWindowDiscarded: ((Int, NSWindow) -> Void)?

    /// Captures the plan once: `origin` is the global cursor position read at
    /// presentation, `targetFrames` the frames (in the shared global space) of
    /// every window that joins the wave. The centre is read again on every
    /// frame of the wave, so it follows the pointer from the first frame on.
    init(origin: GlobalPoint, targetFrames: [GlobalRect],
         reduceMotion: Bool, regularWindows: Bool,
         pointer: @escaping () -> NSPoint = { NSEvent.mouseLocation },
         now: @escaping () -> Int64 = { UptimeClock().nowMillis }) {
        self.origin = origin
        self.targetFrames = targetFrames
        self.reduceMotion = reduceMotion
        self.style = (reduceMotion || regularWindows) ? .opacity : .radial
        self.pointer = pointer
        self.now = now
    }

    /// The plan of this frame: the covering radius is measured from the
    /// current centre, so the disc of the wave always reaches the last
    /// corner of the last display.
    private var currentPlan: RadialRevealPlan {
        RadialRevealPlan(origin: origin, targets: targetFrames)
    }

    /// Reads the pointer once: every window of the wave shares this centre.
    private func refreshOrigin() {
        let location = pointer()
        pointerSampleCount &+= 1
        origin = GlobalPoint(x: location.x, y: location.y)
        lastOrigin = origin
    }

    /// The last centre the wave sampled (development-only probe).
    private(set) var lastOrigin: GlobalPoint?
    /// How often the pointer was read since the wave started (development-only
    /// probe): it must grow while the wave runs and stop when it settles.
    private(set) var pointerSampleCount = 0

    /// Adds a window to the wave. The initial (fully hidden) mask is applied
    /// BEFORE the caller orders the window front, so the very first frame is
    /// never an unmasked one.
    func attach(window: BreakWindow, index: Int) {
        let entry = Entry(index: index, window: window)
        entries.append(entry)
        apply(progress: 0, plan: currentPlan, to: entry)
    }

    /// Starts the entry wave.
    func startEntry() {
        guard !entries.isEmpty else { return }
        phase = .entering
        animFrom = 0
        animTo = 1
        animDurationMillis = entryDurationMillis
        animStartedAt = now()
        startTimer()
    }

    /// Whether an exit tail is worth running: false when there is nothing
    /// left to dismiss (already cancelled or no windows).
    var hasLiveWindows: Bool {
        !entries.isEmpty
    }

    /// Begins the exit wave. The countdown and the callbacks of the break
    /// have already stopped; only this visual tail remains. Returns false
    /// when there is nothing to dismiss (the caller discards immediately).
    ///
    /// The tail owns the windows from here on: it keeps them alive, orders
    /// them out with the last frame and reports every discarded window. The
    /// tail reads the pointer again: the wave contracts towards the cursor
    /// where it is now, not where it was when the break opened.
    @discardableResult
    func beginDismissal(completion: @escaping () -> Void) -> Bool {
        guard !entries.isEmpty else { return false }
        // Sample the live progress of the entry first: the dismissal starts
        // from wherever the wave currently is, never from a re-evaluated
        // position (the shared ripple curve maps the same elapsed time to
        // the same radius in both directions, so the reversal is continuous).
        let progress = currentProgress()
        phase = .exiting
        animFrom = progress
        animTo = 0
        animDurationMillis = exitDurationMillis
        animStartedAt = now()
        exitCompletion = completion
        selfRetain = self
        ownsWindows = true
        BreakRevealDriver.pendingTail = self
        startTimer()
        return true
    }

    /// Discards the wave immediately: hot-plug relayouts, cancellations and
    /// immediate next-break creation call this so no stale completion can
    /// ever touch replacement windows.
    ///
    /// The windows the tail owns are ordered out here; the windows of a
    /// running break belong to the session and are ordered out by it.
    func cancel() {
        timer?.invalidate()
        timer = nil
        for entry in entries {
            entry.window.applyRevealMask(maskImage: nil, contentImage: nil)
            entry.window.alphaValue = 1
            if ownsWindows {
                onWindowDiscarded?(entry.index, entry.window)
                entry.window.orderOut(nil)
            }
        }
        entries.removeAll()
        phase = .idle
        exitCompletion = nil
        selfRetain = nil
        ownsWindows = false
        if BreakRevealDriver.pendingTail === self {
            BreakRevealDriver.pendingTail = nil
        }
    }

    // MARK: - Timing

    private var entryDurationMillis: Int64 {
        reduceMotion ? TransitionTokens.smallFeedbackMillis : TransitionTokens.breakEntryMillis
    }

    private var exitDurationMillis: Int64 {
        reduceMotion ? TransitionTokens.smallFeedbackMillis : TransitionTokens.breakExitMillis
    }

    /// The curve of the wave, entering and exiting alike: the dedicated
    /// ripple tween starts and ends at zero velocity, so the radius neither
    /// bursts out of the origin nor pops its last pixels — and one shared
    /// curve for both directions keeps a dismissal sampled from a live
    /// entry continuous (the same progress always maps to the same radius,
    /// whatever the phase).
    private var curve: TransitionCurve {
        .ripple
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick() // the first frame lands with the initial mask, not a beat later
    }

    private func currentProgress() -> Double {
        guard phase != .idle, animDurationMillis > 0 else { return isSettled ? 1 : 0 }
        let t = Double(now() - animStartedAt) / Double(animDurationMillis)
        let eased = curve.value(at: t)
        return animFrom + (animTo - animFrom) * eased
    }

    @objc private func tick() {
        // One read of the pointer per frame: every window of the wave shares
        // this centre, and the covering radius is measured from it again.
        // The plain fade (regular windows, reduced motion) needs no pointer
        // at all.
        if style == .radial { refreshOrigin() }
        apply(progress: currentProgress())
        let done = animDurationMillis <= 0
            || now() - animStartedAt >= animDurationMillis
        guard done else { return }
        // The wave has covered every window: the masks are removed and the
        // timer stops here, so an idle break never reads the pointer again.
        timer?.invalidate()
        timer = nil
        if phase == .exiting {
            finishExit()
        } else {
            settle()
        }
    }

    // MARK: - Frames

    private func apply(progress: Double) {
        let plan = currentPlan
        for entry in entries {
            apply(progress: progress, plan: plan, to: entry)
        }
    }

    private func apply(progress: Double, plan: RadialRevealPlan, to entry: Entry) {
        let clamped = min(max(progress, 0), 1)
        switch style {
        case .opacity:
            entry.window.alphaValue = CGFloat(clamped)
        case .radial:
            let radius = RadialReveal.radius(at: clamped, plan: plan)
            let bounds = entry.window.revealMaskBounds
            // The shared centre, converted into the coordinates of the mask
            // of this window: every window of the wave is centred on the same
            // point of the desktop.
            let global = NSPoint(x: plan.origin.x, y: plan.origin.y)
            let windowPoint = entry.window.convertPoint(fromScreen: global)
            let target = entry.window.revealMaskTarget ?? entry.window.revealContainer
            let localOrigin = target.convert(windowPoint, from: nil)
            guard let image = RadialMaskRaster.image(origin: localOrigin,
                                                     radius: radius,
                                                     feather: CGFloat(plan.feather),
                                                     bounds: bounds) else { return }
            entry.window.applyRevealMask(
                maskImage: NSImage(cgImage: image, size: bounds.size),
                contentImage: image)
        }
    }

    /// The entry has completed: the windows are fully revealed, so the masks
    /// are disposed and the driver goes idle (it keeps no timer, no rasters
    /// and reads no pointer).
    private func settle() {
        phase = .idle
        isSettled = true
        for entry in entries {
            entry.window.applyRevealMask(maskImage: nil, contentImage: nil)
        }
    }

    /// The exit tail has completed: every window is ordered out FIRST — the
    /// session that owned them may already be gone — then the masks are
    /// removed, the retained references are released and the completion runs
    /// last.
    private func finishExit() {
        let completion = exitCompletion
        timer?.invalidate()
        timer = nil
        for entry in entries {
            onWindowDiscarded?(entry.index, entry.window)
            entry.window.orderOut(nil)
        }
        for entry in entries {
            entry.window.applyRevealMask(maskImage: nil, contentImage: nil)
            entry.window.alphaValue = 1
        }
        entries.removeAll()
        phase = .idle
        exitCompletion = nil
        selfRetain = nil
        ownsWindows = false
        if BreakRevealDriver.pendingTail === self {
            BreakRevealDriver.pendingTail = nil
        }
        completion?()
    }
}
