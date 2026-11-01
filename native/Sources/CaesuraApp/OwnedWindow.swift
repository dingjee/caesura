import AppKit
import CaesuraCore

/// Owner of an application window (preferences or poem
/// windows).
///
/// It centralises the three rules the app must not get wrong:
///
/// - **The window is never released by AppKit.** `NSWindow.isReleasedWhenClosed`
///   is `true` by default, so AppKit autoreleases the window when it closes. An
///   owner that drops its own strong reference as well — for example from
///   `NSWindowWillCloseNotification` — releases the window twice. The second
///   release happens when the main autorelease pool is drained and takes the whole
///   app down with it (`EXC_BAD_ACCESS` in `objc_autoreleasePoolPop`).
/// - **The window is released only after its close finished.** `NSWindow.close`
///   still uses the window after the close notification was posted, so the release
///   is deferred to the next run loop turn.
/// - **The close observers are removed.** Repeated open/close cycles therefore do
///   not accumulate observers.
final class OwnedWindow {
    let window: NSWindow
    /// Called after the window was closed and released.
    var onClosed: (() -> Void)?
    /// True from the close notification on: the window must not be shown again,
    /// it is released on the next run loop turn.
    private(set) var isClosed = false

    private var observers: [NSObjectProtocol] = []

    init(window: NSWindow) {
        self.window = window
        window.isReleasedWhenClosed = false
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isClosed = true
            self.finishClose()
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        // A window that is already closed is released on the next run loop turn:
        // showing it again would hand a window to the app that is about to go.
        guard !isClosed else { return }
        // An isolated run shows its windows on the secondary display and never
        // activates the app: the display of the user stays untouched.
        if AppPaths.isIsolatedRun {
            guard let display = SecondaryDisplay.isolatedRunDisplay,
                  let frame = SecondaryDisplay.frame(for: window.frame.size, on: display) else {
                Log.error("Caesura: isolated run without a display, the window stays closed")
                return
            }
            window.setFrame(frame, display: false)
            window.orderFrontRegardless()
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closes the window like the close button does. The delegate may refuse the
    /// close (strict break mode), so the caller checks `isVisible` afterwards.
    func close() {
        window.performClose(nil)
    }

    private func finishClose() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.observers.forEach { NotificationCenter.default.removeObserver($0) }
            self.observers.removeAll()
            self.onClosed?()
            self.onClosed = nil
        }
    }
}

/// Weak reference to a window. The lifecycle test uses it to check that a closed
/// window was really released instead of only hidden.
final class WeakWindow {
    weak var window: NSWindow?

    init(_ window: NSWindow) {
        self.window = window
    }
}
