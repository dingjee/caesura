import Foundation

/// State machines fed by application pollers (idle seconds, DND probe, process list).
/// The logic is a direct port of the legacy NaturalBreaksManager / DndManager /
/// AppExclusionsManager event logic; the actual data sources are native and live in
/// the application target.

/// Port of NaturalBreaksManager._checkIdleTime.
public final class IdleStateMachine {
    public private(set) var isOnNaturalBreak = false
    public private(set) var isSchedulerCleared = false
    public private(set) var lastIdleMillis: Int64 = 0
    public let inactivityResetMillis: Int64

    public enum Output: Equatable {
        case none
        case clearBreakScheduler
        case naturalBreakFinished
    }

    public init(inactivityResetMillis: Int64) {
        self.inactivityResetMillis = inactivityResetMillis
    }

    public func stop() {
        isOnNaturalBreak = false
        isSchedulerCleared = false
        lastIdleMillis = 0
    }

    public func update(idleMillis: Int64) -> Output {
        var output: Output = .none
        if !isOnNaturalBreak && idleMillis > 20000 {
            isOnNaturalBreak = true
        }
        if isOnNaturalBreak && idleMillis < 20000 {
            isOnNaturalBreak = false
            if lastIdleMillis > inactivityResetMillis {
                isSchedulerCleared = false
                output = .naturalBreakFinished
            }
        }
        if isOnNaturalBreak && idleMillis > inactivityResetMillis {
            isSchedulerCleared = true
            output = .clearBreakScheduler
        }
        lastIdleMillis = idleMillis
        return output
    }
}

/// DND state toggle logic (the macOS data source is the Focus heuristic adapter).
public final class DndStateMachine {
    public private(set) var isOnDnd = false

    public enum Output: Equatable {
        case none
        case dndStarted
        case dndFinished
    }

    public init() {}

    public func stop() {
        isOnDnd = false
    }

    /// Legacy mutates `isOnDnd` directly when DND starts during an active break.
    public func forceOff() {
        isOnDnd = false
    }

    public func update(enabled: Bool) -> Output {
        if !isOnDnd && enabled {
            isOnDnd = true
            return .dndStarted
        }
        if isOnDnd && !enabled {
            isOnDnd = false
            return .dndFinished
        }
        return .none
    }
}

/// Port of AppExclusionsManager. Tracks the first active rule and its matched command.
public final class ExclusionsStateMachine {
    public struct Rule: Equatable {
        public var name: String?
        public var active: Bool
        public var rule: String // "pause" | "resume"
        public var commands: [String]
        public init(name: String? = nil, active: Bool, rule: String, commands: [String]) {
            self.name = name
            self.active = active
            self.rule = rule
            self.commands = commands
        }

        public static func from(settingsValue: SettingsValue?) -> Rule? {
            guard let object = settingsValue?.objectValue,
                  let active = object["active"]?.boolValue,
                  let rule = object["rule"]?.stringValue else { return nil }
            let commands = (object["commands"]?.arrayValue ?? []).compactMap(\.stringValue)
            return Rule(name: object["name"]?.stringValue, active: active, rule: rule, commands: commands)
        }
    }

    public private(set) var appExclusion: Rule?
    public private(set) var isOnAppExclusion = false

    public init(rule: Rule?) {
        appExclusion = rule
        reset()
    }

    /// Matches like legacy `_runningAppExclusion`: command or name contains the pattern.
    public func matchedCommand(in processes: [ProcessSnapshotEntry]) -> String? {
        guard let exclusion = appExclusion, exclusion.active else { return nil }
        for command in exclusion.commands {
            if processes.contains(where: {
                ($0.command?.contains(command) ?? false) || ($0.name?.contains(command) ?? false)
            }) {
                return command
            }
        }
        return nil
    }

    public func reset() {
        isOnAppExclusion = false
        if let appExclusion, appExclusion.active {
            isOnAppExclusion = appExclusion.rule == "resume"
        }
    }

    /// Legacy assigns `isOnAppExclusion` directly in a few fallback branches.
    public func forceOn() {
        isOnAppExclusion = true
    }

    public func forceOff() {
        isOnAppExclusion = false
    }

    public var isSchedulerCleared: Bool {
        guard let appExclusion, appExclusion.active else { return false }
        if appExclusion.rule == "pause" {
            return isOnAppExclusion
        }
        return !isOnAppExclusion
    }

    public enum Output: Equatable {
        case none
        case started(rule: String, matched: String)
        case finished(rule: String)
    }

    public func update(matched: String?) -> Output {
        if !isOnAppExclusion, let matched {
            isOnAppExclusion = true
            return .started(rule: appExclusion?.rule ?? "pause", matched: matched)
        }
        if isOnAppExclusion, matched == nil {
            isOnAppExclusion = false
            return .finished(rule: appExclusion?.rule ?? "pause")
        }
        return .none
    }
}

/// Snapshot of one running process used by exclusion matching.
public struct ProcessSnapshotEntry {
    public var name: String?
    public var command: String?
    public init(name: String?, command: String?) {
        self.name = name
        self.command = command
    }
}
