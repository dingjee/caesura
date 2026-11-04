import AppKit
import SwiftUI
import UserNotifications
import CaesuraCore

/// Coordinates the menu bar, break schedule, poem progression and application windows.
final class AppCoordinator: NSObject, NSApplicationDelegate {
    let launchArguments: [String]
    private(set) var settings: SettingsStore!
    private(set) var planner: BreaksPlanner!
    private var driver: PlannerDriver!
    private(set) var localization = Localization()
    private(set) var screenManager: ScreenManager!
    private(set) var statusBar: StatusBarController!
    private(set) var audio: AudioPlayer!
    private(set) var health = HealthTracker(modeEnabled: false)
    private(set) var cliServer = CliServer()

    private var idleMonitor: IdleMonitor!
    private var focusMonitor: FocusMonitor!
    private var exclusionsMonitor: ExclusionsMonitor!
    private let sleepMonitor = SleepMonitor()
    /// Held while a break is on the screen: idle display sleep and the idle
    /// screen saver would bring the lock screen up behind the break.
    private let displaySleep = DisplaySleepAssertion()

    var isNewVersion = false
    private var pausedForSuspendOrLock = false
    /// True when the pause of a fullscreen video told the user once that the
    /// accessibility permission is missing. The hint comes once per process:
    /// a notice on every break would nag without helping.
    private var didWarnAboutAccessibilityPermission = false
    private var versionCheckWorkItem: DispatchWorkItem?
    /// The end sound of a manual-await break is played once per break.
    private var didPlayManualAwaitSound = false

    enum PendingIdea {
        case mini(String)
        case long(title: String?, text: String?)
        /// The poem of a break that already ran (the replay of the last
        /// break). The poem is frozen, the timing starts again and the showing
        /// is not counted.
        case poem(PoemBreakSession)
    }

    private var nextIdea: PendingIdea?
    private var lastBreak: (mini: Bool, idea: PendingIdea)?
    /// The pause of a video in fullscreen for a break: it reads the playback
    /// of the target, pauses it only when it plays, and resumes exactly it.
    private let videoPlayback = VideoPlaybackController()

    private var breakSession: BreakSession?
    private var preferencesWindow: OwnedWindow?
    /// The window with the poem of the rotation.
    private var poemWindow: OwnedWindow?
    /// The first-run toast under the menu bar icon.
    private var toast: ToastWindow?
    private var preferencesController: PreferencesController?
    /// Application-owned screenshot hook (verification): when set, real app windows are
    /// captured with CGWindowListCreateImage into this directory at key moments.
    private let shotsDirectory: URL?
    /// Weak probes of the closed windows (development only, lifecycle test).
    private var lifecycleWindowProbes: [String: WeakWindow] = [:]
    /// The running lifecycle test (development only). It has to be retained for
    /// the whole run.
    private var lifecycleRunner: LifecycleTestRunner?

    init(launchArguments: [String]) {
        self.launchArguments = launchArguments
        if let shotsPath = ProcessInfo.processInfo.environment["CAESURA_SHOTS_DIR"], !shotsPath.isEmpty {
            let url = URL(fileURLWithPath: (shotsPath as NSString).expandingTildeInPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            shotsDirectory = url
        } else {
            shotsDirectory = nil
        }
        super.init()
    }

    /// Captures the app's own windows (no Screen Recording permission required for
    /// self-owned windows). Supplemental to screencapture.
    ///
    /// The window ids are collected on the main thread, the (slow) capture itself runs
    /// in the background so the user interface is never blocked.
    @objc func captureWindowShots(tag: String) {
        guard let shotsDirectory else { return }
        var targets: [(name: String, id: CGWindowID, view: NSView?)] = []
        for (index, window) in NSApp.windows.enumerated() {
            guard window.isVisible else { continue }
            // `windowNumber` is a dynamic property: read it once, it can change (or turn
            // negative) between two accesses.
            let number = window.windowNumber
            guard number > 0, number <= Int(CGWindowID.max) else { continue }
            let name = window.title.isEmpty ? "window-\(index)" :
                window.title.replacingOccurrences(of: "/", with: "-")
            targets.append((name, CGWindowID(number), window.contentView))
        }
        if let statusItemID = statusBar?.statusItemWindowID {
            targets.append(("statusitem", statusItemID, nil))
        }
        guard !targets.isEmpty else {
            Log.warn("Caesura: no visible app windows to capture for \(tag)")
            return
        }
        DispatchQueue.global(qos: .utility).async {
            var captured = 0
            for target in targets {
                // The window surface of a non-activating overlay does not always contain
                // the rendered content, so the view is rendered into a bitmap as well.
                if let view = target.view, let image = BreakWindowRenderer.render(view) {
                    let url = shotsDirectory.appendingPathComponent("\(tag)-\(target.name).png")
                    try? image.write(to: url, options: .atomic)
                    captured += 1
                    Log.info("Caesura: captured window shot \(url.path)")
                    continue
                }
                guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, target.id,
                                                            [.bestResolution, .boundsIgnoreFraming]) else {
                    Log.warn("Caesura: window capture failed for \(target.name) (\(tag))")
                    continue
                }
                let rep = NSBitmapImageRep(cgImage: cgImage)
                guard let data = rep.representation(using: .png, properties: [:]) else { continue }
                let url = shotsDirectory.appendingPathComponent("\(tag)-\(target.name).png")
                try? data.write(to: url, options: .atomic)
                captured += 1
                Log.info("Caesura: captured window shot \(url.path)")
            }
            if captured == 0 {
                Log.warn("Caesura: no window could be captured for \(tag)")
            }
        }
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.configure(dataDirectory: AppPaths.dataDirectory())

        // The probe of the poem (development only): it renders the poem of a
        // break into an image and stops the app. Without the environment
        // variable nothing happens and the app starts as usual.
        if PoemProbe.runIfRequested() {
            Log.info("Caesura: the poem probe wrote its images")
            Log.flush()
            exit(0)
        }

        // The identity of this process and what macOS tells it about the
        // accessibility permission: the log is the first place to look when
        // a permission seems to be missing (the permission belongs to this
        // binary — a rebuild that changes its signature asks for it again).
        Log.info("Caesura: running as \(Bundle.main.bundleIdentifier ?? "-") "
                 + "(\(Bundle.main.bundleURL.path))")
        Log.info("Caesura: accessibility permission granted: \(VideoPlayback.canUseAccessibility)")

        Notifier.shared.configure()
        NotificationCenter.default.addObserver(forName: Notifier.openPreferencesNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.createPreferencesWindow()
        }

        // Single instance: forward CLI args to the running GUI and exit when one exists.
        if !launchArguments.isEmpty {
            let command = Command(input: launchArguments, version: AppPaths.version)
            if !command.isLocalCommand {
                let payload: [String: Any] = ["argv": launchArguments]
                if let data = try? JSONSerialization.data(withJSONObject: payload),
                   case .forwarded = CliForwarder.forward(argvJSON: data, socketURL: AppPaths.socketURL()) {
                    Log.info("Caesura: forwarding command to the main instance")
                    exit(0)
                }
            } else {
                // help/version/logs behave like the CLI even when launched from the app binary.
                switch command.command {
                case "version": print(command.versionText())
                case "logs": print(Log.logFileURL.path)
                default: print(command.helpText())
                }
                exit(0)
            }
        }

        // The CLI socket doubles as the single-instance lock: a second GUI instance
        // finds the socket owned by the running instance and exits instead of running
        // a duplicate scheduler.
        if !startCliServer() {
            if cliServer.lastError == CliServer.errorSocketOwned {
                Log.info("Caesura: another instance is already running, exiting")
                exit(0)
            }
            Log.warn("Caesura: continuing without a CLI server")
        }

        // Preflight of an isolated run: every window of the app is placed on the
        // secondary display, so that the display of the user is never covered.
        // Without a secondary display the run stops — there is no fallback to the
        // main or to the cursor display. A test-only opt-in
        // (CAESURA_NATIVE_TEST_MAIN_DISPLAY) may use the main display instead; it
        // is logged and never happens silently.
        if AppPaths.isIsolatedRun {
            if let secondary = SecondaryDisplay.screen {
                Log.info("Caesura: isolated run on the secondary display \(secondary.frame)")
            } else if AppPaths.allowsMainDisplayInIsolatedRun, let main = NSScreen.main ?? NSScreen.screens.first {
                Log.warn("Caesura: isolated run uses the main display (\(main.frame)) — explicitly allowed by CAESURA_NATIVE_TEST_MAIN_DISPLAY")
            } else {
                Log.error("Caesura: isolated run needs a secondary display, stopping")
                exit(1)
            }
        }

        observeScreenChanges()
        initialize(isAppStart: true)
        scheduleMenuOpening()
        startLifecycleTestIfRequested()
    }

