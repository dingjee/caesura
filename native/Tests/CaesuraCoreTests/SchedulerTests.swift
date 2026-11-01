import Foundation
import CaesuraCore

enum SchedulerTests {
    static func registerAll() {
        TestRunner.register("scheduler: plan and timeLeft", planAndTimeLeft)
        TestRunner.register("scheduler: cancel clears reference and time", cancel)
        TestRunner.register("scheduler: correct re-anchors remaining time", correct)
        TestRunner.register("scheduler: due detection", due)
    }

    static func planAndTimeLeft() throws {
        let clock = ManualClock()
        let scheduler = Scheduler(clock: clock)
        try expectNil(scheduler.timeLeft) // legacy: false when unplanned
        scheduler.plan(delay: 1000, reference: "startMicrobreak")
        try expectEqual(scheduler.timeLeft ?? 0, 1000)
        clock.advance(400)
        try expectEqual(scheduler.timeLeft ?? 0, 600)
    }

    static func cancel() throws {
        let clock = ManualClock()
        let scheduler = Scheduler(clock: clock)
        scheduler.plan(delay: 1000, reference: "startBreak")
        scheduler.cancel()
        try expectNil(scheduler.reference)
        try expectNil(scheduler.timeLeft)
        try expectFalse(scheduler.isDue)
    }

    static func correct() throws {
        let clock = ManualClock()
        let scheduler = Scheduler(clock: clock)
        scheduler.plan(delay: 10000, reference: "startMicrobreak")
        clock.advance(3000)
        scheduler.correct()
        try expectEqual(scheduler.timeLeft ?? 0, 7000)
        try expectEqual(scheduler.plannedAtMillis, 3000)
        // correct with nothing planned is a no-op
        scheduler.cancel()
        scheduler.correct()
        try expectNil(scheduler.timeLeft)
    }

    static func due() throws {
        let clock = ManualClock()
        let scheduler = Scheduler(clock: clock)
        scheduler.plan(delay: 500, reference: "startBreak")
        try expectFalse(scheduler.isDue)
        clock.advance(500)
        try expectTrue(scheduler.isDue)
    }
}
