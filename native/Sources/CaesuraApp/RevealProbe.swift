import AppKit
import SwiftUI
import CaesuraCore

/// Opt-in probe of the radial reveal of the break window (development only).
///
/// The probe drives the **real** driver with an injected pointer and an
/// injected clock, on windows that are never ordered in: nothing shows,
/// nothing is activated, and the mouse of the user is never moved. It checks
/// the rules the reveal has to keep:
///
/// - the centre of the wave is the pointer, read once per frame, and the
///   covering radius is measured from that centre,
/// - the wave follows the pointer while it runs — entering and leaving
///   again,
/// - the wave stops reading the pointer once it settled (an idle break
///   costs nothing),
/// - a wave that is cancelled or discarded never calls back into the break.
enum RevealProbe {
    /// Runs the probe and returns its checks.
    @MainActor
    static func run() -> [String: Any] {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return ["measured": false, "reason": "no display"]
        }
        /// The pointer of the probe: it never touches the real mouse.
        var pointer = NSPoint(x: 120, y: 240)
        var samples = 0
        let pointerProvider: () -> NSPoint = {
            samples += 1
            return pointer
        }
        /// The clock of the probe: the frames of the wave are deterministic.
        var clock: Int64 = 0
        let now: () -> Int64 = { clock }

        let frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        let targetFrames = [GlobalRect(x: frame.origin.x, y: frame.origin.y,
                                       width: frame.width, height: frame.height)]

        // MARK: The entry follows the pointer and stops when it settled

        let entryWindow = BreakWindow(screen: screen, contentRect: frame,
                                      regularWindows: false, fullscreen: false)
        let entry = BreakRevealDriver(origin: GlobalPoint(x: pointer.x, y: pointer.y),
                                      targetFrames: targetFrames,
                                      reduceMotion: false,
                                      regularWindows: false,
                                      pointer: pointerProvider,
                                      now: { clock })
        entry.attach(window: entryWindow, index: 0)
        entry.startEntry()
        let firstSample = entry.pointerSampleCount
        let firstOrigin = entry.lastOrigin

        // The pointer moves: the next frame reads it again, and the centre of
        // the wave is the new point.
        pointer = NSPoint(x: 420, y: 360)
        clock += 100
        PoemProbe.pumpMainRunLoop(seconds: 0.08)
        let samplesAfterMove = entry.pointerSampleCount
        let originAfterMove = entry.lastOrigin

        // The wave runs out: the masks are removed and the timer stops.
        clock += 2_000
        PoemProbe.pumpMainRunLoop(seconds: 0.08)
        let settled = entry.isSettled
        let maskRemoved = entryWindow.revealMaskTarget?.layer?.mask == nil
        let samplesWhenSettled = entry.pointerSampleCount
        PoemProbe.pumpMainRunLoop(seconds: 0.08)
        let samplesWhileIdle = entry.pointerSampleCount

        // MARK: The exit reads the pointer again

        var exitCompleted = false
        pointer = NSPoint(x: 300, y: 300)
        let exitStarted = entry.beginDismissal { exitCompleted = true }
        let samplesAtExitStart = entry.pointerSampleCount
        pointer = NSPoint(x: 200, y: 200)
        clock += 100
        PoemProbe.pumpMainRunLoop(seconds: 0.08)
        let samplesDuringExit = entry.pointerSampleCount
        let originDuringExit = entry.lastOrigin
        clock += 2_000
        PoemProbe.pumpMainRunLoop(seconds: 0.08)
        let samplesAfterExit = entry.pointerSampleCount
        PoemProbe.pumpMainRunLoop(seconds: 0.08)
        let samplesAfterExitIdle = entry.pointerSampleCount
        let maskRemovedAfterTheExit = entryWindow.revealMaskTarget?.layer?.mask == nil

        // MARK: The reader's scroller is masked like every other pixel

