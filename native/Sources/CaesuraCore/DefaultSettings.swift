import Foundation

/// Safety rules for known settings:
/// values outside the legacy preferences-UI slider ranges are preserved (advanced JSON
/// users and short isolated smoke-test durations rely on that). Only values that are
/// invalid or unsafe (wrong type, non-finite, negative, non-integer counts, zero
/// durations) fall back to the default for that key.
public enum SettingsPolicy {
    /// Known numeric keys that must be a finite number > 0 (durations and intervals).
    public static let positiveMillisKeys: Set<String> = [
        "microbreakDuration", "microbreakInterval", "breakDuration",
        "microbreakNotificationInterval", "breakNotificationInterval",
        "microbreakPostponeTime", "breakPostponeTime",
        "naturalBreaksInactivityResetTime", "naturalBreaksCheckInterval",
        "monitorDndCheckInterval", "appExclusionsCheckInterval"
    ]

    /// Known numeric keys that must be a finite number >= 0.
    public static let nonNegativeNumberKeys: Set<String> = [
        "opacity", "volume", "currentTimeInBreaksFontSize",
        "microbreakPostponableDurationPercent", "breakPostponableDurationPercent"
    ]

    /// Known numeric keys that may be any finite number: coordinates can be negative
    /// (west/south of the reference meridian) and legacy stores them unchanged.
    public static let finiteNumberKeys: Set<String> = [
        "posLatitude", "posLongitude"
    ]

    /// Counts that must be integral and >= 0. Zero is a valid legacy value:
    /// `breakInterval: 0` means a long break after every Mini break, and a postpone
    /// limit of 0 forbids postponing.
    public static let nonNegativeCountKeys: Set<String> = [
        "breakInterval", "microbreakPostponesLimit", "breakPostponesLimit"
    ]

    /// Counts that must be integral and stay inside their range. A value of the
    /// wrong type, a fractional value or a value outside the range falls back to
    /// the default of the key.
    public static let boundedCountKeys: [String: ClosedRange<Int>] = [
        "poemFullRepeats": 0...9
    ]

    /// Multipliers that must be finite and stay inside their range. A value of
    /// the wrong type or a non-finite value falls back to the default of the
    /// key, a value outside the range is clamped into it.
    public static let boundedDoubleKeys: [String: ClosedRange<Double>] = [
        PoemSpacing.settingKey: PoemSpacing.minimumFactor...PoemSpacing.maximumFactor
    ]

    public static let booleanKeys: Set<String> = [
        "breakNotification", "microbreakNotification", "microbreak", "break",
        "microbreakStrictMode", "breakStrictMode", "microbreakPostpone", "breakPostpone",
        "transparentMode", "blurredBackground", "fullscreen", "ideas", "naturalBreaks",
        "useIdeasFromSettings", "notifyNewVersion", "isFirstRun", "useMonochromeTrayIcon",
        "silentNotifications", "monitorDnd", "currentTimeInBreaks", "checkNewVersion",
        "showBreaksAsRegularWindows", "pauseForSuspendOrLock", "showTrayIcon",
        "showTrayMenuInStrictMode", "disableAppUpdateFeatures", "hidePreferencesFileLocation",
        "hideStrictModePreferences", "miniBreakManualFinish", "longBreakManualFinish",
        "breakHealthMode", "openAtLogin", "_migratedOpenAtLogin",
        "pauseFullscreenVideo"
    ]

    public static let stringKeys: Set<String> = [
        "mainColor", "miniBreakColor", "longBreakAudio", "miniBreakAudio",
        "miniBreakStartSound", "longBreakStartSound", "language", "themeSource",
        "endBreakShortcut", "screen", "breakContentScreen", "trayIconStyle",
        "currentTimeInBreaksFormat", "customPreferencesMessage",
        "trayIconThemeSource",
        "pauseBreaksToggleShortcut", "pauseBreaksFor30MinutesShortcut",
        "pauseBreaksFor1HourShortcut", "pauseBreaksFor2HoursShortcut",
        "pauseBreaksFor5HoursShortcut", "pauseBreaksUntilMorningShortcut",
        "skipToNextScheduledBreakShortcut", "skipToNextMiniBreakShortcut",
        "skipToNextLongBreakShortcut", "resetBreaksShortcut", "startLastBreakAgainShortcut"
    ]

