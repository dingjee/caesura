import Foundation
import CaesuraCore

enum StatusMessagesTests {
    static func registerAll() {
        TestRunner.register("status: empty during active break", activeBreak)
        TestRunner.register("status: paused indefinitely / resuming", paused)
        TestRunner.register("status: dnd and app exclusion lines", pauseCauses)
        TestRunner.register("status: next mini/long with long-break suffix", nextBreak)
    }

    static func input(_ planner: BreaksPlanner, _ settings: SettingsStore) -> StatusMessages.Input {
        StatusMessages.Input(planner: planner, settings: settings)
    }

    static func makePlanner(_ clock: ManualClock, values: [String: SettingsValue] = [:]) -> (BreaksPlanner, SettingsStore) {
        let settings = SettingsStore(url: URL(fileURLWithPath: "/dev/null/unused.json"), loadNow: false)
        settings.applyForTesting(DefaultSettings.values.merging(values) { _, new in new })
        return (BreaksPlanner(clock: clock, settings: settings), settings)
    }

    static func activeBreak() throws {
        let (planner, settings) = makePlanner(ManualClock())
        planner.nextBreak()
        let localization = Localization()
        localization.setLanguage("en")
        planner.applyDnd(enabled: true) // idle scheduled -> cleared, DND flagged
        let message = StatusMessages.trayMessage(input(planner, settings), localization: localization)
        try expectTrue(message.contains("Paused"), "got: \(message)")
        try expectTrue(message.contains("Do Not Disturb"), "got: \(message)")
    }

    static func paused() throws {
        let (planner, settings) = makePlanner(ManualClock())
        let localization = Localization()
        localization.setLanguage("en")
        planner.pause(1)
        var message = StatusMessages.trayMessage(input(planner, settings), localization: localization)
        try expectTrue(message.contains("Indefinitely"), "got: \(message)")
        planner.resume()
        planner.pause(90 * 60000)
        message = StatusMessages.trayMessage(input(planner, settings), localization: localization)
        // Legacy humanizeDuration(5400000, units d/h/m, round) -> "2 hours"
        try expectTrue(message.contains("Resuming"), "got: \(message)")
        try expectTrue(message.contains("2 hours"), "got: \(message)")
    }

    static func pauseCauses() throws {
        let settings = SettingsStore(url: URL(fileURLWithPath: "/dev/null/unused.json"), loadNow: false)
        var values = DefaultSettings.values
        values["appExclusions"] = .array([
            .object(["active": .bool(true), "rule": .string("pause"), "commands": .array([.string("zoom.us")])])
        ])
        settings.applyForTesting(values)
        let planner = BreaksPlanner(clock: ManualClock(), settings: settings)
        let localization = Localization()
        localization.setLanguage("en")
        planner.nextBreak()
        planner.applyDnd(enabled: true)
        var message = StatusMessages.trayMessage(input(planner, settings), localization: localization)
        try expectTrue(message.contains("Do Not Disturb"), "got: \(message)")
        planner.applyDnd(enabled: false)
        // Legacy shows an empty status while idle-cleared; only real exclusions get a line.
        planner.applyExclusion(matched: "zoom.us")
        message = StatusMessages.trayMessage(input(planner, settings), localization: localization)
        try expectTrue(message.contains("App exclusion"), "got: \(message)")
    }

    static func nextBreak() throws {
        let (planner, settings) = makePlanner(ManualClock())
        let localization = Localization()
        localization.setLanguage("en")
        planner.nextBreak()
        var message = StatusMessages.trayMessage(input(planner, settings), longBreaksEnabled: true, localization: localization)
        try expectTrue(message.contains("Next Mini break"), "got: \(message)")
        try expectTrue(message.contains("after 2 Mini breaks"), "got: \(message)")
        planner.skipToBreak()
        message = StatusMessages.trayMessage(input(planner, settings), longBreaksEnabled: true, localization: localization)
        try expectTrue(message.contains("Next Long break"), "got: \(message)")
        try expectFalse(message.contains("after"), "got: \(message)")
    }
}
