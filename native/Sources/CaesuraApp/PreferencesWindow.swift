import SwiftUI
import CaesuraCore

/// Native preferences for the schedule, poetry, appearance and application.
final class PreferencesController: ObservableObject {
    let localization: Localization
    let settings: SettingsStore
    weak var coordinator: AppCoordinator?
    @Published var snapshot: [String: SettingsValue]
    /// True when macOS lets the app read and press the controls of another
    /// application. The permission is granted in the system settings, so the
    /// state can change while the app is in the background.
    @Published var accessibilityAllowed = FullscreenVideo.canUseAccessibility

    init(localization: Localization, settings: SettingsStore, coordinator: AppCoordinator) {
        self.localization = localization
        self.settings = settings
        self.coordinator = coordinator
        self.snapshot = settings.values
    }

    func reload(settings: SettingsStore, localization: Localization) {
        snapshot = settings.values
        objectWillChange.send()
    }

    /// Reads the permission again: the user may have granted it in the system
    /// settings in the meantime.
    func refreshAccessibilityState() {
        let allowed = FullscreenVideo.canUseAccessibility
        guard allowed != accessibilityAllowed else { return }
        accessibilityAllowed = allowed
        Log.info("Caesura: the accessibility permission was granted")
    }

    // MARK: Typed accessors

    func bool(_ key: String) -> Binding<Bool> {
        Binding(get: { [weak self] in
            self?.settings.getBool(key) ?? false
        }, set: { [weak self] newValue in
            self?.coordinator?.saveSetting(key: key, value: .bool(newValue))
            self?.snapshot = self?.settings.values ?? [:]
        })
    }

    func string(_ key: String) -> Binding<String> {
        Binding(get: { [weak self] in
            self?.settings.getString(key) ?? ""
        }, set: { [weak self] newValue in
            self?.coordinator?.saveSetting(key: key, value: .string(newValue))
            self?.snapshot = self?.settings.values ?? [:]
        })
    }

    /// Legacy renders checkboxes marked `negative` with the inverted value: the
    /// "Show breaks even in Do Not Disturb mode" box is checked when the DND
    /// *monitoring* is off.
    func invertedBool(_ key: String) -> Binding<Bool> {
        Binding(get: { [weak self] in
            !(self?.settings.getBool(key) ?? false)
        }, set: { [weak self] newValue in
            self?.coordinator?.saveSetting(key: key, value: .bool(!newValue))
            self?.snapshot = self?.settings.values ?? [:]
        })
    }

    /// Legacy refuses to disable the last remaining break type and explains why.
    func toggleBreakType(key: String, enabled: Bool) {
        if !enabled {
            let otherKey = key == "microbreak" ? "break" : "microbreak"
            if !settings.getBool(otherKey) {
                let alert = NSAlert()
                alert.messageText = localization.t("preferences.schedule.cantDisableBoth")
                alert.informativeText = localization.t("preferences.schedule.cantDisableBoth")
                alert.addButton(withTitle: localization.t("main.continue"))
                alert.runModal()
                snapshot = settings.values
                return
            }
        }
        coordinator?.saveSetting(key: key, value: .bool(enabled))
        snapshot = settings.values
    }

    /// Range slider binding over a millis value with a divisor (legacy sliders).
    func slider(_ key: String, divisor: Double) -> Binding<Double> {
        Binding(get: { [weak self] in
            Double(self?.settings.getMillis(key) ?? 0) / divisor
        }, set: { [weak self] newValue in
            self?.coordinator?.saveSetting(key: key, value: .int(Int64((newValue * divisor).rounded())))
            self?.snapshot = self?.settings.values ?? [:]
        })
    }

