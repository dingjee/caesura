import Foundation

/// Decides which menu bar appearance to render.
/// The native app draws the icon itself (template mono / colour / progress ring /
/// minutes number); this descriptor carries the decision, testable without AppKit.
public struct TrayIconDescriptor: Equatable {
    public var paused: Bool
    public var monochrome: Bool
    public var darkAppearance: Bool
    public var trayIconStyle: String // default | time | progress
    public var minutesRemaining: Int
    public var percentage: Int
    public var reference: String?

    public init(paused: Bool, monochrome: Bool, darkAppearance: Bool, trayIconStyle: String,
                minutesRemaining: Int, percentage: Int, reference: String?) {
        self.paused = paused
        self.monochrome = monochrome
        self.darkAppearance = darkAppearance
        self.trayIconStyle = trayIconStyle
        self.minutesRemaining = minutesRemaining
        self.percentage = percentage
        self.reference = reference
    }

    public init(planner: BreaksPlanner, settings: SettingsStore, darkAppearance: Bool) {
        self.paused = planner.isPaused ||
            planner.dndMachine.isOnDnd ||
            planner.idleMachine.isSchedulerCleared ||
            planner.exclusionsMachine.isSchedulerCleared
        self.monochrome = settings.getBool("useMonochromeTrayIcon")
        self.darkAppearance = darkAppearance
        self.trayIconStyle = settings.getString("trayIconStyle")
        self.minutesRemaining = Utils.minutesRemaining(planner.timeToNextBreak)
        self.percentage = planner.progressPercentage
        self.reference = planner.scheduler.reference
    }

    /// Legacy rule: numeric suffixes only while a break is not running/finished.
    public var showsNumericSuffix: Bool {
        if paused || reference == "finishMicrobreak" || reference == "finishBreak" { return false }
        return true
    }

    public enum Appearance: Equatable {
        case icon(paused: Bool, monochrome: Bool, dark: Bool)
        case progress(percent: Int, paused: Bool, monochrome: Bool, dark: Bool)
        case minutes(Int, paused: Bool, monochrome: Bool, dark: Bool)
    }

    public var appearance: Appearance {
        if showsNumericSuffix && trayIconStyle == "progress" && (0...100).contains(percentage) {
            return .progress(percent: percentage, paused: paused, monochrome: monochrome, dark: darkAppearance)
        }
        if showsNumericSuffix && trayIconStyle == "time" && (0...99).contains(minutesRemaining) {
            return .minutes(minutesRemaining, paused: paused, monochrome: monochrome, dark: darkAppearance)
        }
        return .icon(paused: paused, monochrome: monochrome, dark: darkAppearance)
    }
}
