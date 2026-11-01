import AppKit
import CaesuraCore

/// Display selection and placement through NSScreen.
final class ScreenManager {
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var displayCount: Int {
        NSScreen.screens.count
    }

    /// Legacy getTargetDisplay: displayID -1 means "cursor display"; without all
    /// screens, the `screen` setting selects primary/cursor/index.
    func targetDisplay(displayID: Int = -1) -> NSScreen {
        // An isolated run always uses the secondary display and never falls back
        // to the main or to the cursor display.
        if AppPaths.isIsolatedRun {
            // The preflight of an isolated run stops the app when there is no
            // display to use, so this fallback is unreachable — it must never be
            // the cursor display.
            guard let display = SecondaryDisplay.isolatedRunDisplay else {
                Log.error("Caesura: isolated run without a display to use")
                return NSScreen.screens[0]
            }
            return display
        }
        if !settings.getBool("allScreens") {
            let screenSetting = settings.getString("screen")
            if screenSetting == "primary", let primary = NSScreen.screens.first {
                return primary
            }
            if screenSetting == "cursor", let cursor = cursorDisplay() {
                return cursor
            }
            if let index = Int(screenSetting), index >= 0, index < NSScreen.screens.count {
                return NSScreen.screens[index]
            }
        }
        if displayID == -1 {
            return cursorDisplay() ?? NSScreen.main ?? NSScreen.screens[0]
        }
        if displayID >= NSScreen.screens.count || displayID < 0 {
            Log.warn("Caesura: invalid displayID \(displayID), falling back to cursor display")
            return cursorDisplay() ?? NSScreen.screens[0]
        }
        return NSScreen.screens[displayID]
    }

    func cursorDisplay() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }

    func displayBounds(_ displayID: Int = -1) -> CGRect {
        targetDisplay(displayID: displayID).frame
    }

    func displayX(_ displayID: Int = -1, width: CGFloat = 800, fullscreen: Bool = false) -> CGFloat {
        let bounds = displayBounds(displayID)
        if fullscreen {
            return bounds.origin.x
        }
        return floor(bounds.origin.x + (bounds.width - width) / 2)
    }

    func displayY(_ displayID: Int = -1, height: CGFloat = 600, fullscreen: Bool = false) -> CGFloat {
        let bounds = displayBounds(displayID)
        if fullscreen {
            return bounds.origin.y
        }
        return floor(bounds.origin.y + (bounds.height - height) / 2)
    }

    func displayWidth(_ displayID: Int = -1) -> CGFloat {
        floor(displayBounds(displayID).width)
    }

    func displayHeight(_ displayID: Int = -1) -> CGFloat {
        floor(displayBounds(displayID).height)
    }

    /// Legacy getContentDisplayId: -1 = all screens, else the index of the content
    /// screen (or -1 when invalid, which means "all screens").
    func contentDisplayIndex() -> Int {
        let setting = settings.getString("breakContentScreen")
        if setting == "all" { return -1 }
        let target: NSScreen?
        if setting == "primary" {
            target = NSScreen.screens.first
        } else if setting == "cursor" {
            target = cursorDisplay()
        } else {
            target = nil
        }
        let index = target.flatMap { screen in
            NSScreen.screens.firstIndex(where: { candidate in candidate === screen })
        } ?? Int(setting).flatMap { (0...Int.max).contains($0) ? $0 : nil }
        guard let index, index >= 0, index < NSScreen.screens.count else {
            Log.warn("Caesura: invalid breakContentScreen \"\(setting)\", showing break content on all screens")
            return -1
        }
        return index
    }

    /// The screen that carries the break content; `nil` means every screen shows it
    /// (legacy `breakContentScreen: all`).
    func contentDisplayScreen() -> NSScreen? {
        let setting = settings.getString("breakContentScreen")
        if setting == "all" { return nil }
        if setting == "primary" { return NSScreen.screens.first }
        if setting == "cursor" { return cursorDisplay() }
        guard let index = Int(setting), index >= 0, index < NSScreen.screens.count else {
            Log.warn("Caesura: invalid breakContentScreen \"\(setting)\", showing break content on all screens")
            return nil
        }
        return NSScreen.screens[index]
    }

    /// The displays a break is shown on. With `allScreens` disabled the break is shown
    /// on the single display selected by the `screen` setting (legacy breaks out of
    /// its display loop after the first window).
    func targetScreens() -> [NSScreen] {
        // An isolated run shows its breaks on the secondary display only. Without
        // it there is no break window — the display of the user stays untouched.
        if AppPaths.isIsolatedRun {
            return SecondaryDisplay.isolatedRunDisplay.map { [$0] } ?? []
        }
        if settings.getBool("allScreens") {
            return NSScreen.screens
        }
        if NSScreen.screens.count > 1 {
            Log.info("Caesura: not showing on more Monitors as it is disabled.")
        }
        return [targetDisplay()]
    }
}
