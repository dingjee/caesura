import AppKit
import CaesuraCore

/// NSStatusItem + menu, porting legacy updateTray/getTrayMenuTemplate/updateToolTip.
final class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    /// The tooltip of the menu bar item: the app owns it, so it never floats
    /// over another application.
    private let tooltip = StatusItemTooltip()
    private let settings: SettingsStore
    private let localization: Localization
    private let planner: BreaksPlanner
    var actions: MenuActions?
    var isNewVersion = false
    private var refreshTimer: Timer?
    private var darkAppearanceObserver: NSObjectProtocol?
    /// Set while the "menu bar item not drawn" warning is active, so the crowded
    /// menu bar is logged on transition only (refresh runs every 10s).
    private var menuBarItemNotDrawnWarned = false
    /// The place of the menu bar item, as it was logged the last time.
    private var loggedAnchor: NSRect = .zero

    struct MenuActions {
        var skipToMicrobreak: () -> Void
        var skipToBreak: () -> Void
        var pauseBreaks: (Int64) -> Void
        var resumeBreaks: () -> Void
        var resetBreaks: () -> Void
        var openPreferences: () -> Void
        var showTodaysPoem: () -> Void
        var quit: () -> Void
        var openDownloads: () -> Void
    }

    init(settings: SettingsStore, localization: Localization, planner: BreaksPlanner) {
        self.settings = settings
        self.localization = localization
        self.planner = planner
        super.init()
        darkAppearanceObserver = DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshIcon()
        }
    }

    deinit {
        if let darkAppearanceObserver {
            DistributedNotificationCenter.default.removeObserver(darkAppearanceObserver)
        }
    }

    /// The appearance of the menu bar the icon lives in.
    ///
    /// The icon has to follow the menu bar, not the appearance of the app: the
    /// app can run in the light appearance (the Appearance setting) while the
    /// menu bar of the system stays dark — an icon drawn for a light menu bar
    /// would be a black mark in a row of white ones.
    private var systemUsesDarkAppearance: Bool {
        let appearance = statusItem?.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func trayIconUseDarkColors() -> Bool {
        let source = settings.getString("trayIconThemeSource")
        if source == "light" { return false }
        if source == "dark" { return true }
        return systemUsesDarkAppearance
    }

    func refresh() {
        // Legacy hides the dock icon defensively on every update (LSUIElement app).
        NSApp.setActivationPolicy(.accessory)

        if !settings.getBool("showTrayIcon") {
            remove()
            return
        }
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem?.button?.imagePosition = .imageOnly
            // Legacy: click opens the context menu, double click opens preferences.
            statusItem?.button?.target = self
            statusItem?.button?.action = #selector(statusItemClicked(_:))
            statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            let menu = NSMenu()
            menu.delegate = self
            statusItem?.menu = menu
        }
        if let item = statusItem {
            if !item.isVisible {
                Log.info("Caesura: restoring hidden menu bar item")
                item.isVisible = true
            }
            if item.button?.isHidden == true {
                Log.info("Caesura: unhiding menu bar button")
                item.button?.isHidden = false
            }
            // Per Apple, isVisible stays true when the menu bar lacks space, so this
            // state is logged only — the item is never rebuilt or removed here.
            let windowDrawn = item.button?.window?.isVisible == true
            if item.isVisible, !windowDrawn, !menuBarItemNotDrawnWarned {
                menuBarItemNotDrawnWarned = true
                Log.warn("Caesura: menu bar item is not drawn; the menu bar may lack space " +
                         "(isVisible stays true per Apple); not rebuilding")
            }
            if windowDrawn {
                menuBarItemNotDrawnWarned = false
            }
        }
        refreshIcon()
        rebuildMenu()
        updateToolTip()
        if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    func remove() {
        tooltip.detach()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton?) {
        // NSStatusItem with a context menu shows it automatically on click; double-click
        // opens preferences (legacy behavior).
        let currentEvent = NSApp.currentEvent
        if currentEvent?.clickCount ?? 0 >= 2 {
            actions?.openPreferences()
        }
    }

    /// Verification hook: opens the menu programmatically so a real screenshot of the
    /// menu bar menu can be taken.
    func openMenuForVerification() {
        statusItem?.button?.performClick(nil)
    }

    /// Verification hook: hides the item the way the system does, so the restoration
    /// path can be exercised. No-op with a log when no item exists.
    func hideStatusItemForVerification() {
        guard let statusItem else {
            Log.info("Caesura: no menu bar item to hide")
            return
        }
        Log.info("Caesura: hiding the menu bar item for verification")
        statusItem.isVisible = false
    }

    /// The window of the menu bar item (it is not part of `NSApp.windows`).
    var statusItemWindow: NSWindow? {
        statusItem?.button?.window
    }

    /// The frame of the menu bar button in the coordinates of its screen — the
    /// anchor of the toast that points at the icon.
    ///
    /// The frame of the window is the anchor, not the conversion of the button:
    /// the window of a status item has its own base coordinate system, so the
    /// conversion lands at the origin of the screen instead of at the icon.
    var statusItemButtonScreenFrame: NSRect? {
        guard let window = statusItem?.button?.window, window.isVisible else { return nil }
        return window.frame
    }

    /// The menu bar item exists (it is created when `showTrayIcon` is enabled).
    var isStatusItemPresent: Bool {
        statusItem != nil && statusItem?.button != nil
    }

    /// The menu bar item is shown in the menu bar: its button is visible and not
    /// hidden. A status item without a button is not shown at all.
    var isStatusItemVisible: Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        return !button.isHidden && window.isVisible
    }

    /// The window id of the menu bar item, for verification screenshots.
    var statusItemWindowID: CGWindowID? {
        guard let window = statusItemWindow, window.isVisible else { return nil }
        let number = window.windowNumber
        guard number > 0, number <= Int(CGWindowID.max) else { return nil }
        return CGWindowID(number)
    }

    func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let descriptor = TrayIconDescriptor(planner: planner, settings: settings,
                                            darkAppearance: trayIconUseDarkColors())
        button.image = TrayIconRenderer.image(for: descriptor)
        // The tooltip watches the icon: it appears when the pointer rests on
        // it and it leaves with the pointer. The area needs the size of the
        // icon, so it is added after the image is set.
        tooltip.attach(to: button)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        // The tooltip would hang over the menu.
        tooltip.hide()
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        if !settings.getBool("disableAppUpdateFeatures") && isNewVersion {
            addItem(to: menu, title: localization.t("main.downloadLatestVersion"),
                    symbol: "arrow.down.circle",
                    action: #selector(openDownloadsClicked), target: self)
            menu.addItem(.separator())
        }

        let input = StatusMessages.Input(planner: planner, settings: settings)
        let statusMessage = StatusMessages.stateMessage(input, localization: localization)
        if !statusMessage.isEmpty {
            for line in statusMessage.components(separatedBy: "\n") {
                let item = menu.addItem(withTitle: line, action: nil, target: nil)
                item.isEnabled = false
            }
            menu.addItem(.separator())
        }

        let inStrictBreak = (planner.scheduler.reference == "finishMicrobreak" && settings.getBool("microbreakStrictMode")) ||
            (planner.scheduler.reference == "finishBreak" && settings.getBool("breakStrictMode"))
        if inStrictBreak && !settings.getBool("showTrayMenuInStrictMode") {
            return // empty menu in strict mode, like legacy
        }

        let schedulerCleared = planner.exclusionsMachine.isSchedulerCleared
        let notPausedAnywhere = !(planner.isPaused || planner.dndMachine.isOnDnd || schedulerCleared)
        // The countdown of the next break and the skip menu are one: an item
        // per break type that starts that type at once. The minutes are shown
        // only for the type that is planned right now — the countdown of the
        // scheduler is exact for it, and no other number is invented.
        if notPausedAnywhere {
            for item in MenuSkipPlan.items(planner: planner, settings: settings) {
                addItem(to: menu, title: skipItemTitle(item),
                        symbol: item.isMini ? "timer" : "cup.and.saucer",
                        action: item.isMini ? #selector(skipToMicrobreakClicked) : #selector(skipToBreakClicked),
                        target: self)
            }
        }

        if planner.isPaused {
            addItem(to: menu, title: localization.t("main.resume"),
                    symbol: "play.fill",
                    action: #selector(resumeClicked), target: self)
        } else if !(planner.dndMachine.isOnDnd || schedulerCleared) {
            let pause = addItem(to: menu, title: localization.t("main.pause"),
                                symbol: "pause", action: nil, target: nil)
            let submenu = NSMenu()
            submenu.addItem(withTitle: localization.t("utils.minutes", options: ["count": 30]),
                            action: #selector(pause30Clicked), target: self)
            submenu.addItem(withTitle: localization.t("main.forHour"),
                            action: #selector(pause1hClicked), target: self)
            submenu.addItem(withTitle: localization.t("main.for2Hours"),
                            action: #selector(pause2hClicked), target: self)
            submenu.addItem(withTitle: localization.t("main.for5Hours"),
                            action: #selector(pause5hClicked), target: self)
            submenu.addItem(withTitle: localization.t("main.untilMorning"),
                            action: #selector(pauseMorningClicked), target: self)
            submenu.addItem(.separator())
            submenu.addItem(withTitle: localization.t("main.indefinitely"),
                            action: #selector(pauseIndefinitelyClicked), target: self)
            pause.submenu = submenu
            addItem(to: menu, title: localization.t("main.resetBreaks"),
                    symbol: "arrow.counterclockwise",
                    action: #selector(resetClicked), target: self)
        }

        menu.addItem(.separator())
        addItem(to: menu, title: localization.t("main.todaysPoem"),
                symbol: "text.book.closed",
                action: #selector(todaysPoemClicked), target: self)
        addItem(to: menu, title: localization.t("main.preferences"),
                symbol: "gearshape",
                action: #selector(preferencesClicked), target: self)

        menu.addItem(.separator())
        addItem(to: menu, title: localization.t("main.quitCaesura"),
                symbol: "power",
                action: #selector(quitClicked), target: self)
    }

    /// A menu item with a system symbol; the symbol carries the title as its
    /// accessibility description, so the meaning survives without the image.
    @discardableResult
    private func addItem(to menu: NSMenu, title: String, symbol: String?,
                         action selector: Selector?, target: AnyObject?) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: selector, target: target)
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
        return item
    }

    /// The title of one skip item: the minutes are part of the title only when
    /// the plan of that type is exact (see `MenuSkipPlan`).
    private func skipItemTitle(_ item: MenuSkipPlan.Item) -> String {
        if let minutes = item.minutes {
            return localization.t(item.isMini ? "main.skipMiniBreakIn" : "main.skipLongBreakIn",
                                  options: ["minutes": minutes])
        }
        return localization.t(item.isMini ? "main.skipMiniBreakNow" : "main.skipLongBreakNow")
    }

    // MARK: Actions

    @objc private func skipToMicrobreakClicked() { actions?.skipToMicrobreak() }
    @objc private func skipToBreakClicked() { actions?.skipToBreak() }
    @objc private func resumeClicked() { actions?.resumeBreaks() }
    @objc private func pause30Clicked() { actions?.pauseBreaks(1800 * 1000) }
    @objc private func pause1hClicked() { actions?.pauseBreaks(3600 * 1000) }
    @objc private func pause2hClicked() { actions?.pauseBreaks(3600 * 2 * 1000) }
    @objc private func pause5hClicked() { actions?.pauseBreaks(3600 * 5 * 1000) }
    @objc private func pauseMorningClicked() {
        let millis = UntilMorning.msToSunrise(settings: settings)
        actions?.pauseBreaks(millis)
    }
    @objc private func pauseIndefinitelyClicked() { actions?.pauseBreaks(1) }
    @objc private func resetClicked() { actions?.resetBreaks() }
    @objc private func preferencesClicked() { actions?.openPreferences() }
    @objc private func todaysPoemClicked() { actions?.showTodaysPoem() }
    @objc private func quitClicked() { actions?.quit() }
    @objc private func openDownloadsClicked() { actions?.openDownloads() }

    // MARK: Tooltip

    func updateToolTip() {
        guard let button = statusItem?.button else { return }
        var text = localization.t("main.toolTipHeader")
        let input = StatusMessages.Input(planner: planner, settings: settings)
        let message = StatusMessages.trayMessage(input, longBreaksEnabled: settings.getBool("break"),
                                                 localization: localization)
        if !message.isEmpty {
            text += "\n\n" + message
        }
        // The tooltip of the app replaces the tooltip of the system: the one of
        // the system stays on the screen when the pointer moves to another
        // application, and every refresh armed it again.
        button.toolTip = nil
        button.setAccessibilityHelp(text)
        tooltip.text = text
        logAnchorIfChanged(button: button)
    }

    /// Logs the place of the menu bar item when it moves.
    ///
    /// The verification run reads it to put the pointer on the icon.
    private func logAnchorIfChanged(button: NSStatusBarButton) {
        guard let window = button.window, window.isVisible else { return }
        let frame = window.frame
        guard frame != .zero, frame != loggedAnchor else { return }
        loggedAnchor = frame
        Log.info("Caesura: the menu bar item is at \(frame)")
    }

    /// True while the tooltip of the menu bar item is on the screen.
    var isTooltipVisible: Bool {
        tooltip.isVisible
    }
}

extension NSMenu {
    @discardableResult
    func addItem(withTitle title: String, action selector: Selector?, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = target
        addItem(item)
        return item
    }
}