    /// Opt-in lifecycle regression runner (development only). Without the
    /// environment variable nothing runs and the app is unchanged.
    private func startLifecycleTestIfRequested() {
        // The runner only runs in an isolated profile: it drives the real windows
        // of the app and must never touch a normal installation.
        guard AppPaths.isIsolatedRun else { return }
        guard let spec = ProcessInfo.processInfo.environment["CAESURA_LIFECYCLE_TEST"],
              !spec.isEmpty,
              let runner = LifecycleTestRunner(coordinator: self, spec: spec) else { return }
        Log.info("Caesura: lifecycle test requested")
        // The runner is kept alive by the coordinator: it schedules its steps with
        // weak references and would be gone otherwise.
        lifecycleRunner = runner
        runner.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let inStrictBreak = (planner?.scheduler.reference == "finishMicrobreak" && settings?.getBool("microbreakStrictMode") == true) ||
            (planner?.scheduler.reference == "finishBreak" && settings?.getBool("breakStrictMode") == true)
        if inStrictBreak {
            Log.info("Caesura: preventing app closure (in break with strict mode)")
            return .terminateCancel
        }
        Log.info("Caesura: terminating on request")
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        Notifier.shared.cancelPendingDismissals()
        Log.info("Caesura: terminated")
        Log.flush()
    }

    /// Port of legacy `initialize`.
    func initialize(isAppStart: Bool) {
        Log.info("Caesura: \(isAppStart ? "" : "re")initializing...")

        if settings == nil {
            TrialSupport.importCompatibleProfileIfNeeded()
            settings = SettingsStore(url: AppPaths.configURL(), loadNow: false)
            let importedConfig = !AppPaths.isIsolatedRun && settings.importLegacyConfigIfPresent(legacyURL: AppPaths.legacyConfigURL())
            settings.readOnlyFailureHandler = { message in
                Notifier.shared.show(text: message, silent: false)
            }
            settings.load()
            if settings.diagnostics.contains(where: { $0.kind == .legacyImported }) {
                Log.info("Caesura: legacy Electron settings imported (backup written)")
            }
            if importedConfig {
                // The legacy user data also holds custom audio, custom images and the
                // contributor stamp; they are copied without overwriting native files.
                let assets = LegacyAssets.importAssets(legacyDirectory: AppPaths.legacyDataDirectory(),
                                                      nativeDirectory: AppPaths.dataDirectory())
                Log.info("Caesura: legacy assets imported (audio: \(assets.copiedAudio), images: \(assets.copiedImages), stamp: \(assets.importedStamp))")
            }
        }
        health = HealthTracker(modeEnabled: settings.getBool("breakHealthMode"))
        settings.onChange = { [weak self] key, _ in
            self?.handleSettingChanged(key: key)
        }

        localization.setLanguage(settings.getString("language"))
        reloadIdeaDecks()
        let rotation = PoemRotation(provider: BundledPoemProvider(), settings: settings)
        if !rotation.isAvailable {
            Log.warn("Caesura: no poem catalog, breaks fall back to empty ideas")
        }
        poemRotation = rotation

        if planner == nil {
            planner = BreaksPlanner(clock: SystemClock(), settings: settings)
            attachPlannerHandlers()
        }
        planner.reinitializeMachines()
        planner.nextBreak()
        driver = PlannerDriver(planner: planner)
        rescheduleDriver()

        screenManager = ScreenManager(settings: settings)
        audio = AudioPlayer(settings: settings)

        syncLoginItem()
        applyThemeSource()
        ensureCustomAssetDirectories()
        if AppPaths.isIsolatedRun {
            // An isolated run must not ask for notification authorization: the
            // permission belongs to the installed app, not to the test profile.
            Log.info("Caesura: isolated run, not asking for notification authorization")
        } else {
            Notifier.shared.requestAuthorizationIfNeeded(silentNotifications: settings.getBool("silentNotifications"))
        }
        startMonitors()
        registerHotkeys()
        planVersionCheck(seconds: 1)
        checkMediaKeyPermission()

        statusBar?.remove()
        statusBar = StatusBarController(settings: settings, localization: localization, planner: planner)
        statusBar.isNewVersion = isNewVersion
        statusBar.actions = StatusBarController.MenuActions(
            skipToMicrobreak: { [weak self] in self?.skipToMicrobreak() },
            skipToBreak: { [weak self] in self?.skipToBreak() },
            pauseBreaks: { [weak self] millis in self?.pauseBreaks(millis) },
            resumeBreaks: { [weak self] in self?.resumeBreaks(false) },
            resetBreaks: { [weak self] in self?.resetBreaks() },
            openPreferences: { [weak self] in self?.createPreferencesWindow() },
            showTodaysPoem: { [weak self] in self?.createPoemWindow() },
            quit: { [weak self] in
                // A video that was paused for a break has to play again.
                self?.videoPlayback.resumeIfNeeded()
                NSApp.terminate(nil)
            },
            openDownloads: { [weak self] in self?.openExternal("https://github.com/dingjee/caesura/releases") }
        )
        statusBar.refresh()

        // The first run: the app stays in the menu bar, a toast points at the
        // icon to say that it is running.
        if isAppStart, settings.getBool("isFirstRun") {
            settings.set("isFirstRun", .bool(false))
            showRunningToast()
        }

        refreshOpenWindows()
    }

