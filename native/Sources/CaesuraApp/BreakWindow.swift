import AppKit
import SwiftUI
import CaesuraCore

/// Native break window: borderless, transparent, non-activating, always-on-top overlay
/// sized relative to its screen (legacy BrowserWindow flags). `showBreaksAsRegularWindows`
/// gives a framed, activatable window instead. One window per screen; non-content
/// screens get blank overlays (legacy `?blank=1`).
final class BreakWindow: NSWindow {
    /// The content of the window: the blurred background is its bottom layer, the
    /// break content is the top one.
    ///
    /// The layers are siblings on purpose. An effect view that is a child of the
    /// break content is drawn *over* it (AppKit draws the subviews of a view above
    /// the view itself), which hides the idea, the countdown and the buttons, and a
    /// nested effect view does not sample the desktop behind the window.
    private let contentContainer = NSView()
    private var visualEffectView: NSVisualEffectView?
    private var breakContentView: NSView?

    convenience init(screen: NSScreen, contentRect: NSRect, regularWindows: Bool, fullscreen: Bool) {
        self.init(contentRect: contentRect,
                  styleMask: regularWindows ? [.titled, .closable] : [.borderless],
                  backing: .buffered, defer: false)
        if !regularWindows {
            isOpaque = false
            backgroundColor = .clear
            level = .popUpMenu
            isMovable = false
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            standardWindowButton(.closeButton)?.isHidden = true
        } else {
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        contentContainer.frame = NSRect(origin: .zero, size: contentRect.size)
        contentContainer.autoresizingMask = [.width, .height]
        contentView = contentContainer
        self.setFrame(contentRect, display: true)
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = false
    }

    override var canBecomeKey: Bool { styleMask.contains(.titled) }
    override var canBecomeMain: Bool { styleMask.contains(.titled) }

    /// The break content of the window, drawn above the blurred background.
    func setBreakContent(_ view: NSView) {
        breakContentView = view
        view.frame = contentContainer.bounds
        view.autoresizingMask = [.width, .height]
        contentContainer.addSubview(view)
        // The first layout happens before the window is ordered front, so that the
        // window never shows an empty frame.
        contentContainer.layoutSubtreeIfNeeded()
    }

    /// Legacy `vibrancy: 'hud'` + `visualEffectState: 'active'` on macOS.
    ///
    /// The effect view is a direct child of the window's content view and sits below
    /// the break content, so that the blurred desktop shows behind the break and the
    /// text and the buttons stay readable on top of it.
    func setBlurredBackground(_ enabled: Bool) {
        guard enabled else {
            visualEffectView?.removeFromSuperview()
            visualEffectView = nil
            return
        }
        guard visualEffectView == nil else { return }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        effect.frame = contentContainer.bounds
        if let breakContentView {
            contentContainer.addSubview(effect, positioned: .below, relativeTo: breakContentView)
        } else {
            contentContainer.addSubview(effect, positioned: .below, relativeTo: nil)
        }
        visualEffectView = effect
        Log.info("Caesura: blurred background enabled for the break window")
    }
}

/// Creates and tears down the windows of one running break; owns the per-break
/// shortcut and manual-await transitions (legacy startMicrobreak/startBreak).
final class BreakSession: NSObject, NSWindowDelegate {
    /// Why a break ended.
    ///
    /// The reasons are kept apart because they mean different things: only a
    /// break that really reached its captured duration may count the poem of
    /// the break as shown. A skipped, postponed or cancelled break ends the
    /// break without counting a showing.
    enum Outcome {
        /// The break is still running.
        case running
        /// The break reached its captured duration.
        case elapsed
        /// The break was ended early by the user (skip, close, shortcut).
        case skipped
        /// The break was postponed.
        case postponed
        /// The break was cancelled (pause, reset, quit).
        case cancelled
    }

    let mini: Bool
    let model: BreakContentView.Model
    /// True when the break may count a showing of the poem. A replay of the
    /// last break shows the same poem again and must not count it twice.
    let countsPoemShowing: Bool
    /// True once the showing of this break was counted.
    private var didCountPoemShowing = false
    /// Why the break ended (`.running` while it runs).
    private(set) var outcome: Outcome = .running
    private(set) var windows: [BreakWindow] = []
    private(set) var states: [BreakWindowState] = []
    /// The states of the windows that show the break content (one per display).
    private(set) var contentStates: [BreakWindowState] = []
    /// The state that drives the break: the first window with content (legacy starts
    /// the break on the first display).
    private(set) var contentState: BreakWindowState?
    /// True while the break waits for a manual finish.
    private(set) var isManualAwait = false
    var onPostpone: (() -> Void)?
    var onSkip: (() -> Void)?
    var onFinish: (() -> Void)? // manual finish / automatic completion
    var onCountdownEnd: (() -> Void)?
    /// Returning `false` prevents the window from closing (legacy strict-mode guard).
    var onCloseRequested: ((BreakSession) -> Bool)?
    /// Development-only probe (lifecycle test): invoked with the window index right
    /// before each window is ordered out in close() and relayout().
    var onWindowDiscarded: ((Int, NSWindow) -> Void)?

    init(mini: Bool, model: BreakContentView.Model, countsPoemShowing: Bool = false) {
        self.mini = mini
        self.model = model
        self.countsPoemShowing = countsPoemShowing
    }

    /// Counts the poem of this break as shown. Only a break that reached its
    /// captured duration is allowed to, and only once — a manual finish that
    /// follows the countdown end must not count a second time.
    ///
    /// Returns true when this call counted the showing.
    @discardableResult
    func commitPoemShowing() -> Bool {
        guard !didCountPoemShowing else { return false }
        guard countsPoemShowing else { return false }
        guard outcome == .running || outcome == .elapsed else { return false }
        didCountPoemShowing = true
        return true
    }

