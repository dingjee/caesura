import Foundation
import CaesuraCore

enum BreaksPlannerTests {
    static func registerAll() {
        TestRunner.register("planner: default mini 20s/10min, long 5min after 2 minis", defaultSchedule)
        TestRunner.register("planner: mini-only schedule", miniOnly)
        TestRunner.register("planner: long-only uses interval×(breakInterval+1)", longOnly)
        TestRunner.register("planner: both disabled plans nothing and is a no-op", bothDisabled)
        TestRunner.register("planner: notification lead times (mini 10s, long 30s)", notificationLeads)
        TestRunner.register("planner: nextBreakAfterNotification waits notificationInterval", afterNotification)
        TestRunner.register("planner: alternation across skips", alternationWithSkips)
        TestRunner.register("planner: postpone respects postponesLimit and notification lead", postpone)
        TestRunner.register("planner: breakStarted plans finish at duration; fires finish event", finishDeadline)
        TestRunner.register("planner: pause cancels timers; timed resume fires once", pauseResume)
        TestRunner.register("planner: resume reinitializes pollers exactly once", resumeRestartPollersOnce)
        TestRunner.register("planner: idle clear then finish does not fire", idleClearsScheduler)
        TestRunner.register("planner: idle return beyond reset time resets", idleReset)
        TestRunner.register("planner: dnd started during active break does not end the break", dndDuringBreak)
        TestRunner.register("planner: pause-rule exclusion closes active break and clears scheduler", exclusionPauseClosesBreak)
        TestRunner.register("planner: resume-rule exclusion resumes and clears when it ends", exclusionResume)
        TestRunner.register("planner: correctScheduler re-anchors remaining time", correctScheduler)
        TestRunner.register("planner: manual finish keeps window phase until finished", manualFinish)
        TestRunner.register("planner: strict mode blocks skip but postpone allowed in window", strictGate)
        TestRunner.register("planner: timeToNextBreak includes notification lead", timeToNextBreakMath)
    }

    private static func makePlanner(_ clock: ManualClock, values: [String: SettingsValue]) -> BreaksPlanner {
        let settings = SettingsStore(url: URL(fileURLWithPath: "/dev/null/unused.json"), loadNow: false)
        settings.applyForTesting(DefaultSettings.values.merging(values) { _, new in new })
        return BreaksPlanner(clock: clock, settings: settings)
    }