    /// Verification hook: opens the menu bar menu so that a real screenshot can be
    /// taken (`CAESURA_OPEN_MENU_AFTER=<seconds>`). Never active without the
    /// environment variable.
    private func scheduleMenuOpening() {
        // The menu of the status item opens on the main display: an isolated run
        // never does that.
        guard !AppPaths.isIsolatedRun else { return }
        guard let raw = ProcessInfo.processInfo.environment["CAESURA_OPEN_MENU_AFTER"],
              let seconds = TimeInterval(raw), seconds > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.statusBar.openMenuForVerification()
            self?.captureWindowShots(tag: "menu")
        }
    }

    private func attachPlannerHandlers() {
        planner.onEvent = { [weak self] event in
            guard let self else { return }
            self.driver?.reschedule()
            switch event {
            case .startMicrobreakNotification:
                self.startBreakNotification(mini: true)
            case .startBreakNotification:
                self.startBreakNotification(mini: false)
            case .startMicrobreak:
                self.startMicrobreak()
            case .startBreak:
                self.startBreak()
            case .finishMicrobreak(let shouldPlaySound, let shouldPlanNext):
                if self.settings.getBool("miniBreakManualFinish") {
                    self.enterManualAwait(mini: true, shouldPlaySound: shouldPlaySound)
                    return
                }
                self.health.decrease(-HealthPolicy.completed(mini: true))
                // The planner ends the break when its duration is over.
                self.finishMicrobreak(shouldPlaySound: shouldPlaySound, shouldPlanNext: shouldPlanNext,
                                      outcome: .elapsed)
            case .finishBreak(let shouldPlaySound, let shouldPlanNext):
                if self.settings.getBool("longBreakManualFinish") {
                    self.enterManualAwait(mini: false, shouldPlaySound: shouldPlaySound)
                    return
                }
                self.health.decrease(-HealthPolicy.completed(mini: false))
                self.finishBreak(shouldPlaySound: shouldPlaySound, shouldPlanNext: shouldPlanNext,
                                 outcome: .elapsed)
            case .resumeBreaks:
                self.resumeBreaks(true)
            case .updateToolTip:
                self.statusBar?.refresh()
            case .restartPollers:
                self.startPollers()
            case .stopPollers:
                self.stopPollers()
            case .naturalBreaksPoller(let shouldUse):
                shouldUse ? self.idleMonitor?.start() : self.idleMonitor?.stop()
            case .dndPoller(let shouldUse):
                shouldUse ? self.focusMonitor?.start(checkIntervalMillis: self.settings.getMillis("monitorDndCheckInterval"))
                          : self.focusMonitor?.stop()
            }
        }
    }

    private func rescheduleDriver() {
        driver?.reschedule()
    }

    // MARK: Initialization helpers

    /// The pause of a video in fullscreen reads and presses the controls of
    /// another application, which needs the accessibility permission. Without
    /// it the feature cannot work, so the user is told once where to grant it.
    private func checkMediaKeyPermission() {
        guard settings.getBool("pauseFullscreenVideo") else { return }
        guard !VideoPlayback.canUseAccessibility else { return }
        Log.warn("Caesura: the accessibility permission is missing, "
                 + "a video in fullscreen cannot be paused until it is granted "
                 + "(Preferences → Breaks)")
    }

    private func syncLoginItem() {
        // An isolated run must never change the login item of the real installation.
        if AppPaths.isIsolatedRun {
            Log.info("Caesura: isolated run, not touching the login item")
            return
        }
        let migrated = settings.getBool("_migratedOpenAtLogin")
        let status = LoginItemManager.currentStatus()
        if !migrated {
            settings.set("openAtLogin", .bool(status == .enabled || status == .requiresApproval))
            settings.set("_migratedOpenAtLogin", .bool(true))
            Log.info("Caesura: Migrated to openAtLogin")
        }
        let openAtLogin = settings.getBool("openAtLogin")
        let current = LoginItemManager.currentStatus() == .enabled
        if openAtLogin != current {
            LoginItemManager.setEnabled(openAtLogin)
        }
    }

    private func applyThemeSource() {
        switch settings.getString("themeSource") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    private func ensureCustomAssetDirectories() {
        for url in [AppPaths.audioDirectory(), AppPaths.imagesDirectory()] {
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
    }

    private func startMonitors() {
        idleMonitor?.stop()
        focusMonitor?.stop()
        exclusionsMonitor?.stop()
        sleepMonitor.stop()
        idleMonitor = IdleMonitor(settings: settings)
        idleMonitor.onUpdate = { [weak self] millis in
            self?.planner.applyIdle(idleMillis: millis)
            self?.statusBar?.refresh()
        }
        if settings.getBool("naturalBreaks") {
            idleMonitor.start()
        }

        focusMonitor = FocusMonitor()
        focusMonitor.onUpdate = { [weak self] enabled in
            self?.planner.applyDnd(enabled: enabled)
            self?.statusBar?.refresh()
        }
        if settings.getBool("monitorDnd") {
            focusMonitor.start(checkIntervalMillis: settings.getMillis("monitorDndCheckInterval"))
        }

        exclusionsMonitor = ExclusionsMonitor(settings: settings)
        exclusionsMonitor.onSnapshot = { [weak self] processes in
            guard let self else { return }
            // Every snapshot is delivered, including "no match": the state machine
            // needs the nil to finish a pause rule / start a resume rule.
            let matched = self.planner.exclusionsMachine.matchedCommand(in: processes)
            self.planner.applyExclusion(matched: matched)
            self.statusBar?.refresh()
        }
        exclusionsMonitor.start()

        sleepMonitor.onSuspendOrLock = { [weak self] in
            self?.onSuspendOrLock()
        }
        sleepMonitor.onResumeOrUnlock = { [weak self] in
            self?.onResumeOrUnlock()
        }
        sleepMonitor.start()
    }

    private func startPollers() {
        if settings.getBool("naturalBreaks") { idleMonitor.start() }
        if settings.getBool("monitorDnd") { focusMonitor.start(checkIntervalMillis: settings.getMillis("monitorDndCheckInterval")) }
        exclusionsMonitor.start()
    }

    /// Legacy `pause` stops the idle/DND/exclusion managers; `resume` starts them again.
    private func stopPollers() {
        idleMonitor?.stop()
        focusMonitor?.stop()
        exclusionsMonitor?.stop()
    }

    /// Recreates the monitors so that changed check intervals and rules are picked up
    /// (the monitors capture their interval when they start).
    private func restartMonitors() {
        startMonitors()
    }

    private var shortcutSettingsKeys: [String] {
        ["pauseBreaksFor30MinutesShortcut", "pauseBreaksFor1HourShortcut", "pauseBreaksFor2HoursShortcut",
         "pauseBreaksFor5HoursShortcut", "pauseBreaksUntilMorningShortcut", "pauseBreaksToggleShortcut",
         "skipToNextScheduledBreakShortcut", "skipToNextMiniBreakShortcut", "skipToNextLongBreakShortcut",
         "resetBreaksShortcut", "startLastBreakAgainShortcut"]
    }

    private func registerHotkeys() {
        HotKeyManager.shared.unregisterAll()
        HotKeyManager.shared.onHotKey = { [weak self] name in
            self?.handleShortcut(name: name)
        }
        for key in shortcutSettingsKeys {
            let accelerator = settings.getString(key)
            guard !accelerator.isEmpty else { continue }
            HotKeyManager.shared.register(name: key, accelerator: accelerator)
        }
        // The end-break shortcut only exists during a break; other shortcuts stay
        // registered and keep their own dispatch (legacy registered both).
        if breakSession != nil {
            registerEndBreakShortcut()
        }
    }

    /// Legacy breakShortcuts.js `onShortcut`.
    private func handleShortcut(name: String) {
        switch name {
        case "endBreakShortcut":
            guard let session = breakSession else { return }
            endBreakShortcutPressed(mini: session.mini)
        case "pauseBreaksToggleShortcut":
            if planner.isPaused {
                Log.info("Caesura: resuming breaks by shortcut")
                resumeBreaks(false)
            } else {
                Log.info("Caesura: pausing breaks by shortcut")
                pauseBreaks(1)
            }
        case "skipToNextScheduledBreakShortcut":
            if planner.scheduledBreakType == "break" {
                skipToBreak()
            } else {
                skipToMicrobreak()
            }
        case "skipToNextMiniBreakShortcut":
            skipToMicrobreak()
        case "skipToNextLongBreakShortcut":
            skipToBreak()
        case "resetBreaksShortcut":
            resetBreaks()
        case "startLastBreakAgainShortcut":
            startLastBreakAgain()
        case "pauseBreaksUntilMorningShortcut":
            pauseBreaks(UntilMorning.msToSunrise(settings: settings))
        case "pauseBreaksFor30MinutesShortcut":
            pauseBreaks(30 * 60 * 1000)
        case "pauseBreaksFor1HourShortcut":
            pauseBreaks(3600 * 1000)
        case "pauseBreaksFor2HoursShortcut":
            pauseBreaks(2 * 3600 * 1000)
        case "pauseBreaksFor5HoursShortcut":
            pauseBreaks(5 * 3600 * 1000)
        default:
            break
        }
    }

    private func startCliServer() -> Bool {
        cliServer.onArgv = { [weak self] argv in
            // The status is answered right here: it only reads the state of
            // this process, and the client waits for the answer.
            if let answer = self?.statusAnswer(for: argv) { return answer }
            // The server delivers on a background queue; every UI action runs on the
            // main thread.
            DispatchQueue.main.async {
                self?.handleForwardedArguments(argv)
            }
            return nil
        }
        if !cliServer.start(socketURL: AppPaths.socketURL()) {
            Log.warn("Caesura: could not start CLI server: \(cliServer.lastError)")
            return false
        }
        return true
    }

    /// The status of this process, as JSON: the identity of the application
    /// that is really running and what macOS tells it about the accessibility
    /// permission.
    ///
    /// The command line client asks the running instance for it, so the answer
    /// is about that process — the accessibility permission of the *client* is
    /// a different thing and would tell nothing about the application.
    private func statusAnswer(for argv: [String]) -> String? {
        let command = Command(input: argv, version: AppPaths.version)
        guard command.command == "status", command.hasSupportedCommand else { return nil }
        // The whole snapshot is built on the main thread: the settings belong
        // to the user interface, and the answer never races with a change in
        // the preferences. The server never waits for the client queue, so
        // this cannot become a circular wait.
        var status: [String: Any] = [:]
        DispatchQueue.main.sync { [weak self] in
            status = [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "version": AppPaths.version,
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                "bundlePath": Bundle.main.bundleURL.path,
                "executablePath": Bundle.main.executableURL?.path ?? "",
                "accessibilityTrusted": VideoPlayback.canUseAccessibility,
                "pauseVideoPlayback": self?.settings?.getBool("pauseFullscreenVideo") ?? false,
            ]
        }
        // The answer is one line: the frame of the socket is newline
        // terminated, so a pretty printed payload would break it.
        guard let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        Log.info("Caesura: status requested — accessibility trusted: "
                 + "\(status["accessibilityTrusted"] ?? false), bundle: "
                 + "\(status["bundleIdentifier"] ?? ""), executable: "
                 + "\(status["executablePath"] ?? "")")
        return text
    }

    /// Hot-plug: the break windows follow the display layout without losing the
    /// break deadline or the countdown state.
    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleScreenParametersChanged()
        }
    }

    private func handleScreenParametersChanged() {
        // An isolated run must not survive the loss of its secondary display:
        // AppKit would move the open windows to the display of the user. A run that
        // explicitly uses the main display keeps running on it.
        if AppPaths.isIsolatedRun, SecondaryDisplay.screen == nil,
           !AppPaths.allowsMainDisplayInIsolatedRun {
            Log.error("Caesura: isolated run lost its secondary display, stopping")
            exit(1)
        }
        // A display change must also re-check the menu bar item: without a running
        // break the notification used to skip the refresh entirely.
        if let session = breakSession {
            session.relayout(screens: screenManager.targetScreens(),
                             contentScreen: screenManager.contentDisplayScreen(),
                             settings: settings)
        }
        statusBar?.refresh()
    }

    private func refreshOpenWindows() {
        if let controller = preferencesController, preferencesWindow?.isVisible == true {
            controller.reload(settings: settings, localization: localization)
        }
    }

    // MARK: Notifications & version check

    private func startBreakNotification(mini: Bool) {
        let seconds = Int(settings.getMillis(mini ? "microbreakNotificationInterval" : "breakNotificationInterval") / 1000)
        let text = localization.t(mini ? "main.microbreakIn" : "main.breakIn", options: ["seconds": seconds])
        Notifier.shared.show(text: text, silent: settings.getBool("silentNotifications"))
        Log.info("Caesura: showing \(mini ? "Mini" : "Long") break notification")
        planner.nextBreakAfterNotification()
        statusBar?.refresh()
    }

    private func planVersionCheck(seconds: TimeInterval) {
        guard !settings.getBool("disableAppUpdateFeatures") else { return }
        versionCheckWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.checkVersion()
        }
        versionCheckWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func checkVersion() {
        guard !settings.getBool("disableAppUpdateFeatures") else { return }
        guard settings.getBool("checkNewVersion") else { return }
        VersionCheck.fetchLatestTag { [weak self] tag in
            guard let self else { return }
            if let tag, VersionCheck.isNewVersionAvailable(remoteTag: tag, localVersion: AppPaths.version) {
                if !self.isNewVersion {
                    self.isNewVersion = true
                    self.statusBar.isNewVersion = true
                    self.statusBar.refresh()
                    if self.settings.getBool("notifyNewVersion") {
                        Notifier.shared.show(localizedKey: "process.newVersionAvailable",
                                             localization: self.localization,
                                             silent: self.settings.getBool("silentNotifications"),
                                             openURL: "https://github.com/dingjee/caesura/releases")
                    }
                }
            }
            self.planVersionCheck(seconds: 3600 * 48)
        }
    }

    // MARK: Break lifecycle (legacy startMicrobreak/startBreak & friends)

    private var miniIdeas: [String] {
        IdeasLoader.miniIdeas(settings: settings, localization: localization)
    }

    private var longIdeas: [(title: String, text: String)] {
        IdeasLoader.longIdeas(settings: settings, localization: localization)
    }

    /// Persistent idea decks (legacy `new IdeasLoader(data).ideas()`): every card is
    /// drawn once before the deck is rebuilt, so two breaks in a row never repeat.
    private var miniIdeaDeck: Shuffled<String>?
    private var longIdeaDeck: Shuffled<BreakIdea>?
    /// Daily poem of the default idea path (nil when the catalog is unavailable).
    private var poemRotation: PoemRotation?

    private func reloadIdeaDecks() {
        miniIdeaDeck = Shuffled(miniIdeas)
        longIdeaDeck = Shuffled(longIdeas.map { BreakIdea(title: $0.title, text: $0.text) })
    }

    private func startBreakNotificationSound(mini: Bool) {
        let value = settings.getString(mini ? "miniBreakStartSound" : "longBreakStartSound")
        if value != "silence" {
            audio.play(value: value)
        }
    }

    private func makeBreakModel(mini: Bool, started: Int64, ideaMini: String,
                                ideaLongTitle: String, ideaLongText: String,
                                poem: PoemBreakSession?) -> BreakContentView.Model {
        let color = settings.getString(mini ? "miniBreakColor" : "mainColor")
        let background = Utils.backgroundColor(color: color,
                                               transparentMode: settings.getBool("transparentMode"),
                                               opacity: settings.getDouble("opacity"))
        // The readable foreground follows the luminance of the break background, not
        // the appearance of the application (legacy: white text, black on Snow white).
        let foreground = Utils.foregroundColor(forBackground: color)
        return BreakContentView.Model(
            mini: mini,
            ideaMini: ideaMini,
            ideaLongTitle: ideaLongTitle,
            ideaLongText: ideaLongText,
            started: started,
            duration: settings.getMillis(mini ? "microbreakDuration" : "breakDuration"),
            miniDuration: settings.getMillis("microbreakDuration"),
            strictMode: settings.getBool(mini ? "microbreakStrictMode" : "breakStrictMode"),
            postponable: settings.getBool(mini ? "microbreakPostpone" : "breakPostpone") &&
                planner.postponesNumber < Int(settings.getMillis(mini ? "microbreakPostponesLimit" : "breakPostponesLimit")) &&
                settings.getMillis(mini ? "microbreakPostponesLimit" : "breakPostponesLimit") > 0,
            postponableDurationPercent: settings.getDouble(mini ? "microbreakPostponableDurationPercent" : "breakPostponableDurationPercent"),
            backgroundColor: Color(hex: background) ?? .teal,
            foregroundColor: Color(hex: foreground) ?? .white,
            danger: health.danger,
            breakHealthMode: settings.getBool("breakHealthMode"),
            themeColor: color,
            blank: false,
            showClock: settings.getBool("currentTimeInBreaks"),
            clockFontSize: settings.getDouble("currentTimeInBreaksFontSize"),
            clockFormat: settings.getString("currentTimeInBreaksFormat"),
            shortcutHint: Utils.formatKeyboardShortcut(settings.getString("endBreakShortcut")),
            localization: localization,
            imagesDirectory: AppPaths.imagesDirectory(),
            poem: poem
        )
    }

    /// The replay of a poem break: the same poem and the same words, but a new
    /// timeline. The showing is not counted again and the session keeps its
    /// token: a replay never allocates a new one.
    private func rebasedPoemSession(_ session: PoemBreakSession, started: Int64) -> PoemBreakSession {
        PoemBreakSession(poemId: session.poemId, title: session.title, author: session.author,
                         lines: session.lines, mini: session.mini, startedAt: started,
                         durationMillis: settings.getMillis(session.mini ? "microbreakDuration" : "breakDuration"),
                         kind: session.kind, mode: session.mode,
                         revealedBefore: session.revealedBefore, revealedAfter: session.revealedAfter,
                         totalWords: session.totalWords,
                         extraRepeatsAtStart: session.extraRepeatsAtStart,
                         extraRepeatsLimit: session.extraRepeatsLimit, token: session.token)
    }

    private func startMicrobreak() {
        guard breakSession == nil else {
            Log.warn("Caesura: Mini break already running, not starting Mini break")
            return
        }
        let started = SystemClock().nowMillis
        var idea = ""
        var poemSession: PoemBreakSession?
        var countsPoemShowing = false
        if case .poem(let replay)? = nextIdea {
            // The replay of a poem break: the same poem, a new timeline and no
            // showing — the poem is not counted twice.
            poemSession = rebasedPoemSession(replay, started: started)
        } else if case .mini(let value)? = nextIdea, !value.isEmpty {
            idea = value
        } else if !settings.getBool("ideas") {
            idea = ""
        } else if settings.getBool("useIdeasFromSettings") {
            // The custom ideas of the user: an empty deck shows nothing. The
            // poem never takes their place.
            if let deck = miniIdeaDeck, let random = deck.randomElement {
                idea = random
            } else {
                idea = ""
            }
        } else if let session = poemRotation?.plan(mini: true, startedAt: started,
                                                  durationMillis: settings.getMillis("microbreakDuration")) {
            // The poem of the rotation: the break shows the words it reveals.
            poemSession = session
            countsPoemShowing = true
        } else {
            idea = ""
        }
        nextIdea = nil
        lastBreak = (true, poemSession.map { PendingIdea.poem($0) } ?? .mini(idea))

        startBreakNotificationSound(mini: true)
        didPlayManualAwaitSound = false
        let model = makeBreakModel(mini: true, started: started, ideaMini: idea,
                                   ideaLongTitle: "", ideaLongText: "",
                                   poem: poemSession)
        let session = BreakSession(mini: true, model: model,
                                   countsPoemShowing: countsPoemShowing)
        configureSessionCallbacks(session: session)
        // The break owns the screen until completeBreak: idle display sleep
        // and the idle screen saver must not bring the lock screen up behind
        // it, so the break ends on the desktop it covered.
        displaySleep.begin()
        // The video is paused before the break covers the screen: the target
        // application is still the one in front, and its controls are read
        // while they are in the state the user left them in.
        pauseVideoPlaybackIfNeeded()
        session.show(screens: screenManager.targetScreens(),
                     contentScreen: screenManager.contentDisplayScreen(),
                     settings: settings)
        breakSession = session
        registerEndBreakShortcut()
        planner.breakStarted(shouldPlaySound: true)
        Log.info("Caesura: starting Mini break")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.captureWindowShots(tag: "mini-break")
        }
        rescheduleDriver()
        statusBar.refresh()
    }

    private func startBreak() {
        guard breakSession == nil else {
            Log.warn("Caesura: Long break already running, not starting Long break")
            return
        }
        let started = SystemClock().nowMillis
        // Legacy draws the default long idea from the deck first and lets `nextIdea`
        // override each of its components. The default source is now the poem of the
        // rotation; the custom-ideas deck (useIdeasFromSettings) keeps its
        // contributor path.
        var title = ""
        var text = ""
        var poemSession: PoemBreakSession?
        var countsPoemShowing = false
        if case .poem(let replay)? = nextIdea {
            poemSession = rebasedPoemSession(replay, started: started)
        } else {
            // The CLI may name the parts of the break. Then the break shows
            // the plain content and no poem of the rotation: the poem is only
            // read, it never moves.
            let named = nextIdea.flatMap { idea -> (String?, String?)? in
                if case .long(let nextTitle, let nextText) = idea {
                    return (nextTitle, nextText)
                }
                return nil
            }
            let namedByCli = named.map {
                PoemBreakParts.hasCustomPart(title: $0.0, text: $0.1)
            } ?? false
            if namedByCli {
                // The poem of the rotation is the default of the parts the CLI
                // did not name — but only when the poem would have been the
                // source of the break. It is only read here: the rotation
                // never moves.
                var currentPoem: Poem?
                if settings.getBool("ideas"), !settings.getBool("useIdeasFromSettings") {
                    currentPoem = poemRotation?.poem()
                }
                if settings.getBool("ideas"), settings.getBool("useIdeasFromSettings"),
                   let deck = longIdeaDeck, let random = deck.randomElement {
                    // The custom ideas of the user: an empty deck shows nothing.
                    title = random.title
                    text = random.text
                }
                let parts = PoemBreakParts.resolve(
                    title: named?.0,
                    text: named?.1,
                    defaultTitle: currentPoem.map { PoemIdeaFormatter.longTitle($0) } ?? title,
                    defaultText: currentPoem.map { PoemIdeaFormatter.longBody($0) } ?? text)
                title = parts.title
                text = parts.text
            } else if settings.getBool("ideas") {
                if settings.getBool("useIdeasFromSettings") {
                    // The custom ideas of the user: an empty deck shows nothing.
                    // The poem never takes their place.
                    if let deck = longIdeaDeck, let random = deck.randomElement {
                        title = random.title
                        text = random.text
                    }
                } else if let session = poemRotation?.plan(mini: false, startedAt: started,
                                                          durationMillis: settings.getMillis("breakDuration")) {
                    // The poem of the rotation: the break shows the words it
                    // reveals.
                    poemSession = session
                    countsPoemShowing = true
                }
            }
        }
        nextIdea = nil
        lastBreak = (false, poemSession.map { PendingIdea.poem($0) } ?? .long(title: title, text: text))

        startBreakNotificationSound(mini: false)
        didPlayManualAwaitSound = false
        let model = makeBreakModel(mini: false, started: started, ideaMini: "",
                                   ideaLongTitle: title, ideaLongText: text,
                                   poem: poemSession)
        let session = BreakSession(mini: false, model: model,
                                   countsPoemShowing: countsPoemShowing)
        configureSessionCallbacks(session: session)
        // The break owns the screen until completeBreak: idle display sleep
        // and the idle screen saver must not bring the lock screen up behind
        // it, so the break ends on the desktop it covered.
        displaySleep.begin()
        // The video is paused before the break covers the screen: the target
        // application is still the one in front, and its controls are read
        // while they are in the state the user left them in.
        pauseVideoPlaybackIfNeeded()
        session.show(screens: screenManager.targetScreens(),
                     contentScreen: screenManager.contentDisplayScreen(),
                     settings: settings)
        breakSession = session
        registerEndBreakShortcut()
        planner.longBreakStarted(shouldPlaySound: true)
        Log.info("Caesura: starting Long break")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.captureWindowShots(tag: "long-break")
        }
        rescheduleDriver()
        statusBar.refresh()
    }

    private func configureSessionCallbacks(session: BreakSession) {
        session.onPostpone = { [weak self, weak session] in
            guard let self, let session else { return }
            self.postponeCurrentBreak(mini: session.mini)
        }
        session.onSkip = { [weak self, weak session] in
            guard let self, let session else { return }
            self.health.increase(HealthPolicy.skipped(mini: session.mini))
            if session.mini {
                self.finishMicrobreak(shouldPlaySound: false, shouldPlanNext: true, outcome: .skipped)
            } else {
                self.finishBreak(shouldPlaySound: false, shouldPlanNext: true, outcome: .skipped)
            }
        }
        session.onFinish = { [weak self, weak session] in
            guard let self, let session else { return }
            if session.contentState?.manualAwait == true {
                // Manual finish click: end sound already played at await entry.
                // The break did reach its duration, so it counts like one.
                self.health.decrease(-HealthPolicy.completed(mini: session.mini))
                if session.mini {
                    self.finishMicrobreak(shouldPlaySound: false, shouldPlanNext: true, outcome: .elapsed)
                } else {
                    self.finishBreak(shouldPlaySound: false, shouldPlanNext: true, outcome: .elapsed)
                }
            } else {
                session.onSkip?()
            }
        }
        session.onCountdownEnd = { [weak self, weak session] in
            guard let self, let session else { return }
            // The break reached its captured duration: the poem of this break
            // may be counted as revealed. Only a break that really lasted counts,
            // and only once — the manual finish that may follow does not count
            // a second time.
            self.commitPoemShowing(session: session)
            // Manual finish enabled: enter the await phase instead of closing.
            if self.settings.getBool(session.mini ? "miniBreakManualFinish" : "longBreakManualFinish") {
                self.enterManualAwait(mini: session.mini, shouldPlaySound: false) // sound handled by planner event
                return
            }
        }
        // Development-only probe (lifecycle test): record the discarded windows so
        // the test can check that they are released after close()/relayout().
        // Ordinary runs never assign it: no test probes are retained.
        if lifecycleRunner != nil {
            session.onWindowDiscarded = { [weak self] index, window in
                self?.lifecycleRecordClosedWindow("break-\(index)", window)
            }
        }
        // Closing a regular break window follows the same policy as the buttons,
        // the hotkey and the CLI: strict mode blocks it, otherwise it ends the break.
        session.onCloseRequested = { [weak self, weak session] _ in
            guard let self, let session else { return true }
            // The captured duration of the running break, not the current setting.
            let timeLeft = session.model.duration - (SystemClock().nowMillis - session.model.started)
            if session.model.strictMode && timeLeft > 0 {
                Log.info("Caesura: preventing closing break window as in strict mode")
                return false
            }
            self.health.increase(HealthPolicy.skipped(mini: session.mini))
            if session.mini {
                self.finishMicrobreak(shouldPlaySound: false, shouldPlanNext: true, outcome: .skipped)
            } else {
                self.finishBreak(shouldPlaySound: false, shouldPlanNext: true, outcome: .skipped)
            }
            return false
        }
    }

    /// Counts the poem of a break as shown.
    ///
    /// Only a break that reached its captured duration counts, and only once:
    /// a manual finish, a repeated callback or a rebuilt window must not count
    /// the poem twice. A break that was skipped, postponed or cancelled never
    /// counts — and it does not take a showing away either.
    ///
    /// The session itself says what is counted: the words it revealed, the
    /// completion of the poem or one more repetition of the complete poem.
    private func commitPoemShowing(session: BreakSession?) {
        guard let session else { return }
        guard let poemSession = session.model.poem else { return }
        // The break must really have lasted its duration: a break that was cut
        // short (an exclusion rule, a pause) does not count.
        let elapsed = SystemClock().nowMillis - session.model.started
        guard elapsed >= session.model.duration else { return }
        // The counting happens once per break: the countdown end and the end
        // of the break both report it.
        guard session.commitPoemShowing() else { return }
        guard let rotation = poemRotation else { return }
        let counted = rotation.commit(session: poemSession)
        let progress = rotation.revealProgress
        Log.info("Caesura: the poem '\(poemSession.title)' was shown "
                 + "(\(poemSession.kind.rawValue), \(progress.words) of \(poemSession.totalWords) words, "
                 + "\(progress.repeats) repetitions, counted: \(counted))")
    }

    /// Registers the end-break shortcut without touching the other global shortcuts.
    private func registerEndBreakShortcut() {
        HotKeyManager.shared.unregister(name: "endBreakShortcut")
        let accelerator = settings.getString("endBreakShortcut")
        guard !accelerator.isEmpty else { return }
        HotKeyManager.shared.register(name: "endBreakShortcut", accelerator: accelerator)
    }

    private func unregisterEndBreakShortcut() {
        HotKeyManager.shared.unregister(name: "endBreakShortcut")
    }

    /// Legacy end-break global shortcut policy: finish when done, postpone or skip
    /// according to the postponable window. The duration is the one captured with the
    /// break, not the current setting.
    private func endBreakShortcutPressed(mini: Bool) {
        guard let session = breakSession else { return }
        let duration = session.model.duration
        let passedPercent = Double(SystemClock().nowMillis - session.model.started) / Double(duration) * 100
        if passedPercent >= 100 {
            health.decrease(-HealthPolicy.completed(mini: mini))
            if mini {
                finishMicrobreak(shouldPlaySound: false, shouldPlanNext: true, outcome: .elapsed)
            } else {
                finishBreak(shouldPlaySound: false, shouldPlanNext: true, outcome: .elapsed)
            }
            return
        }
        let postponableDurationPercent = session.model.postponableDurationPercent
        if Utils.canPostpone(postpone: session.model.postponable, passedPercent: passedPercent,
                             postponePercent: postponableDurationPercent) {
            postponeCurrentBreak(mini: mini)
        } else if Utils.canSkip(strictMode: session.model.strictMode, postpone: session.model.postponable,
                                passedPercent: passedPercent, postponePercent: postponableDurationPercent) {
            health.increase(HealthPolicy.skipped(mini: mini))
            if mini {
                finishMicrobreak(shouldPlaySound: false, shouldPlanNext: true, outcome: .skipped)
            } else {
                finishBreak(shouldPlaySound: false, shouldPlanNext: true, outcome: .skipped)
            }
        }
    }

    private func enterManualAwait(mini: Bool, shouldPlaySound: Bool) {
        guard let session = breakSession else { return }
        // The break reached its duration: the poem of the break may be counted
        // as revealed, even when the break waits for the manual finish.
        commitPoemShowing(session: session)
        // The end sound of the countdown is played exactly once, independently of which
        // callback reports the end: the window countdown can arrive before the planner
        // event, and only the planner event carries the sound.
        if shouldPlaySound, !settings.getBool("silentNotifications"), !didPlayManualAwaitSound {
            didPlayManualAwaitSound = true
            audio.play(value: settings.getString(mini ? "miniBreakAudio" : "longBreakAudio"))
        }
        // The phase transition itself happens exactly once.
        guard !session.isManualAwait else { return }
        session.enterManualAwait()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.captureWindowShots(tag: "manual-await")
        }
    }

    private func finishMicrobreak(shouldPlaySound: Bool, shouldPlanNext: Bool,
                                  outcome: BreakSession.Outcome) {
        // The break really lasted its duration: the poem of the break may be
        // counted as revealed (at most once).
        if outcome == .elapsed {
            commitPoemShowing(session: breakSession)
        }
        completeBreak(mini: true, shouldPlaySound: shouldPlaySound, outcome: outcome)
        Log.info("Caesura: finishing Mini break (shouldPlanNext: \(shouldPlanNext))")
        if shouldPlanNext {
            planner.nextBreak()
        } else {
            planner.clear()
        }
        rescheduleDriver()
        statusBar.refresh()
    }

    private func finishBreak(shouldPlaySound: Bool, shouldPlanNext: Bool,
                              outcome: BreakSession.Outcome) {
        if outcome == .elapsed {
            commitPoemShowing(session: breakSession)
        }
        completeBreak(mini: false, shouldPlaySound: shouldPlaySound, outcome: outcome)
        Log.info("Caesura: finishing Long break (shouldPlanNext: \(shouldPlanNext))")
        if shouldPlanNext {
            planner.nextBreak()
        } else {
            planner.clear()
        }
        rescheduleDriver()
        statusBar.refresh()
    }

    private func completeBreak(mini: Bool, shouldPlaySound: Bool, outcome: BreakSession.Outcome) {
        unregisterEndBreakShortcut()
        displaySleep.end()
        videoPlayback.resumeIfNeeded()
        warnAboutMissingAccessibilityPermission()
        if shouldPlaySound && !settings.getBool("silentNotifications") {
            audio.play(value: settings.getString(mini ? "miniBreakAudio" : "longBreakAudio"))
        }
        // The reason of the end is kept on the session: a break that was skipped
        // or cancelled must never count the poem of the break as revealed.
        breakSession?.end(outcome: outcome)
        breakSession?.close()
        breakSession = nil
    }

    /// Tells the user once per process that the accessibility permission is
    /// missing. The hint comes after the break: the screen belongs to the break
    /// while it runs, and the user can open the preferences with a click on
    /// the notice. The state also stays visible in Preferences → Breaks, so a
    /// notice on every break would only nag without helping.
    private func warnAboutMissingAccessibilityPermission() {
        guard !didWarnAboutAccessibilityPermission else { return }
        guard !VideoPlayback.canUseAccessibility else { return }
        guard settings.getBool("pauseFullscreenVideo") else { return }
        didWarnAboutAccessibilityPermission = true
        Log.info("Caesura: a video in fullscreen could not be read or paused, "
                 + "the accessibility permission is missing")
        Notifier.shared.show(text: localization.t("main.mediaKeyPermissionMissing"),
                             silent: true, identifier: "media-key-permission",
                             openPreferences: true, autoDismissAfter: 30)
    }

    /// Pauses a video that plays, so that the break does not talk over it.
    /// Only a playback that could be read and confirmed is paused, and only
    /// it is resumed when the break ends.
    private func pauseVideoPlaybackIfNeeded() {
        // The setting keeps its old name so that an existing profile keeps
        // its choice; it covers every video now, not only a fullscreen one.
        guard settings.getBool("pauseFullscreenVideo") else { return }
        videoPlayback.pauseIfNeeded()
    }

    private func postponeCurrentBreak(mini: Bool) {
        // Legacy `postponeMicrobreak` and `postponeBreak` both increase the danger by 1.
        health.increase(HealthPolicy.postponed())
        completeBreak(mini: mini, shouldPlaySound: false, outcome: .postponed)
        planner.postponeCurrentBreak()
        Log.info("Caesura: postponing \(mini ? "Mini" : "Long") break")
        rescheduleDriver()
        statusBar.refresh()
    }

    private func skipToMicrobreak(delay: Int64 = 100) {
        if let session = breakSession {
            health.increase(HealthPolicy.skipped(mini: session.mini))
            completeBreak(mini: session.mini, shouldPlaySound: false, outcome: .skipped)
        }
        planner.skipToMicrobreak(delay: delay)
        Log.info("Caesura: skipping to Mini break in \(delay)ms")
        rescheduleDriver()
        statusBar.refresh()
    }

    private func skipToBreak(delay: Int64 = 100) {
        if let session = breakSession {
            health.increase(HealthPolicy.skipped(mini: session.mini))
            completeBreak(mini: session.mini, shouldPlaySound: false, outcome: .skipped)
        }
        planner.skipToBreak(delay: delay)
        Log.info("Caesura: skipping to Long break in \(delay)ms")
        rescheduleDriver()
        statusBar.refresh()
    }

    private func startLastBreakAgain() {
        guard let lastBreak else {
            Log.info("Caesura: no last break to start again")
            return
        }
        guard breakSession == nil else {
            Log.info("Caesura: not starting last break again, a break is running")
            return
        }
        guard !planner.isPaused, !planner.dndMachine.isOnDnd, !planner.exclusionsMachine.isSchedulerCleared else {
            Log.info("Caesura: not starting last break again, breaks are paused")
            return
        }
        nextIdea = lastBreak.idea
        if lastBreak.mini {
            skipToMicrobreak()
        } else {
            skipToBreak()
        }
    }

    private func resetBreaks() {
        if let session = breakSession {
            completeBreak(mini: session.mini, shouldPlaySound: false, outcome: .cancelled)
        }
        health.reset()
        planner.reset()
        Log.info("Caesura: resetting breaks")
        rescheduleDriver()
        statusBar.refresh()
    }

    private func pauseBreaks(_ milliseconds: Int64) {
        if let session = breakSession {
            health.increase(HealthPolicy.paused(mini: session.mini))
            if session.mini {
                finishMicrobreak(shouldPlaySound: false, shouldPlanNext: false, outcome: .cancelled)
            } else {
                finishBreak(shouldPlaySound: false, shouldPlanNext: false, outcome: .cancelled)
            }
        }
        planner.pause(milliseconds)
        Log.info("Caesura: pausing breaks for \(milliseconds)ms")
        rescheduleDriver()
        statusBar.refresh()
    }

    private func resumeBreaks(_ notify: Bool) {
        if planner.dndMachine.isOnDnd {
            Log.info("Caesura: not resuming breaks because in Do Not Disturb")
        } else {
            planner.resume()
            Log.info("Caesura: resuming breaks")
            if notify {
                Notifier.shared.show(localizedKey: "main.resumingBreaks",
                                     localization: localization,
                                     silent: settings.getBool("silentNotifications"))
            }
        }
        rescheduleDriver()
        statusBar.refresh()
    }

    // MARK: Sleep / lock (legacy pauseForSuspendOrLock)

    private func onSuspendOrLock() {
        Log.info("System: suspend or lock")
        guard settings.getBool("pauseForSuspendOrLock") else {
            Log.info("Caesura: not pausing for suspendOrLock because setting is disabled")
            return
        }
        let alreadyPaused = planner.isPaused || planner.dndMachine.isOnDnd ||
            planner.idleMachine.isSchedulerCleared || planner.exclusionsMachine.isSchedulerCleared
        if alreadyPaused {
            Log.info("Caesura: not pausing for suspendOrLock because paused already")
        } else {
            pausedForSuspendOrLock = true
            pauseBreaks(1)
        }
    }

    private func onResumeOrUnlock() {
        Log.info("System: resume or unlock")
        if pausedForSuspendOrLock {
            pausedForSuspendOrLock = false
            resumeBreaks(false)
        } else {
            planner.correctScheduler()
            rescheduleDriver()
        }
        statusBar.refresh()
    }

    // MARK: CLI dispatch (legacy second-instance switch)

    func handleForwardedArguments(_ arguments: [String]) {
        guard planner != nil else {
            Log.info("Caesura: ignoring command received before initialization")
            return
        }
        let command = Command(input: arguments, version: AppPaths.version)
        guard command.hasSupportedCommand else { return }
        guard command.shouldExecuteInMain else { return }
        Log.info("Caesura: arguments received: \(arguments.joined(separator: " "))")

        switch command.command {
        case "reset":
            resetBreaks()
        case "mini":
            let delay = command.waitToMs()
            if delay == -1 {
                Log.error("Caesura: error parsing wait interval to ms because of invalid value")
                return
            }
            if let title = command.options?["title"] {
                nextIdea = .mini(title)
            }
            if command.options?["noskip"] != "true" || delay > 0 {
                skipToMicrobreak(delay: delay)
            }
        case "long":
            let delay = command.waitToMs()
            if delay == -1 {
                Log.error("Caesura: error parsing wait interval to ms because of invalid value")
                return
            }
            nextIdea = .long(title: command.options?["title"], text: command.options?["text"])
            if command.options?["noskip"] != "true" || delay > 0 {
                skipToBreak(delay: delay)
            }
        case "last":
            startLastBreakAgain()
        case "resume":
            if planner.isPaused { resumeBreaks(false) }
        case "toggle":
            if planner.isPaused {
                resumeBreaks(false)
            } else {
                pauseBreaks(1)
            }
        case "postpone":
            requestBreakAction(.postpone)
        case "skip":
            requestBreakAction(.skip)
        case "finish":
            requestBreakAction(.finish)
        case "pause":
            let duration = command.durationToMs(untilMorningMillis: UntilMorning.msToSunrise(settings: settings))
            if duration == -1 {
                Log.error("Caesura: error when parsing duration to ms because of invalid value")
                return
            }
            pauseBreaks(duration)
        case "preferences":
            createPreferencesWindow()
        default:
            break
        }
    }

    /// Legacy forwards postpone/skip/finish to the visible break window, where the
    /// renderer enforces policy and run-once semantics.
    private enum BreakAction { case postpone, skip, finish }

    private func requestBreakAction(_ action: BreakAction) {
        guard let session = breakSession, session.hasVisibleWindow, let state = session.contentState else {
            Log.info("Caesura: cannot \(action) break (source: cli): no active break window")
            return
        }
        let model = session.model
        let passed = SystemClock().nowMillis - model.started
        let passedPercent = Double(passed) / Double(model.duration) * 100
        switch action {
        case .postpone:
            if !state.manualAwait, passed < model.duration,
               Utils.canPostpone(postpone: model.postponable, passedPercent: passedPercent,
                                 postponePercent: model.postponableDurationPercent) {
                session.onPostpone?()
            } else {
                Log.info("Caesura: cannot postpone break (source: cli): postponement is not allowed right now")
            }
        case .skip:
            if !state.manualAwait, passed < model.duration,
               Utils.canSkip(strictMode: model.strictMode, postpone: model.postponable,
                             passedPercent: passedPercent, postponePercent: model.postponableDurationPercent) {
                session.onSkip?()
            } else {
                Log.info("Caesura: cannot skip break (source: cli): skipping is not allowed right now")
            }
        case .finish:
            if state.manualAwait {
                health.decrease(-HealthPolicy.completed(mini: model.mini))
                // The end sound already played when the manual await phase was entered;
                // the Finish button behaves the same way.
                if model.mini {
                    finishMicrobreak(shouldPlaySound: false, shouldPlanNext: true, outcome: .elapsed)
                } else {
                    finishBreak(shouldPlaySound: false, shouldPlanNext: true, outcome: .elapsed)
                }
            } else {
                Log.info("Caesura: cannot finish break (source: cli): break is not waiting for manual finish")
            }
        }
    }

    // MARK: Settings changes (legacy save-setting semantics)

    func saveSetting(key: String, value: SettingsValue) {
        if key == "naturalBreaks" {
            planner.naturalBreaks(shouldUse: value.boolValue ?? false)
        }
        if key == "monitorDnd" {
            planner.doNotDisturb(shouldUse: value.boolValue ?? false)
        }
        if key == "language" {
            localization.setLanguage(value.stringValue ?? "en")
        }
        if key == "themeSource" {
            settings.set("themeSource", value)
            applyThemeSource()
        }
        // Legacy quirks: saving these keys also writes their mini counterparts.
        if key == "longBreakAudio" {
            settings.set("miniBreakAudio", value)
        }
        if key == "mainColor" {
            settings.set("miniBreakColor", value)
        }
        if key == "pauseFullscreenVideo", value.boolValue == true {
            // Reading and pressing the controls of another application needs
            // the accessibility permission: the user is asked for it when the
            // feature is switched on.
            VideoPlayback.requestAccessibilityPermission()
        }
        if key == "showTrayIcon" {
            settings.set("showTrayIcon", value)
            if value.boolValue == false {
                statusBar.remove()
            }
        }
        if key == "openAtLogin" {
            if AppPaths.isIsolatedRun {
                Log.info("Caesura: isolated run, not touching the login item")
            } else {
                LoginItemManager.setEnabled(value.boolValue ?? false)
            }
        }
        if key == "breakHealthMode" && value.boolValue == false {
            health.setMode(enabled: false)
        }
        settings.set(key, value)
        statusBar.refresh()
    }

    /// Reinitialize-on-change behaviors that legacy handled in `initialize(false)`.
    private func handleSettingChanged(key: String) {
        switch key {
        case "language":
            statusBar.refresh()
            refreshOpenWindows()
            reloadIdeaDecks()
        case "useIdeasFromSettings", "breakIdeas", "microbreakIdeas":
            reloadIdeaDecks()
        case "themeSource":
            statusBar.refreshIcon()
        case "naturalBreaks", "monitorDnd", "appExclusions", "appExclusionsCheckInterval",
             "naturalBreaksInactivityResetTime", "naturalBreaksCheckInterval", "monitorDndCheckInterval":
            planner.reinitializeMachines()
            // Recreate the monitors: they capture their check interval when they start,
            // so a running monitor would otherwise keep the old cadence.
            restartMonitors()
        case "trayIconStyle", "useMonochromeTrayIcon", "trayIconThemeSource", "showTrayIcon":
            statusBar.refresh()
        case "breakHealthMode":
            health.setMode(enabled: settings.getBool("breakHealthMode"))
        case "endBreakShortcut":
            // The end-break shortcut only exists during a break, but its accelerator
            // may be edited while one is running.
            if breakSession != nil {
                registerEndBreakShortcut()
            }
        default:
            break
        }
        if shortcutSettingsKeys.contains(key) {
            registerHotkeys()
        }
    }

    func restoreDefaults() {
        let alert = NSAlert()
        alert.messageText = localization.t("main.restoreDefaults")
        alert.informativeText = localization.t("main.warning")
        alert.addButton(withTitle: localization.t("main.continue"))
        alert.addButton(withTitle: localization.t("main.cancel"))
        alert.alertStyle = .warning
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Log.info("Caesura: restoring default settings")
            var defaults = DefaultSettings.values
            defaults["isFirstRun"] = .bool(false)
            settings.updateWithoutNotification(defaults)
            initialize(isAppStart: false)
        }
    }

    // MARK: Windows

    func openExternal(_ urlString: String) {
        guard let url = URL(string: urlString), urlString.hasPrefix("https://") || urlString.hasPrefix("mailto:") else { return }
        NSWorkspace.shared.open(url)
    }

    /// The first run: a toast under the menu bar icon that says that Caesura
    /// is running. It is the whole first-run experience — the app stays in the
    /// menu bar and the toast fades away on its own.
    ///
    /// An isolated run (the tests) leaves the display of the user untouched:
    /// the toast hangs under the menu bar icon, which is on the display of the
    /// user. It is only shown when the run explicitly allows the main display.
    private func showRunningToast() {
        let allowsMainDisplay = ProcessInfo.processInfo.environment["CAESURA_NATIVE_TEST_MAIN_DISPLAY"] == "1"
        guard !AppPaths.isIsolatedRun || allowsMainDisplay else {
            Log.info("Caesura: an isolated run does not show the first-run toast")
            return
        }
        guard let anchor = statusBar?.statusItemButtonScreenFrame else {
            Log.info("Caesura: no menu bar icon to point at, the toast is skipped")
            return
        }
        let view = ToastView(title: localization.t("toast.runningTitle"),
                             message: localization.t("toast.runningBody")) { [weak self] in
            self?.toast?.dismiss()
        }
        let hosting = NSHostingView(rootView: view)
        let toast = ToastWindow(content: hosting)
        self.toast = toast
        toast.present(anchor: anchor)
        Log.info("Caesura: the first-run toast points at the menu bar icon")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.captureWindowShots(tag: "toast")
        }
    }

    func createPreferencesWindow() {
        if let preferencesWindow, !preferencesWindow.isClosed {
            preferencesWindow.show()
            return
        }
        let maxHeight = screenManager.displayBounds(-1).height * 0.9
        let window = NSWindow(contentRect: NSRect(x: screenManager.displayX(-1, width: 600),
                                                  y: screenManager.displayY(-1, height: 530),
                                                  width: 600, height: 530),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = localization.t("preferences.title")
        window.setContentSize(NSSize(width: 600, height: min(530, maxHeight)))
        let controller = PreferencesController(localization: localization, settings: settings, coordinator: self)
        preferencesController = controller
        window.contentView = NSHostingView(rootView: PreferencesView(controller: controller))
        window.center()
        let owner = OwnedWindow(window: window)
        // The user grants the permission in the system settings: the window
        // becomes key again when they come back, and the state of the
        // permission is read again.
        let keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.preferencesController?.refreshAccessibilityState()
        }
        owner.onClosed = { [weak self, weak owner, weak window] in
            guard let self, let owner else { return }
            NotificationCenter.default.removeObserver(keyObserver)
            if let window { self.lifecycleRecordClosedWindow("preferences", window) }
            if self.preferencesWindow === owner {
                self.preferencesWindow = nil
                self.preferencesController = nil
            }
        }
        preferencesWindow = owner
        owner.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.captureWindowShots(tag: "preferences")
        }
    }

    /// The window with the poem of the rotation: the whole poem, its name and
    /// its author.
    ///
    /// Reading the poem is quiet: the window never opens by itself, it does not
    /// start a break, and it does not count a showing — the poem is only shown
    /// by the breaks.
    func createPoemWindow() {
        if let poemWindow, !poemWindow.isClosed {
            poemWindow.show()
            return
        }
        guard let poem = poemRotation?.poem() else {
            Log.warn("Caesura: no poem, the poem window stays closed")
            return
        }
        let window = NSWindow(contentRect: NSRect(x: screenManager.displayX(-1, width: 620),
                                                  y: screenManager.displayY(-1, height: 560),
                                                  width: 620, height: 560),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = localization.t("main.todaysPoem")
        window.contentView = NSHostingView(rootView: PoemWindowView(poem: poem,
                                                                    imagesDirectory: AppPaths.imagesDirectory()))
        window.center()
        let owner = OwnedWindow(window: window)
        owner.onClosed = { [weak self, weak owner, weak window] in
            guard let self, let owner else { return }
            if let window { self.lifecycleRecordClosedWindow("poem", window) }
            if self.poemWindow === owner {
                self.poemWindow = nil
            }
        }
        poemWindow = owner
        owner.show()
        Log.info("Caesura: showing the poem of the rotation")
    }

    // MARK: Debug info (legacy show-debug)

    func debugInfo() -> [String] {
        [
            planner.scheduler.reference ?? "null",
            planner.scheduler.timeLeft.map { localization.formatTimeRemaining(max(0, $0)) } ?? "null",
            String(planner.breakNumber),
            String(planner.postponesNumber),
            settings.url.path,
            Log.logFileURL.path,
            planner.dndMachine.isOnDnd ? "true" : "false",
            AppPaths.imagesDirectory().path,
            AppPaths.audioDirectory().path,
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        ]
    }
}