    /// Records why the break ended.
    func end(outcome: Outcome) {
        self.outcome = outcome
    }

    /// `screens` are the displays the break is shown on; `contentScreen` is the display
    /// that carries the break content. `contentScreen == nil` means every screen shows
    /// the content (legacy `breakContentScreen: all`).
    func show(screens: [NSScreen], contentScreen: NSScreen?, settings: SettingsStore) {
        states = []
        presentWindows(screens: screens, contentScreen: contentScreen, settings: settings)
    }

    /// Re-creates the windows after a display layout change (hot-plug). The break
    /// deadline, the countdown and the manual-await phase are preserved: only the
    /// windows are replaced.
    func relayout(screens: [NSScreen], contentScreen: NSScreen?, settings: SettingsStore) {
        // relayout and close overwrite the probes with the windows they discard, so
        // the lifecycle test asserts a release between the steps.
        for (index, window) in windows.enumerated() {
            onWindowDiscarded?(index, window)
            window.delegate = nil
            window.orderOut(nil)
        }
        windows.removeAll()
        // The trimmed states take their countdown timers with them: a repeating
        // timer stays scheduled in the run loop until it is invalidated.
        while states.count > screens.count { states.removeLast().stop() }
        while states.count < screens.count { states.append(BreakWindowState()) }
        presentWindows(screens: screens, contentScreen: contentScreen, settings: settings)
        // The manual-await phase survives a display change.
        if isManualAwait {
            contentStates.forEach { $0.enterManualAwait() }
        }
    }

    private func presentWindows(screens: [NSScreen], contentScreen: NSScreen?, settings: SettingsStore) {
        let regularWindows = settings.getBool("showBreaksAsRegularWindows")
        let allScreens = settings.getBool("allScreens")
        let widthPercent = CGFloat(settings.getDouble("breakWindowWidth"))
        let heightPercent = CGFloat(settings.getDouble("breakWindowHeight"))
        let fullscreen = settings.getBool("fullscreen")

        // Legacy blanks the other screens only when the break is an overlay
        // (not a regular window) and a single content screen was selected.
        let useContentScreen = contentScreen != nil && allScreens && !regularWindows

        contentStates.removeAll()
        contentState = nil

        for (index, screen) in screens.enumerated() {
            let isBlank = useContentScreen && screen !== contentScreen
            let bounds = BreakSession.bounds(for: screen,
                                             widthPercent: widthPercent,
                                             heightPercent: heightPercent,
                                             fullscreen: fullscreen)
            let window = BreakWindow(screen: screen, contentRect: bounds,
                                     regularWindows: regularWindows, fullscreen: fullscreen)
            window.delegate = self
            let state: BreakWindowState
            if index < states.count {
                state = states[index]
            } else {
                state = BreakWindowState()
                states.append(state)
            }
            var windowModel = model
            windowModel.blank = isBlank
            let view = BreakContentView(state: isBlank ? BreakWindowState() : state,
                                        model: windowModel,
                                        onPostpone: { [weak self] in self?.onPostpone?() },
                                        onFinish: { [weak self] in self?.handleFinishButton() })
            if !isBlank {
                // Only the first window with content drives the break (legacy emits
                // the break event on one display only); the others mirror it.
                contentStates.append(state)
                if contentState == nil {
                    contentState = state
                    state.onCountdownEnd = { [weak self] in self?.onCountdownEnd?() }
                }
            }
            let hosting = NSHostingView(rootView: view)
            window.setBreakContent(hosting)
            window.setBlurredBackground(settings.getBool("blurredBackground"))
            window.orderFrontRegardless()
            windows.append(window)
            if !isBlank {
                state.start(model: windowModel)
            }
            Log.info("Caesura: showing window \(index + 1) of \(screens.count)\(isBlank ? " (blank)" : "")")
        }
    }

    static func bounds(for screen: NSScreen, widthPercent: CGFloat, heightPercent: CGFloat,
                       fullscreen: Bool) -> NSRect {
        let screenBounds = screen.frame
        if fullscreen {
            // Cover the screen (legacy macOS used kiosk; covers the same area).
            return screenBounds
        }
        let width = floor(screenBounds.width * widthPercent)
        let height = floor(screenBounds.height * heightPercent)
        return NSRect(x: screenBounds.midX - width / 2,
                      y: screenBounds.midY - height / 2,
                      width: width, height: height)
    }

    /// Legacy prevents closing the break window while the countdown runs in strict mode.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let onCloseRequested else { return true }
        return onCloseRequested(self)
    }

    private func handleFinishButton() {
        if contentState?.manualAwait ?? false {
            onFinish?()
        } else {
            onSkip?()
        }
    }

    /// Legacy `enter-manual-await`: keep windows, show elapsed time and a Finish button.
    /// The transition happens once and reaches every window with content.
    func enterManualAwait() {
        guard !isManualAwait else { return }
        isManualAwait = true
        contentStates.forEach { $0.enterManualAwait() }
        Log.info("Caesura: entering manual finish phase (\(mini ? "Mini" : "Long") break)")
    }

    func close() {
        states.forEach { $0.stop() }
        // relayout and close overwrite the probes with the windows they discard, so
        // the lifecycle test asserts a release between the steps.
        for (index, window) in windows.enumerated() {
            onWindowDiscarded?(index, window)
            window.delegate = nil
            window.orderOut(nil)
        }
        windows.removeAll()
        states.removeAll()
        contentStates.removeAll()
        contentState = nil
        isManualAwait = false
    }

    var hasVisibleWindow: Bool {
        windows.contains { $0.isVisible }
    }
}