    private static func defaultSchedule() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: [:])
        planner.nextBreak()
        try expectEqual(planner.scheduledBreakType, "microbreak")
        try expectEqual(planner.scheduler.reference, "startMicrobreakNotification")
        try expectEqual(planner.scheduler.delay, 600000 - 10000)
        try expectEqual(planner.breakNumber, 1)
    }

    private static func miniOnly() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: ["break": .bool(false)])
        planner.nextBreak()
        try expectEqual(planner.scheduler.reference, "startMicrobreakNotification")
        try expectEqual(planner.scheduler.delay, 590000)
        clock.advance(590000)
        planner.fireIfDue()
        planner.nextBreakAfterNotification()
        try expectEqual(planner.scheduler.reference, "startMicrobreak")
        clock.advance(10000)
        planner.fireIfDue()
        // breakNumber never enters the modulo cycle with long breaks disabled
        try expectEqual(planner.scheduledBreakType, "microbreak")
    }

    private static func longOnly() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: ["microbreak": .bool(false)])
        planner.nextBreak()
        // 10min * (2+1) - 30s notification lead
        try expectEqual(planner.scheduler.reference, "startBreakNotification")
        try expectEqual(planner.scheduler.delay, 600000 * 3 - 30000)
    }

    private static func bothDisabled() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: ["microbreak": .bool(false), "break": .bool(false)])
        planner.nextBreak()
        // Legacy: no scheduling branch matches; scheduler stays cancelled (reference nil).
        try expectNil(planner.scheduler.reference)
        // Firing does nothing and does not crash.
        clock.advance(600000)
        planner.fireIfDue()
        try expectNil(planner.scheduler.reference)
        // Legacy _scheduledBreakType: `!shouldBreak` branch wins -> microbreak.
        try expectEqual(planner.scheduledBreakType, "microbreak")
    }

    private static func notificationLeads() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: [:])
        planner.nextBreak() // bn 1: mini notification, 10min - 10s
        try expectEqual(planner.scheduler.delay, 600000 - 10000)
        try expectEqual(planner.scheduler.reference, "startMicrobreakNotification")
        planner.nextBreak() // bn 2: mini again
        try expectEqual(planner.scheduler.reference, "startMicrobreakNotification")
        planner.nextBreak() // bn 3: long, 10min - 30s
        try expectEqual(planner.scheduler.reference, "startBreakNotification")
        try expectEqual(planner.scheduler.delay, 600000 - 30000)
    }

    private static func afterNotification() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: [:])
        planner.nextBreak()
        clock.advance(600000 - 10000)
        planner.fireIfDue()
        planner.nextBreakAfterNotification()
        try expectEqual(planner.scheduler.reference, "startMicrobreak")
        try expectEqual(planner.scheduler.delay, 10000)
    }

    private static func alternationWithSkips() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: [:])
        planner.nextBreak()
        try expectEqual(planner.breakNumber, 1)
        try expectEqual(planner.scheduledBreakType, "microbreak")
        planner.nextBreak()
        try expectEqual(planner.breakNumber, 2)
        planner.nextBreak()
        try expectEqual(planner.breakNumber, 3)
        try expectEqual(planner.scheduledBreakType, "break")
        // skipToBreak pins the cycle at the long boundary
        planner.skipToBreak()
        try expectEqual(planner.breakNumber, 3)
        planner.nextBreak() // 4 -> mini
        try expectEqual(planner.scheduledBreakType, "microbreak")
        // skipToMicrobreak resets the cycle only when currently at the long boundary
        planner.skipToMicrobreak() // bn 4 is not a boundary -> unchanged
        try expectEqual(planner.breakNumber, 4)
        planner.nextBreak() // 5 -> mini
        planner.nextBreak() // 6 -> long
        try expectEqual(planner.scheduledBreakType, "break")
        planner.skipToMicrobreak() // 6 % 3 == 0 -> restart at 1
        try expectEqual(planner.breakNumber, 1)
        planner.nextBreak() // 2 -> mini
        try expectEqual(planner.scheduledBreakType, "microbreak")
    }

    private static func postpone() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: ["microbreakNotification": .bool(false)])
        planner.nextBreak()
        clock.advance(600000)
        planner.fireIfDue() // startMicrobreak emitted
        planner.breakStarted(shouldPlaySound: true)
        planner.postponeCurrentBreak()
        try expectEqual(planner.postponesNumber, 1)
        // postponeTime 120s, notification disabled -> schedule startMicrobreak in 120s
        try expectEqual(planner.scheduler.reference, "startMicrobreak")
        try expectEqual(planner.scheduler.delay, 120000)
        // Second postpone still allowed to schedule (limit enforced at start), count = 2
        planner.postponeCurrentBreak()
        try expectEqual(planner.postponesNumber, 2)
    }

    private static func finishDeadline() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: ["microbreakNotification": .bool(false)])
        var events: [PlannerEvent] = []
        planner.onEvent = { events.append($0) }
        planner.nextBreak()
        clock.advance(600000)
        planner.fireIfDue()
        planner.breakStarted(shouldPlaySound: true)
        try expectEqual(planner.scheduler.reference, "finishMicrobreak")
        try expectEqual(planner.scheduler.delay, 20000)
        clock.advance(19999)
        planner.fireIfDue()
        try expectFalse(events.contains(.finishMicrobreak(shouldPlaySound: true, shouldPlanNext: true)))
        clock.advance(1)
        planner.fireIfDue()
        try expectTrue(events.contains(.finishMicrobreak(shouldPlaySound: true, shouldPlanNext: true)))
        try expectEqual(planner.scheduler.reference, "finishMicrobreak") // unchanged until app plans next
    }

    private static func pauseResume() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: [:])
        var events: [PlannerEvent] = []
        planner.onEvent = { events.append($0) }
        planner.nextBreak()
        planner.pause(60000)
        try expectTrue(planner.isPaused)
        try expectEqual(planner.scheduler.reference, "resumeBreaks")
        try expectEqual(planner.breakNumber, 0)
        // pause(1) = indefinite: no resume timer
        planner.resume()
        planner.pause(1)
        try expectNil(planner.scheduler.reference)
        // timed pause fires resumeBreaks exactly once; the app then calls resume()
        planner.resume()
        planner.pause(1000)
        clock.advance(999)
        planner.fireIfDue()
        try expectFalse(events.contains(.resumeBreaks))
        clock.advance(1)
        planner.fireIfDue()
        try expectTrue(events.contains(.resumeBreaks))
        planner.resume() // mirrors legacy main.js resumeBreaks() handler
        try expectFalse(planner.isPaused)
        clock.advance(1000)
        planner.fireIfDue()
        let resumeCount = events.filter { $0 == .resumeBreaks }.count
        try expectEqual(resumeCount, 1)
    }

    private static func resumeRestartPollersOnce() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: [:])
        var events: [PlannerEvent] = []
        planner.onEvent = { events.append($0) }
        planner.pause(1)
        planner.resume()
        planner.resume() // second resume without pause must not re-emit restartPollers
        let restarts = events.filter { $0 == .restartPollers }.count
        try expectEqual(restarts, 1)
    }

    private static func idleClearsScheduler() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: [:])
        planner.nextBreak()
        try expectNotNil(planner.scheduler.reference)
        planner.applyIdle(idleMillis: 25000) // > 20s but < reset 300s: user idle
        try expectNotNil(planner.scheduler.reference)
        planner.applyIdle(idleMillis: 310000) // > reset: clear scheduler
        try expectNil(planner.scheduler.reference)
        // finish never fires for a cleared scheduler
        var events: [PlannerEvent] = []
        planner.onEvent = { events.append($0) }
        clock.advance(1000000)
        planner.fireIfDue()
        try expectTrue(events.isEmpty)
    }

    private static func idleReset() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: [:])
        planner.nextBreak()
        planner.applyIdle(idleMillis: 310000)
        try expectNil(planner.scheduler.reference)
        // user returns after long idle -> naturalBreakFinished resets the planner
        planner.applyIdle(idleMillis: 10000)
        try expectNotNil(planner.scheduler.reference)
        try expectEqual(planner.scheduler.reference, "startMicrobreakNotification")
    }

    private static func dndDuringBreak() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: [:])
        planner.nextBreak()
        clock.advance(600000)
        planner.fireIfDue()
        planner.breakStarted(shouldPlaySound: true)
        try expectEqual(planner.scheduler.reference, "finishMicrobreak")
        planner.applyDnd(enabled: true)
        // Active break must not be cut short by DND; DND flag reset like legacy
        try expectEqual(planner.scheduler.reference, "finishMicrobreak")
        try expectFalse(planner.dndMachine.isOnDnd)
    }

    private static func exclusionPauseClosesBreak() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: ["appExclusions": .array([
            .object(["active": .bool(true), "rule": .string("pause"), "commands": .array([.string("zoom.us")])])
        ])])
        var events: [PlannerEvent] = []
        planner.onEvent = { events.append($0) }
        planner.nextBreak()
        clock.advance(600000)
        planner.fireIfDue()
        planner.breakStarted(shouldPlaySound: true)
        try expectNil(planner.exclusionsMachine.matchedCommand(in: [snapshot("Finder")]))
        planner.applyExclusion(matched: planner.exclusionsMachine.matchedCommand(
            in: [snapshot("Finder"), snapshot("zoom.us", command: "/Applications/zoom.us.app/zoom")]) ?? nil)
        try expectTrue(events.contains(.finishMicrobreak(shouldPlaySound: false, shouldPlanNext: false)))
        try expectNil(planner.scheduler.reference)
        try expectTrue(planner.exclusionsMachine.isSchedulerCleared)
    }

    private static func exclusionResume() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: ["appExclusions": .array([
            .object(["active": .bool(true), "rule": .string("resume"), "commands": .array([.string("presentation")])])
        ])])
        planner.nextBreak()
        try expectNotNil(planner.scheduler.reference)
        // resume rule configured: matched -> reschedules; gone -> pauses
        planner.applyExclusion(matched: "presentation")
        try expectNotNil(planner.scheduler.reference)
        planner.applyExclusion(matched: nil)
        try expectNil(planner.scheduler.reference) // cleared after exclusion ends
        try expectTrue(planner.exclusionsMachine.isSchedulerCleared)
    }

    private static func snapshot(_ name: String, command: String? = nil) -> ProcessSnapshotEntry {
        ProcessSnapshotEntry(name: name, command: command)
    }

    private static func correctScheduler() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: [:])
        planner.nextBreak()
        let originalDeadline = planner.scheduler.plannedAtMillis + planner.scheduler.delay
        clock.advance(100000)
        planner.correctScheduler() // e.g. after resume without pause
        try expectEqual(planner.scheduler.timeLeft ?? 0, originalDeadline - clock.nowMillis)
        try expectEqual(planner.scheduler.delay, originalDeadline - clock.nowMillis)
    }

    private static func manualFinish() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: [:])
        var events: [PlannerEvent] = []
        planner.onEvent = { events.append($0) }
        planner.nextBreak()
        clock.advance(600000)
        planner.fireIfDue()
        planner.breakStarted(shouldPlaySound: true)
        clock.advance(20000)
        planner.fireIfDue()
        // App reacts to finishMicrobreak by entering manual await (window stays);
        // scheduler reference remains finishMicrobreak so skip/finish CLI can find it.
        try expectEqual(planner.scheduler.reference, "finishMicrobreak")
        // Manual finish click: app closes and plans next
        planner.nextBreak()
        try expectEqual(planner.scheduler.reference, "startMicrobreakNotification")
    }

    private static func strictGate() throws {
        // Strict mode is enforced in policy helpers; planner keeps running the break.
        try expectTrue(Utils.canSkip(strictMode: false, postpone: false, passedPercent: 0, postponePercent: 30))
        try expectFalse(Utils.canSkip(strictMode: true, postpone: false, passedPercent: 0, postponePercent: 30))
        try expectFalse(Utils.canSkip(strictMode: false, postpone: true, passedPercent: 10, postponePercent: 30))
        try expectTrue(Utils.canSkip(strictMode: false, postpone: true, passedPercent: 31, postponePercent: 30))
        try expectTrue(Utils.canPostpone(postpone: true, passedPercent: 30, postponePercent: 30))
        try expectFalse(Utils.canPostpone(postpone: true, passedPercent: 31, postponePercent: 30))
    }

    private static func timeToNextBreakMath() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: [:])
        planner.nextBreak()
        // notification scheduled: timeToNextBreak = timeLeft + micro lead
        try expectEqual(planner.timeToNextBreak ?? 0, 590000 + 10000)
        try expectEqual(planner.progressInterval ?? 0, 600000)
        try expectEqual(planner.progressPercentage, 0)
        clock.advance(295000) // half of the notification delay
        try expectEqual(planner.progressPercentage, 49)
    }
}