// MARK: Lifecycle regression test (development only)
//
// The opt-in lifecycle runner (`CAESURA_LIFECYCLE_TEST`) drives the real windows
// of the app. Only the runner calls these hooks; a normal run never does.

extension AppCoordinator {
    func lifecycleOpenPreferences() { createPreferencesWindow() }
    func lifecycleClosePreferences() { preferencesWindow?.close() }

    func lifecycleStartMiniBreak() { startMicrobreak() }
    func lifecyclePostponeBreak() { breakSession?.onPostpone?() }
    func lifecycleSkipBreak() { breakSession?.onSkip?() }
    func lifecycleQuit() { NSApp.terminate(nil) }

    /// Verification hook: hides the menu bar item so the restoration path of
    /// `StatusBarController.refresh()` can be exercised.
    func lifecycleHideTray() { statusBar.hideStatusItemForVerification() }

    /// Verification hook: posts the real didChangeScreenParametersNotification, so
    /// the test drives the registered production handler (including its
    /// breakSession guard) instead of a copy of it.
    func lifecycleRelayout() {
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// True while the running break has at least one visible window.
    func lifecycleBreakWindowVisible() -> Bool {
        breakSession?.hasVisibleWindow ?? false
    }

    /// Remembers a closed window weakly, so the lifecycle test can check that it
    /// was really released.
    func lifecycleRecordClosedWindow(_ name: String, _ window: NSWindow) {
        lifecycleWindowProbes[name] = WeakWindow(window)
    }

    /// True when the window with that name was released after its close.
    func lifecycleWindowReleased(_ name: String) -> Bool {
        guard let probe = lifecycleWindowProbes[name] else { return false }
        return probe.window == nil
    }
}