    public static let arrayKeys: Set<String> = [
        "appExclusions", "breakIdeas", "microbreakIdeas",
        MediaAllowedApplication.settingKey
    ]

    /// Returns the replacement value when `value` is unsafe for `key`, or nil when valid.
    public static func sanitized(key: String, value: SettingsValue, default defaultValue: SettingsValue) -> SettingsValue? {
        switch key {
        case let key where positiveMillisKeys.contains(key):
            guard let d = value.doubleValue, d.isFinite, d > 0 else { return defaultValue }
            return nil
        case let key where nonNegativeNumberKeys.contains(key):
            guard let d = value.doubleValue, d.isFinite, d >= 0 else { return defaultValue }
            return nil
        case let key where finiteNumberKeys.contains(key):
            guard let d = value.doubleValue, d.isFinite else { return defaultValue }
            return nil
        case let key where nonNegativeCountKeys.contains(key):
            guard let d = value.doubleValue, d.isFinite, d >= 0, d == d.rounded(.towardZero) else {
                return defaultValue
            }
            return nil
        case let key where boundedCountKeys[key] != nil:
            guard let range = boundedCountKeys[key],
                  let d = value.doubleValue, d.isFinite, d == d.rounded(.towardZero),
                  range.contains(Int(d)) else { return defaultValue }
            return nil
        case let key where boundedDoubleKeys[key] != nil:
            guard let range = boundedDoubleKeys[key],
                  let d = value.doubleValue, d.isFinite else { return defaultValue }
            return SettingsValue.double(min(max(d, range.lowerBound), range.upperBound))
        case "morningHour":
            // Either an hour of the day or the string "sunrise".
            guard isMorningHourValue(value) else { return defaultValue }
            return nil
        case let key where booleanKeys.contains(key):
            guard value.boolValue != nil else { return defaultValue }
            return nil
        case let key where stringKeys.contains(key):
            guard value.stringValue != nil else { return defaultValue }
            return nil
        case let key where arrayKeys.contains(key):
            guard value.arrayValue != nil else { return defaultValue }
            return nil
        default:
            return nil // unknown key: preserved untouched
        }
    }

    /// Hour-of-day for morning; numeric 0–23 or the string "sunrise" (legacy allows any
    /// number; out-of-range hours are preserved like legacy, only type-checked).
    public static func isMorningHourValue(_ value: SettingsValue) -> Bool {
        if value.stringValue == "sunrise" { return true }
        return value.isFiniteNumber
    }
}

