import Foundation
import CaesuraCore

enum UntilMorningTests {
    static func registerAll() {
        TestRunner.register("untilMorning: fixed hour before/after current hour", fixedHour)
        TestRunner.register("untilMorning: sunrise returns sane duration at mid latitudes", sunriseSane)
        TestRunner.register("untilMorning: polar fallback keeps finite duration", polarFallback)
    }

    static func fixedHour() throws {
        let clock = ManualClock(start: iso("2026-10-26T10:00:00Z"))
        let settings = inMemory(["morningHour": .int(6)])
        let millis = UntilMorning.msToSunrise(settings: settings, clock: clock, calendar: utcCalendar())
        // 10:00 UTC -> tomorrow 06:00 UTC = 20h
        try expectTrue(abs(millis - 20 * 3600000) < 60000, "expected ~20h, got \(millis / 60000)min")

        let earlyClock = ManualClock(start: iso("2026-10-26T03:00:00Z"))
        let early = UntilMorning.msToSunrise(settings: settings, clock: earlyClock, calendar: utcCalendar())
        try expectTrue(abs(early - 3 * 3600000) < 60000, "expected ~3h, got \(early / 60000)min")
    }

    static func sunriseSane() throws {
        let clock = ManualClock(start: iso("2026-10-26T22:00:00Z"))
        var settings = DefaultSettings.values
        settings["morningHour"] = .string("sunrise")
        settings["posLatitude"] = .double(52.52) // Berlin
        settings["posLongitude"] = .double(13.405)
        let store = SettingsStore(url: URL(fileURLWithPath: "/dev/null/unused.json"), loadNow: false)
        store.applyForTesting(settings)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let millis = UntilMorning.msToSunrise(settings: store, clock: clock, calendar: calendar)
        // Between now and next sunrise: 3–11 hours expected late October in Berlin.
        try expectTrue(millis > 3 * 3600000 && millis < 11 * 3600000, "expected 3–11h to sunrise, got \(millis / 60000)min")
    }

    static func polarFallback() throws {
        // Longyearbyen in mid-January: deep polar night on both candidate days -> fallback 6:00.
        let clock = ManualClock(start: iso("2027-01-15T10:00:00Z"))
        var settings = DefaultSettings.values
        settings["morningHour"] = .string("sunrise")
        settings["posLatitude"] = .double(78.22)
        settings["posLongitude"] = .double(15.63)
        let store = SettingsStore(url: URL(fileURLWithPath: "/dev/null/unused.json"), loadNow: false)
        store.applyForTesting(settings)
        let millis = UntilMorning.msToSunrise(settings: store, clock: clock, calendar: utcCalendar())
        try expectTrue(abs(millis - 20 * 3600000) < 120000, "expected fallback ~20h, got \(millis / 60000)min")
    }

    static func inMemory(_ overrides: [String: SettingsValue]) -> SettingsStore {
        let store = SettingsStore(url: URL(fileURLWithPath: "/dev/null/unused.json"), loadNow: false)
        store.applyForTesting(DefaultSettings.values.merging(overrides) { _, new in new })
        return store
    }

    static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func iso(_ string: String) -> Int64 {
        let formatter = ISO8601DateFormatter()
        return Int64(formatter.date(from: string)!.timeIntervalSince1970 * 1000)
    }
}