    /// How often the complete poem is shown again before the rotation shows the
    /// next poem.
    func poemFullRepeats() -> Binding<Int> {
        Binding(get: { [weak self] in
            self?.settings.getBoundedCount(PoemRotation.extraRepeatsKey)
                ?? PoemRotation.defaultExtraRepeats
        }, set: { [weak self] newValue in
            self?.coordinator?.saveSetting(key: PoemRotation.extraRepeatsKey,
                                           value: .int(Int64(newValue)))
            self?.snapshot = self?.settings.values ?? [:]
        })
    }

    /// The opacity slider: a percent (0–100) over the stored fraction, kept a
    /// Double end to end. The old millis/integer binding showed the default 0.9
    /// as 0 % and collapsed every intermediate value to 0 or 1.
    func opacityPercent() -> Binding<Double> {
        Binding(get: { [weak self] in
            Utils.opacityPercent(fromStored: self?.settings.getDouble("opacity") ?? 0.9)
        }, set: { [weak self] newValue in
            self?.coordinator?.saveSetting(key: "opacity",
                                           value: .double(Utils.storedOpacity(fromPercent: newValue)))
            self?.snapshot = self?.settings.values ?? [:]
        })
    }

    /// The single background choice over the two legacy keys: Solid =
    /// transparentMode false + blurredBackground false, Translucent = true + false,
    /// Frosted = true + true. The keys themselves are unchanged: nothing is
    /// migrated or cleared.
    ///
    /// Choosing a mode also sets the transparency of the background to the
    /// golden ratio of the mode: solid is opaque, translucent keeps 1/φ of the
    /// colour and frosted only 1/φ² — the colour stays a tint over the blurred
    /// desktop instead of hiding it. The opacity slider stays free afterwards.
    func backgroundMode() -> Binding<BackgroundMode> {
        Binding(get: { [weak self] in
            guard let self else { return .solid }
            switch (self.settings.getBool("transparentMode"), self.settings.getBool("blurredBackground")) {
            case (true, true): return .frosted
            case (true, false): return .translucent
            default: return .solid
            }
        }, set: { [weak self] mode in
            guard let self else { return }
            self.coordinator?.saveSetting(key: "transparentMode", value: .bool(mode != .solid))
            self.coordinator?.saveSetting(key: "blurredBackground", value: .bool(mode == .frosted))
            self.coordinator?.saveSetting(key: "opacity", value: .double(mode.opacity))
            self.snapshot = self.settings.values
        })
    }
}

/// The three background modes of the Appearance page.
enum BackgroundMode: Hashable, CaseIterable {
    case solid, translucent, frosted

    /// The transparency of the mode: the colour of the theme over the desktop,
    /// in the steps of the golden ratio (1, 1/φ, 1/φ²).
    var opacity: Double {
        switch self {
        case .solid: return 1
        case .translucent: return 1 / Utils.goldenRatio
        case .frosted: return 1 / (Utils.goldenRatio * Utils.goldenRatio)
        }
    }
}
struct PreferencesView: View {
    @ObservedObject var controller: PreferencesController
    @State private var tab = 0
    @State private var showDebug = false