public enum DefaultSettings {
    /// Defaults for new Caesura profiles. Imported settings retain their existing values.
    public static let values: [String: SettingsValue] = [
        "microbreakDuration": .int(20000),
        "microbreakInterval": .int(600000),
        "breakDuration": .int(300000),
        "breakInterval": .int(2),
        "breakNotification": .bool(true),
        "microbreakNotification": .bool(true),
        "breakNotificationInterval": .int(30000),
        "microbreakNotificationInterval": .int(10000),
        "microbreak": .bool(true),
        "break": .bool(true),
        "microbreakStrictMode": .bool(false),
        "breakStrictMode": .bool(false),
        "morningHour": .int(6),
        "microbreakPostpone": .bool(true),
        "breakPostpone": .bool(true),
        "microbreakPostponeTime": .int(120000),
        "breakPostponeTime": .int(300000),
        "microbreakPostponesLimit": .int(1),
        "microbreakPostponableDurationPercent": .int(30),
        "breakPostponesLimit": .int(1),
        "breakPostponableDurationPercent": .int(30),
        "mainColor": .string("#478484"),
        "miniBreakColor": .string("#478484"),
        "transparentMode": .bool(false),
        "blurredBackground": .bool(false),
        "opacity": .double(0.9),
        "longBreakAudio": .string("crystal-glass"),
        "miniBreakAudio": .string("crystal-glass"),
        "volume": .int(1),
        "fullscreen": .bool(false),
        "ideas": .bool(true),
        "naturalBreaks": .bool(true),
        "naturalBreaksInactivityResetTime": .int(300000),
        "naturalBreaksCheckInterval": .int(2000),
        "allScreens": .bool(true),
        "useIdeasFromSettings": .bool(false),
        "language": .string("en"),
        "notifyNewVersion": .bool(true),
        "isFirstRun": .bool(true),
        "posLatitude": .double(0.0),
        "posLongitude": .double(0.0),
        "useMonochromeTrayIcon": .bool(false),
        "trayIconThemeSource": .string("system"),
        "silentNotifications": .bool(false),
        "monitorDnd": .bool(true),
        "monitorDndCheckInterval": .int(2000),
        "miniBreakStartSound": .string("silence"),
        "longBreakStartSound": .string("silence"),
        "themeSource": .string("system"),
        "endBreakShortcut": .string("CmdOrCtrl+X"),
        "breakWindowWidth": .double(0.85),
        "breakWindowHeight": .double(0.85),
        "checkNewVersion": .bool(true),
        "breakIdeas": .array([]),
        "microbreakIdeas": .array([]),
        "showBreaksAsRegularWindows": .bool(false),
        "appExclusions": .array([]),
        "appExclusionsCheckInterval": .int(2000),
        "pauseForSuspendOrLock": .bool(true),
        "pauseBreaksToggleShortcut": .string(""),
        "pauseBreaksFor30MinutesShortcut": .string(""),
        "pauseBreaksFor1HourShortcut": .string(""),
        "pauseBreaksFor2HoursShortcut": .string(""),
        "pauseBreaksFor5HoursShortcut": .string(""),
        "pauseBreaksUntilMorningShortcut": .string(""),
        "screen": .string("primary"),
        "breakContentScreen": .string("all"),
        "trayIconStyle": .string("default"),
        "currentTimeInBreaks": .bool(false),
        "currentTimeInBreaksFontSize": .int(28),
        "currentTimeInBreaksFormat": .string("tt"),
        "showTrayIcon": .bool(true),
        "skipToNextScheduledBreakShortcut": .string(""),
        "skipToNextMiniBreakShortcut": .string(""),
        "skipToNextLongBreakShortcut": .string(""),
        "resetBreaksShortcut": .string(""),
        "startLastBreakAgainShortcut": .string(""),
        "showTrayMenuInStrictMode": .bool(false),
        "customPreferencesMessage": .string(""),
        "disableAppUpdateFeatures": .bool(false),
        "hidePreferencesFileLocation": .bool(false),
        "hideStrictModePreferences": .bool(false),
        // Native-only: a video that plays in fullscreen is paused during a
        // break and resumed when it ends.
        "pauseFullscreenVideo": .bool(true),
        // Native-only: the applications whose media session keeps playing
        // during a break. Every other media session is paused and resumed.
        MediaAllowedApplication.settingKey: .array(MediaAllowedApplication.defaults.map(\.settingsValue)),
        "miniBreakManualFinish": .bool(false),
        "longBreakManualFinish": .bool(false),
        "breakHealthMode": .bool(false),
        "openAtLogin": .bool(false),
        "_migratedOpenAtLogin": .bool(false),
        // Native-only: how often the complete poem is repeated before the
        // rotation shows the next poem.
        "poemFullRepeats": .int(2),
        // Native-only: the multiplier of the spacing of the lines of a poem
        // (the base spacing times this factor).
        PoemSpacing.settingKey: .double(PoemSpacing.defaultFactor),
        // Native-only: persisted poem rotation state (order/position/showings).
        "poemRotation": .object([:])
    ]
}
