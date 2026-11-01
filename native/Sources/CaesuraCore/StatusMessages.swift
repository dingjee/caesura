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

    /// Base message without the long-break suffix (suffix needs the `break` setting).
    public static func trayMessage(_ input: Input, localization: Localization) -> String {
        var message = ""
        if input.reference == "finishMicrobreak" || input.reference == "finishBreak" {
            return message
        }

        if input.isPaused {
            if let timeLeft = input.timeLeft, timeLeft > 0 {
                message += localization.t("statusMessages.paused") + " - " +
                    localization.t("statusMessages.resuming") + " " +
                    localization.formatTimeIn(timeLeft)
                return message
            }
            message += localization.t("statusMessages.paused") + " " +
                localization.t("statusMessages.indefinitely")
            return message
        }

        if input.doNotDisturb {
            message += localization.t("statusMessages.paused") + " - " + localization.t("statusMessages.dndMode")
            return message
        }

        if input.appExclusionPause {
            message += localization.t("statusMessages.paused") + " - " + localization.t("statusMessages.appExclusion")
            return message
        }

        if input.reference == "startBreak" || input.reference == "startBreakNotification" {
            message += localization.t("statusMessages.nextLongBreak") + " " +
                localization.formatTimeIn(input.timeToNextBreak ?? 0)
            return message
        }

        if input.reference == "startMicrobreak" || input.reference == "startMicrobreakNotification" {
            message += localization.t("statusMessages.nextMiniBreak") + " " +
                localization.formatTimeIn(input.timeToNextBreak ?? 0)
            return message
        }

        return message
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