    private var t: (String) -> String { { controller.localization.t($0) } }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(t("preferences.nav.general")).tag(0)
                Text(t("preferences.nav.breaks")).tag(1)
                Text(t("preferences.nav.appearance")).tag(2)
                Text(t("preferences.nav.about")).tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            let message = controller.settings.getString("customPreferencesMessage")
            if !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(Color.yellow.opacity(0.25))
            }

            ScrollView {
                Group {
                    switch tab {
                    case 0: settingsTab
                    case 1: scheduleTab
                    case 2: themeTab
                    default: aboutTab
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 600, minHeight: 530)
        .background(KeyEventHandler(onCommandD: { showDebug.toggle() }))
    }

    // MARK: Settings tab

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(t("preferences.settings.openAtLogin"), isOn: controller.bool("openAtLogin"))
            // One entry controls every display; the per-display choice only
            // matters when allScreens is off (and offers no "all" value).
            Toggle(t("preferences.settings.allScreens"), isOn: controller.bool("allScreens"))
            if !controller.settings.getBool("allScreens") {
                Picker(t("preferences.settings.showBreaksIn"), selection: controller.string("screen")) {
                    Text("Primary").tag("primary")
                    Text("Cursor").tag("cursor")
                    Divider()
                    ForEach(0..<4, id: \.self) { index in
                        Text("Screen \(index + 1)").tag(String(index))
                    }
                }
            }
            Toggle(t("preferences.settings.fullscreen"), isOn: controller.bool("fullscreen"))
            Toggle(t("preferences.settings.showIdeas"), isOn: controller.bool("ideas"))
            LabeledStepper(label: t("preferences.settings.poemFullRepeats"),
                           help: t("preferences.settings.poemFullRepeatsInfo"),
                           binding: controller.poemFullRepeats(),
                           range: 0...PoemRotation.maxExtraRepeats)
            Toggle(t("preferences.settings.monitorIdleTime"), isOn: controller.bool("naturalBreaks"))
            Toggle(t("preferences.settings.monitorDnd"), isOn: controller.invertedBool("monitorDnd"))
            // Language selection UI is paused (English-only release); the
            // `language` setting, Localization.setLanguage and the bundled
            // locale files stay, so restoring the picker is a one-place change.

            Divider()
            Button(t("preferences.settings.restoreDefaults")) {
                controller.coordinator?.restoreDefaults()
            }
            debugSection
        }
    }

    @ViewBuilder
    private var debugSection: some View {
        if showDebug {
            VStack(alignment: .leading, spacing: 6) {
                let info = controller.coordinator?.debugInfo() ?? []
                Text("reference: \(info.count > 0 ? info[0] : "")").font(.caption.monospaced())
                Text("timeleft: \(info.count > 1 ? info[1] : "")").font(.caption.monospaced())
                Text("breakNumber: \(info.count > 2 ? info[2] : "")").font(.caption.monospaced())
                Text("postponesNumber: \(info.count > 3 ? info[3] : "")").font(.caption.monospaced())
                if !controller.settings.getBool("hidePreferencesFileLocation") {
                    Text("settings: \(info.count > 4 ? info[4] : "")").font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("logs: \(info.count > 5 ? info[5] : "")").font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                Text("doNotDisturb: \(info.count > 6 ? info[6] : "")").font(.caption.monospaced())
                Text("platform: \(info.count > 9 ? info[9] : "")").font(.caption.monospaced())
                Button("Copy debug info") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.joined(separator: "\n"), forType: .string)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(6)
        }
        // No hint while the pane is hidden: ⌘D keeps working (KeyEventHandler).
    }

    // MARK: Schedule tab

    private var scheduleTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(label: Text(t("preferences.schedule.miniBreaks")).font(.headline)) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(t("preferences.schedule.enableMiniBreaks"), isOn: Binding(
                        get: { controller.settings.getBool("microbreak") },
                        set: { controller.toggleBreakType(key: "microbreak", enabled: $0) }))
                    LabeledSlider(label: t("preferences.schedule.breakFor"),
                                  binding: controller.slider("microbreakDuration", divisor: 1000),
                                  range: 10...600, step: 10,
                                  format: { value in controller.localization.formatUnitAndValue(unit: "seconds", value: value) })
                    LabeledSlider(label: t("preferences.schedule.every"),
                                  binding: controller.slider("microbreakInterval", divisor: 60000),
                                  range: 5...65, step: 5,
                                  format: { value in controller.localization.formatUnitAndValue(unit: "minutes", value: value) })
                    Toggle(t("preferences.schedule.showNotificationBeforeMiniBreak"),
                           isOn: controller.bool("microbreakNotification"))
                    Toggle(t("preferences.schedule.enablePostponeMini"), isOn: controller.bool("microbreakPostpone"))
                    if !controller.settings.getBool("hideStrictModePreferences") {
                        Toggle(t("preferences.schedule.enableStrictMini"), isOn: controller.bool("microbreakStrictMode"))
                            .help(t("preferences.schedule.strictModeInfo"))
                    }
                }
                .padding(6)
            }

            GroupBox(label: Text(t("preferences.schedule.longBreaks")).font(.headline)) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(t("preferences.schedule.enableLongBreaks"), isOn: Binding(
                        get: { controller.settings.getBool("break") },
                        set: { controller.toggleBreakType(key: "break", enabled: $0) }))
                    LabeledSlider(label: t("preferences.schedule.breakFor"),
                                  binding: controller.slider("breakDuration", divisor: 60000),
                                  range: 1...60, step: 1,
                                  format: { value in controller.localization.formatUnitAndValue(unit: "minutes", value: value) })
                    LabeledSlider(label: t("preferences.schedule.every"),
                                  binding: controller.slider("breakInterval", divisor: 1),
                                  range: 1...30, step: 1,
                                  format: { value in "\(Int(value)) ×" })
                    Toggle(t("preferences.schedule.showNotificationBeforeLongBreak"),
                           isOn: controller.bool("breakNotification"))
                    Toggle(t("preferences.schedule.pauseFullscreenVideo"),
                           isOn: controller.bool("pauseFullscreenVideo"))
                        .help(t("preferences.schedule.pauseFullscreenVideoInfo"))
                    if controller.settings.getBool("pauseFullscreenVideo") {
                        mediaKeyPermissionRow
                    }
                    Toggle(t("preferences.schedule.enablePostponeLong"), isOn: controller.bool("breakPostpone"))
                    if !controller.settings.getBool("hideStrictModePreferences") {
                        Toggle(t("preferences.schedule.enableStrictLong"), isOn: controller.bool("breakStrictMode"))
                            .help(t("preferences.schedule.strictModeInfo"))
                    }
                }
                .padding(6)
            }

            if !controller.settings.getBool("microbreak") && !controller.settings.getBool("break") {
                Text(t("preferences.schedule.cantDisableBoth"))
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
    }

    /// The state of the permission that reading and pressing the controls of
    /// another application needs.
    ///
    /// The permission is granted in the system settings of macOS, so the row
    /// follows the state of the system: it disappears as soon as the user
    /// allows Caesura there.
    @ViewBuilder
    private var mediaKeyPermissionRow: some View {
        if controller.accessibilityAllowed {
            Label(t("preferences.schedule.pauseFullscreenVideoPermissionGranted"),
                  systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(t("preferences.schedule.pauseFullscreenVideoPermission"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(t("preferences.schedule.grantMediaKeyPermission")) {
                    FullscreenVideo.requestAccessibilityPermission()
                }
            }
        }
    }

    // MARK: Theme tab

    private var themeTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(label: Text(t("preferences.theme.appearance")).font(.headline)) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(t("preferences.theme.background"), selection: controller.backgroundMode()) {
                        Text(t("preferences.theme.backgroundSolid")).tag(BackgroundMode.solid)
                        Text(t("preferences.theme.backgroundTranslucent")).tag(BackgroundMode.translucent)
                        Text(t("preferences.theme.backgroundFrosted")).tag(BackgroundMode.frosted)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 340)
                    if controller.backgroundMode().wrappedValue != .solid {
                        LabeledSlider(label: t("preferences.theme.opacity"),
                                      binding: controller.opacityPercent(),
                                      range: 0...100, step: 1,
                                      format: { "\(Int($0.rounded()))%" })
                    }
                    ForEach([("#478484", "preferences.theme.greenClouds"),
                             ("#633738", "preferences.theme.autumnBeBlessed"),
                             ("#ffffff", "preferences.theme.snowWhite"),
                             ("#1D1F21", "preferences.theme.graphiteCrystal"),
                             ("#A49898", "preferences.theme.coffeeKisses"),
                             ("#567890", "preferences.theme.morningSwim")], id: \.0) { hex, key in
                        HStack {
                            Circle().fill(Color(hex: hex) ?? .gray).frame(width: 16, height: 16)
                            Radio(title: t(key), selected: controller.settings.getString("mainColor") == hex) {
                                controller.coordinator?.saveSetting(key: "mainColor", value: .string(hex))
                                controller.snapshot = controller.settings.values
                            }
                        }
                    }
                    Toggle(t("preferences.theme.enableSounds"), isOn: Binding(
                        get: { !controller.settings.getBool("silentNotifications") },
                        set: { controller.coordinator?.saveSetting(key: "silentNotifications", value: .bool(!$0)) }))
                }
                .padding(6)
            }

            GroupBox(label: Text(t("preferences.theme.trayIcon")).font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(t("preferences.theme.monochrome"), isOn: controller.bool("useMonochromeTrayIcon"))
                    Picker(t("preferences.theme.colour"), selection: controller.string("trayIconThemeSource")) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .frame(width: 260)
                    Picker(t("preferences.theme.trayIconStyleLabel"), selection: controller.string("trayIconStyle")) {
                        Text(t("preferences.theme.trayIconStyleDefault")).tag("default")
                        Text(t("preferences.theme.trayIconStyleTime")).tag("time")
                        Text(t("preferences.theme.trayIconStyleProgress")).tag("progress")
                    }
                    .frame(width: 260)
                    Picker("Appearance", selection: controller.string("themeSource")) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .frame(width: 260)
                }
                .padding(6)
            }
        }
    }

    // MARK: About tab

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "text.quote")
                .font(.system(size: 40))
                .foregroundStyle(.teal)
            Text("Caesura")
                .font(.title)
            Text("A pause for poetry.")
                .font(.title2)
            Text("\(t("preferences.about.version")): \(AppPaths.version)")
            Link("Source and feedback", destination: URL(string: "https://github.com/dingjee/caesura")!)
            Link("Releases", destination: URL(string: "https://github.com/dingjee/caesura/releases")!)
            if !controller.settings.getBool("disableAppUpdateFeatures") {
                Toggle(t("preferences.about.checkNewVersion"), isOn: controller.bool("checkNewVersion"))
            }
            Text("BSD-2-Clause · Caesura contributors")
                .foregroundStyle(.secondary)
            Text("Includes work by Jan Hovancik and contributors; see ThirdPartyNotices.txt.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(PoemCatalog.attribution)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

}

