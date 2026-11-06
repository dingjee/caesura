import Foundation
import CaesuraCore

enum MenuSkipPlanTests {
    static func registerAll() {
        TestRunner.register("menu skip: mini planned shows minutes, long none", miniPlanned)
        TestRunner.register("menu skip: long planned shows minutes, mini none", longPlanned)
        TestRunner.register("menu skip: disabled types have no item", disabledTypes)
        TestRunner.register("menu skip: during a break no minutes at all", duringBreak)
        TestRunner.register("menu skip: a wait below a minute has no number", belowAMinute)
    }

    private static func makePlanner(_ clock: ManualClock, values: [String: SettingsValue]) -> BreaksPlanner {
        let settings = SettingsStore(url: URL(fileURLWithPath: "/dev/null/unused.json"), loadNow: false)
        settings.applyForTesting(DefaultSettings.values.merging(values) { _, new in new })
        return BreaksPlanner(clock: clock, settings: settings)
    }

    /// Both types enabled: the next break is a mini break (default break
    /// interval 2 → the third break is the long one), and the countdown of the
    /// plan is the full interval — the notification lead is included.
    private static func miniPlanned() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: [:])
        planner.nextBreak()
        let items = MenuSkipPlan.items(planner: planner, settings: planner.settings)
        try expectEqual(items.count, 2)
        try expectEqual(items[0], MenuSkipPlan.Item(isMini: true, minutes: 10))
        // The long break is not planned yet: the menu never borrows the mini
        // countdown for it.
        try expectEqual(items[1], MenuSkipPlan.Item(isMini: false, minutes: nil))
    }

    /// The third break is the long one: only it carries the minutes — and they
    /// are the minutes of the long break's own plan, never the mini countdown.
    private static func longPlanned() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: [:])
        planner.skipToBreak(delay: 300_000)
        let items = MenuSkipPlan.items(planner: planner, settings: planner.settings)
        try expectEqual(planner.scheduledBreakType, "break")
        try expectEqual(planner.timeToNextBreak, 300_000)
        try expectEqual(items[0], MenuSkipPlan.Item(isMini: true, minutes: nil))
        try expectEqual(items[1], MenuSkipPlan.Item(isMini: false, minutes: 5))
    }

    /// A disabled type has no item at all.
    private static func disabledTypes() throws {
        let clock = ManualClock()
        let miniOnly = makePlanner(clock, values: ["break": .bool(false)])
        miniOnly.nextBreak()
        let miniItems = MenuSkipPlan.items(planner: miniOnly, settings: miniOnly.settings)
        try expectEqual(miniItems.count, 1)
        try expectTrue(miniItems[0].isMini)

        let longOnly = makePlanner(clock, values: ["microbreak": .bool(false)])
        longOnly.nextBreak()
        let longItems = MenuSkipPlan.items(planner: longOnly, settings: longOnly.settings)
        try expectEqual(longItems.count, 1)
        try expectFalse(longItems[0].isMini)
        try expectNotNil(longItems[0].minutes)
    }

    /// While a break runs (the finish reference) the countdown is gone: no
    /// minutes for either type, the items still start their break at once.
    private static func duringBreak() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: [:])
        planner.nextBreak()
        clock.advance(590_000)
        planner.fireIfDue()
        planner.nextBreakAfterNotification()
        clock.advance(10_000)
        planner.fireIfDue()
        planner.breakStarted(shouldPlaySound: false)
        let items = MenuSkipPlan.items(planner: planner, settings: planner.settings)
        try expectEqual(items.count, 2)
        try expectNil(items[0].minutes)
        try expectNil(items[1].minutes)
    }

    /// A wait below a whole minute has no minute to name: the menu degrades to
    /// the plain "start now" title instead of inventing minutes.
    private static func belowAMinute() throws {
        let clock = ManualClock()
        let planner = makePlanner(clock, values: [:])
        planner.nextBreak()
        clock.advance(590_000)
        planner.fireIfDue()
        planner.nextBreakAfterNotification()
        clock.advance(9_500) // 500 ms of the notification lead are left
        let items = MenuSkipPlan.items(planner: planner, settings: planner.settings)
        try expectEqual(items[0].minutes, nil)
    }
}

enum PoemSpacingTests {
    static func registerAll() {
        TestRunner.register("poem spacing: default is 1.2 of the base", defaultFactor)
        TestRunner.register("poem spacing: missing or illegal value falls back to the default", illegalValue)
        TestRunner.register("poem spacing: out of range values are clamped", clamped)
        TestRunner.register("poem spacing: the store applies the policy on load", storePolicy)
        TestRunner.register("poem spacing: spacing scales the base", spacingMath)
    }

    private static func store(values: [String: SettingsValue]) -> SettingsStore {
        let settings = SettingsStore(url: URL(fileURLWithPath: "/dev/null/unused.json"), loadNow: false)
        settings.applyForTesting(DefaultSettings.values.merging(values) { _, new in new })
        return settings
    }

    private static func defaultFactor() throws {
        try expectEqual(PoemSpacing.factor(settings: store(values: [:])), 1.2)
        try expectEqual(PoemSpacing.minimumFactor, 1.0)
        try expectEqual(PoemSpacing.maximumFactor, 2.0)
        try expectEqual(PoemSpacing.step, 0.1)
    }

    private static func illegalValue() throws {
        // Non-finite values are illegal: they fall back to the default.
        try expectEqual(PoemSpacing.factor(raw: .nan), PoemSpacing.defaultFactor)
        try expectEqual(PoemSpacing.factor(raw: .infinity), PoemSpacing.defaultFactor)
        try expectEqual(PoemSpacing.factor(settings: store(values: [
            PoemSpacing.settingKey: .string("1.4")
        ])), PoemSpacing.defaultFactor)
    }

    private static func clamped() throws {
        try expectEqual(PoemSpacing.factor(raw: 3.0), 2.0)
        try expectEqual(PoemSpacing.factor(raw: 0.5), 1.0)
        try expectEqual(PoemSpacing.factor(settings: store(values: [
            PoemSpacing.settingKey: .double(1.4)
        ])), 1.4)
    }

    /// A written value outside the range is clamped by the policy, and a
    /// legacy import of an unsafe value falls back to the default.
    private static func storePolicy() throws {
        let settings = store(values: [:])
        settings.set(PoemSpacing.settingKey, .double(5.0))
        try expectEqual(settings.getBoundedDouble(PoemSpacing.settingKey), 2.0)
        settings.set(PoemSpacing.settingKey, .double(1.75))
        try expectEqual(settings.getBoundedDouble(PoemSpacing.settingKey), 1.75)
        try expectEqual(settings.get(PoemSpacing.settingKey)?.doubleValue ?? 0, 1.75)
    }

    private static func spacingMath() throws {
        try expectEqual(PoemSpacing.spacing(base: 100, multiplier: 1.2), 120)
        try expectEqual(PoemSpacing.spacing(base: 100, multiplier: 1.0), 100)
        try expectEqual(PoemSpacing.spacing(base: 100, multiplier: 2.0), 200)
    }
}
