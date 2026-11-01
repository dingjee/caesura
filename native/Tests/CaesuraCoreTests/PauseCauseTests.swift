import Foundation
import CaesuraCore

enum PauseCauseTests {
    static func registerAll() {
        TestRunner.register("idle: >20s marks natural break", idleNatural)
        TestRunner.register("idle: return with short idle is ignored", idleShortReturn)
        TestRunner.register("idle: clear only above reset threshold", idleThreshold)
        TestRunner.register("dnd: started/finished edges", dndEdges)
        TestRunner.register("exclusions: matching is substring on name or command", exclusionMatch)
        TestRunner.register("exclusions: pause rule clears while active", exclusionPauseRule)
        TestRunner.register("exclusions: resume rule starts cleared until matched", exclusionResumeRule)
        TestRunner.register("exclusions: only the first active rule applies", exclusionFirstActive)
        TestRunner.register("focus: defaults-output parsing", focusParsing)
    }

    static func idleNatural() throws {
        let machine = IdleStateMachine(inactivityResetMillis: 300000)
        try expectEqual(machine.update(idleMillis: 25000), .none)
        try expectTrue(machine.isOnNaturalBreak)
        try expectEqual(machine.update(idleMillis: 310000), .clearBreakScheduler)
        try expectTrue(machine.isSchedulerCleared)
    }

    static func idleShortReturn() throws {
        let machine = IdleStateMachine(inactivityResetMillis: 300000)
        _ = machine.update(idleMillis: 25000)
        // returning with <20s idle, last idle below reset time -> nothing
        try expectEqual(machine.update(idleMillis: 5000), .none)
        try expectFalse(machine.isSchedulerCleared)
    }

    static func idleThreshold() throws {
        let machine = IdleStateMachine(inactivityResetMillis: 300000)
        _ = machine.update(idleMillis: 310000)
        try expectEqual(machine.update(idleMillis: 10000), .naturalBreakFinished)
        try expectFalse(machine.isSchedulerCleared)
    }

    static func dndEdges() throws {
        let machine = DndStateMachine()
        try expectEqual(machine.update(enabled: true), .dndStarted)
        try expectEqual(machine.update(enabled: true), .none)
        try expectEqual(machine.update(enabled: false), .dndFinished)
        try expectEqual(machine.update(enabled: false), .none)
    }

    static func exclusionMatch() throws {
        let rule = ExclusionsStateMachine.Rule(active: true, rule: "pause", commands: ["zoom.us", "Teams"])
        let machine = ExclusionsStateMachine(rule: rule)
        let processes = [
            ProcessSnapshotEntry(name: "Code", command: "/Applications/Visual Studio Code.app/.../Electron"),
            ProcessSnapshotEntry(name: "zoom.us", command: "/Applications/zoom.us.app/Contents/MacOS/zoom.us --extra")
        ]
        try expectEqual(machine.matchedCommand(in: processes), "zoom.us")
        // name match, not only command
        let byName = [ProcessSnapshotEntry(name: "Microsoft Teams", command: nil)]
        try expectEqual(machine.matchedCommand(in: byName), "Teams")
        try expectNil(machine.matchedCommand(in: [ProcessSnapshotEntry(name: "Finder", command: nil)]))
        // inactive rule never matches
        let inactive = ExclusionsStateMachine(rule: ExclusionsStateMachine.Rule(active: false, rule: "pause", commands: ["zoom.us"]))
        try expectNil(inactive.matchedCommand(in: processes))
    }

    static func exclusionPauseRule() throws {
        let machine = ExclusionsStateMachine(rule: ExclusionsStateMachine.Rule(active: true, rule: "pause", commands: ["zoom"]))
        try expectFalse(machine.isSchedulerCleared)
        try expectEqual(machine.update(matched: "zoom"), .started(rule: "pause", matched: "zoom"))
        try expectTrue(machine.isSchedulerCleared)
        try expectEqual(machine.update(matched: nil), .finished(rule: "pause"))
        try expectFalse(machine.isSchedulerCleared)
    }

    static func exclusionResumeRule() throws {
        let machine = ExclusionsStateMachine(rule: ExclusionsStateMachine.Rule(active: true, rule: "resume", commands: ["keynote"]))
        // Legacy semantics: a resume rule starts as "the app is running" -> breaks NOT paused.
        try expectFalse(machine.isSchedulerCleared)
        // Matching again produces no event (already on).
        try expectEqual(machine.update(matched: "keynote"), .none)
        try expectFalse(machine.isSchedulerCleared)
        // When the app stops, breaks pause.
        try expectEqual(machine.update(matched: nil), .finished(rule: "resume"))
        try expectTrue(machine.isSchedulerCleared)
        // And when it appears again, breaks resume.
        try expectEqual(machine.update(matched: "keynote"), .started(rule: "resume", matched: "keynote"))
        try expectFalse(machine.isSchedulerCleared)
    }

    static func exclusionFirstActive() throws {
        let array: [SettingsValue] = [
            .object(["active": .bool(false), "rule": .string("resume"), "commands": .array([.string("x")])]),
            .object(["active": .bool(true), "rule": .string("pause"), "commands": .array([.string("y")])]),
            .object(["active": .bool(true), "rule": .string("resume"), "commands": .array([.string("z")])])
        ]
        let rule = ExclusionsStateMachine.Rule.firstActive(in: array)
        try expectEqual(rule?.rule, "pause")
        try expectEqual(rule?.commands, ["y"])
    }

    static func focusParsing() throws {
        try expectTrue(FocusHeuristic.parse(output: "1\n"))
        try expectFalse(FocusHeuristic.parse(output: "0\n"))
        try expectFalse(FocusHeuristic.parse(output: "The domain/default pair does not exist\n"))
        // Adapter returns nil (unknown) when the defaults read fails; callers keep state.
        var heuristic = FocusHeuristic { _, _ in nil }
        try expectNil(heuristic.isDoNotDisturbEnabled())
        heuristic = FocusHeuristic { domain, key in
            // Non-throwing: assertions done via string checks below.
            return (domain == "com.apple.controlcenter" && key.contains("FocusModes")) ? " 1 \n" : "bogus"
        }
        try expectEqual(heuristic.isDoNotDisturbEnabled(), true)
    }
}
