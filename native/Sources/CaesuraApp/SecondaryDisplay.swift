import AppKit
import CaesuraCore

/// The secondary display.
///
/// An isolated run (`--data-dir` or `CAESURA_NATIVE_DATA_DIR`) places every
/// window of the app on this display, so that the display the user works on is
/// never covered and the app never steals the focus. There is no fallback to the
/// main or to the cursor display: an isolated run without a secondary display
/// stops instead.
enum SecondaryDisplay {
    /// The index of the secondary display in `NSScreen.screens`.
    static let index = 1

    static var screen: NSScreen? {
        let screens = NSScreen.screens
        guard screens.count > index else { return nil }
        return screens[index]
    }

    /// The visible frame of the secondary display.
    static var visibleFrame: NSRect? {
        screen?.visibleFrame
    }

    /// The display an isolated run uses: the secondary display, or — only when the
    /// run explicitly allows it (`CAESURA_NATIVE_TEST_MAIN_DISPLAY`) — the main
    /// display. There is no silent fallback: without the secondary display and
    /// without the explicit opt-in an isolated run has no display to use.
    static var isolatedRunDisplay: NSScreen? {
        if let secondary = screen { return secondary }
        guard AppPaths.allowsMainDisplayInIsolatedRun else { return nil }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Places a window of the given size in the middle of the secondary display.
    static func frame(for size: CGSize, on screen: NSScreen? = nil) -> NSRect? {
        guard let visible = (screen ?? SecondaryDisplay.screen)?.visibleFrame else { return nil }
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        return NSRect(x: visible.midX - width / 2,
                      y: visible.midY - height / 2,
                      width: width, height: height)
    }
}
