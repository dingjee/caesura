import Foundation

/// The spacing of the lines of a poem: a multiplier of the base spacing.
///
/// The base spacing is the one the window measures the poem with (a share of
/// its height); the multiplier is the preference of the reader. It is a
/// persisted Double: a missing key falls back to the default, an illegal
/// value (a wrong type, a non-finite number) falls back to the default and a
/// value outside the range is clamped into it — the storage applies the same
/// rule when the file is read, this is the second line of defence.
public enum PoemSpacing {
    /// The key of the setting.
    public static let settingKey = "poemLineSpacing"
    /// The default multiplier: the base spacing times 1.2.
    public static let defaultFactor: Double = 1.2
    /// The smallest multiplier the preferences offer.
    public static let minimumFactor: Double = 1.0
    /// The largest multiplier the preferences offer.
    public static let maximumFactor: Double = 2.0
    /// The step of the preferences slider.
    public static let step: Double = 0.1

    /// The multiplier of the settings: a missing or illegal value falls back
    /// to the default, a value outside the range is clamped into it.
    public static func factor(settings: SettingsStore) -> Double {
        factor(raw: settings.getBoundedDouble(settingKey))
    }

    /// The multiplier of a raw value: an illegal value falls back to the
    /// default, a value outside the range is clamped into it.
    public static func factor(raw: Double) -> Double {
        guard raw.isFinite else { return defaultFactor }
        return min(max(raw, minimumFactor), maximumFactor)
    }

    /// The spacing of the lines of a poem: the base spacing of the window
    /// times the multiplier of the reader.
    public static func spacing(base: Double, multiplier: Double) -> Double {
        base * factor(raw: multiplier)
    }
}
