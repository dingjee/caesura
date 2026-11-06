import Foundation

/// Localized menu bar tooltip and status text.
public enum StatusMessages {
    public struct Input {
        public var reference: String?
        public var doNotDisturb: Bool
        public var appExclusionPause: Bool
        public var timeLeft: Int64?
        public var timeToNextBreak: Int64?
        public var isPaused: Bool
        public var breakNumber: Int
        public var breakIntervalSetting: Int64

        public init(planner: BreaksPlanner, settings: SettingsStore) {
            reference = planner.scheduler.reference
            doNotDisturb = planner.dndMachine.isOnDnd
            appExclusionPause = planner.exclusionsMachine.isSchedulerCleared
            timeLeft = planner.scheduler.timeLeft
            timeToNextBreak = planner.timeToNextBreak
            isPaused = planner.isPaused
            breakNumber = planner.breakNumber
            breakIntervalSetting = settings.getMillis("breakInterval")
        }
    }

    /// The state of the planner only: paused, Do Not Disturb and an app
    /// exclusion rule. The menu bar menu shows these lines — the countdown of
    /// the next break is part of the skip items there, so it is not repeated.
    public static func stateMessage(_ input: Input, localization: Localization) -> String {
        if input.reference == "finishMicrobreak" || input.reference == "finishBreak" {
            return ""
        }
        if input.isPaused {
            if let timeLeft = input.timeLeft, timeLeft > 0 {
                return localization.t("statusMessages.paused") + " - " +
                    localization.t("statusMessages.resuming") + " " +
                    localization.formatTimeIn(timeLeft)
            }
            return localization.t("statusMessages.paused") + " " +
                localization.t("statusMessages.indefinitely")
        }
        if input.doNotDisturb {
            return localization.t("statusMessages.paused") + " - " +
                localization.t("statusMessages.dndMode")
        }
        if input.appExclusionPause {
            return localization.t("statusMessages.paused") + " - " +
                localization.t("statusMessages.appExclusion")
        }
        return ""
    }

    /// Base message without the long-break suffix (suffix needs the `break` setting).
    public static func trayMessage(_ input: Input, localization: Localization) -> String {
        let state = stateMessage(input, localization: localization)
        if !state.isEmpty { return state }

        if input.reference == "startBreak" || input.reference == "startBreakNotification" {
            return localization.t("statusMessages.nextLongBreak") + " " +
                localization.formatTimeIn(input.timeToNextBreak ?? 0)
        }

        if input.reference == "startMicrobreak" || input.reference == "startMicrobreakNotification" {
            return localization.t("statusMessages.nextMiniBreak") + " " +
                localization.formatTimeIn(input.timeToNextBreak ?? 0)
        }

        return ""
    }

    /// Full port: long-break suffix depends on the `break` setting.
    public static func trayMessage(_ input: Input, longBreaksEnabled: Bool, localization: Localization) -> String {
        let base = trayMessage(input, localization: localization)
        guard input.reference == "startMicrobreak" || input.reference == "startMicrobreakNotification" else {
            return base
        }
        if longBreaksEnabled {
            let breakInterval = Int(input.breakIntervalSetting) + 1
            let breakNumber = input.breakNumber % breakInterval
            return base + "\n" + localization.t("statusMessages.nextLongBreak") + " " +
                localization.t("statusMessages.afterMiniBreak", options: ["count": breakInterval - breakNumber])
        }
        return base
    }
}