/// Stepper row with a short explanation and the current number.
struct LabeledStepper: View {
    var label: String
    var help: String
    @Binding var binding: Int
    var range: ClosedRange<Int>

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Stepper(value: $binding, in: range) {
                Text("\(binding)")
                    .monospacedDigit()
                    .frame(width: 24, alignment: .trailing)
            }
            .fixedSize()
            .accessibilityLabel(label)
            .accessibilityValue("\(binding)")
        }
    }
}

/// Range slider row with live formatted output (legacy range inputs + output element).
struct LabeledSlider: View {    var label: String
    @Binding var binding: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 170, alignment: .leading)
            Slider(value: $binding, in: range, step: step)
            Text(format(binding))
                .monospacedDigit()
                .frame(width: 110, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}

struct Radio: View {
    var title: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                Text(title)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct KeyEventHandler: NSViewRepresentable {
    var onCommandD: () -> Void

    func makeNSView(context: Context) -> KeyCatcher {
        let view = KeyCatcher()
        view.onCommandD = onCommandD
        return view
    }

    func updateNSView(_ nsView: KeyCatcher, context: Context) {
        nsView.onCommandD = onCommandD
    }

    final class KeyCatcher: NSView {
        var onCommandD: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 2, event.modifierFlags.contains(.command) {
                onCommandD?()
            } else {
                super.keyDown(with: event)
            }
        }

        override var acceptsFirstResponder: Bool { true }
    }
}