        // The break window hosts the real reading viewport (the AppKit bridge)
        // and is never ordered in. The view tree is followed instead of a
        // guess: the scroll view and its scroller must be descendants of the
        // host the reveal mask sits on, so no second surface of the reader can
        // leak past the wave. The wave itself carries the mask onto that host
        // and the cancel of the wave takes it off again.
        let contentWindow = BreakWindow(screen: screen, contentRect: frame,
                                        regularWindows: false, fullscreen: false)
        let controller = PoemFocusController()
        let geometry = PoemFocusGeometry(centers: [100], hasWords: [true], rowUnit: 40, uniform: false)
        let hosted = NSHostingView(rootView: PoemScrollViewport(
            width: frame.width, height: frame.height,
            contentHeight: frame.height * 3,
            followOffset: nil, followAnchorY: nil,
            geometry: geometry, userScrolled: false, initialFraction: nil,
            focusController: controller, contentKey: "probe-scroller",
            content: { Color.clear }))
        contentWindow.setBreakContent(hosted)
        let contentDriver = BreakRevealDriver(
            origin: GlobalPoint(x: pointer.x, y: pointer.y),
            targetFrames: targetFrames, reduceMotion: false, regularWindows: false,
            pointer: pointerProvider, now: { clock })
        // The hidden mask is applied with the attach, before the window would
        // be ordered front — exactly like the break does it.
        contentDriver.attach(window: contentWindow, index: 0)
        let contentMaskDuringTheWave = contentWindow.revealMaskTarget?.layer?.mask != nil
        PoemProbe.pumpMainRunLoop(seconds: 0.08)
        let scrollView = Self.findScrollView(in: hosted)
        let scrollerInsideTheMask: Bool = {
            guard let scrollView else { return false }
            let host = contentWindow.revealMaskTarget
            return Self.isDescendant(scrollView, of: host)
                && scrollView.verticalScroller.map({ Self.isDescendant($0, of: host) }) == true
        }()
        // The overlay presentation is accepted in the hosted tree with the
        // scroller subclass installed (the bridge probe asserts the drawing
        // separately); a demotion to the legacy style would reserve space and
        // shift the poem's measured width.
        scrollView?.scrollerStyle = .overlay
        let overlayScrollerAccepted = scrollView?.scrollerStyle == .overlay
            && scrollView?.verticalScroller is PoemScroller
        contentDriver.cancel()
        let contentMaskRemovedAfterCancel = contentWindow.revealMaskTarget?.layer?.mask == nil

        // MARK: A cancelled wave never calls back

        let cancelledWindow = BreakWindow(screen: screen, contentRect: frame,
                                          regularWindows: false, fullscreen: false)
        let cancelled = BreakRevealDriver(origin: GlobalPoint(x: pointer.x, y: pointer.y),
                                          targetFrames: targetFrames,
                                          reduceMotion: false,
                                          regularWindows: false,
                                          pointer: pointerProvider,
                                          now: { clock })
        cancelled.attach(window: cancelledWindow, index: 0)
        cancelled.startEntry()
        let samplesBeforeCancel = cancelled.pointerSampleCount
        cancelled.cancel()
        clock += 100
        PoemProbe.pumpMainRunLoop(seconds: 0.08)
        let samplesAfterCancel = cancelled.pointerSampleCount

        var cancelledExitCompleted = false
        _ = cancelled.beginDismissal { cancelledExitCompleted = true }
        clock += 2_000
        PoemProbe.pumpMainRunLoop(seconds: 0.08)

        let checks: [String: Any] = [
            "measured": true,
            "entrySampledThePointer": firstSample > 0,
            "entryReadThePointerOnce": firstSample == 1,
            "entryUsedTheInjectedPointer": firstOrigin == GlobalPoint(x: 120, y: 240),
            "entryFollowedThePointer": samplesAfterMove > firstSample
                && originAfterMove == GlobalPoint(x: 420, y: 360),
            "entrySettled": settled,
            "maskRemovedWhenSettled": maskRemoved,
            "noSamplingWhenSettled": samplesWhileIdle == samplesWhenSettled,
            "exitStarted": exitStarted,
            "exitReadThePointerAgain": samplesAtExitStart > samplesWhenSettled,
            "exitFollowedThePointer": samplesDuringExit > samplesAtExitStart
                && originDuringExit == GlobalPoint(x: 200, y: 200),
            "exitCompleted": exitCompleted,
            "noSamplingAfterTheExit": samplesAfterExitIdle == samplesAfterExit,
            "cancelledWaveStopsSampling": samplesAfterCancel == samplesBeforeCancel,
            "cancelledWaveNeverCallsBack": !cancelledExitCompleted,
            "maskRemovedAfterTheExit": maskRemovedAfterTheExit,
            "scrollerInsideTheMask": scrollerInsideTheMask,
            "overlayScrollerAccepted": overlayScrollerAccepted,
            "contentMaskPresentDuringTheWave": contentMaskDuringTheWave,
            "contentMaskRemovedAfterCancel": contentMaskRemovedAfterCancel,
            "pointerSamples": samples,
        ]
        return checks
    }

    /// The scroll view of a hosted tree, if there is one.
    private static func findScrollView(in view: NSView) -> PoemScrollView? {
        if let scroll = view as? PoemScrollView { return scroll }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }

    /// True when `view` is `root` itself or lives in its subtree.
    private static func isDescendant(_ view: NSView, of root: NSView?) -> Bool {
        guard let root else { return false }
        var current: NSView? = view
        while let node = current {
            if node === root { return true }
            current = node.superview
        }
        return false
    }
}
