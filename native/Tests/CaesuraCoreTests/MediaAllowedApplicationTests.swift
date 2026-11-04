import Foundation
import CaesuraCore

enum MediaAllowedApplicationTests {
    static func registerAll() {
        TestRunner.register("media allowlist: defaults preserve Spotify and AlgerMusic", defaults)
        TestRunner.register("media allowlist: adding and removing survives reload", roundTrip)
        TestRunner.register("media allowlist: malformed identities and duplicates are rejected", validation)
        TestRunner.register("media allowlist: an explicit empty list stays empty", empty)
    }

    static func defaults() throws {
        let apps = MediaAllowedApplication.parse(nil)
        try expectEqual(apps.map(\.bundleIdentifier), ["com.spotify.client", "com.alger.music.trial"])
        try expectEqual(MediaAllowedApplication.parse(.string("bad")), apps)
        try expectEqual(MediaAllowedApplication.parse(.array([.null, .string("bad")])), apps)
    }

    static func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let settings = SettingsStore(url: url)
        let extra = MediaAllowedApplication(bundleIdentifier: "com.example.player", name: "Player")!
        let apps = MediaAllowedApplication.defaults + [extra]
        settings.set(MediaAllowedApplication.settingKey, .array(apps.map(\.settingsValue)))
        let loaded = SettingsStore(url: url)
        try expectEqual(MediaAllowedApplication.parse(loaded.get(MediaAllowedApplication.settingKey)), apps)
        loaded.set(MediaAllowedApplication.settingKey, .array([extra.settingsValue]))
        try expectEqual(MediaAllowedApplication.parse(SettingsStore(url: url).get(MediaAllowedApplication.settingKey)), [extra])
    }

    static func validation() throws {
        let values: [SettingsValue] = [
            .object(["bundleIdentifier": .string("com.spotify.client"), "name": .string("Spotify")]),
            .object(["bundleIdentifier": .string("COM.SPOTIFY.CLIENT"), "name": .string("duplicate")]),
            .object(["bundleIdentifier": .string("../some app")]), .string("invalid"),
            .object(["name": .string("missing identity")])
        ]
        try expectEqual(MediaAllowedApplication.parse(.array(values)).count, 1)
        try expectNil(MediaAllowedApplication(bundleIdentifier: "", name: "App"))
        try expectNil(MediaAllowedApplication(bundleIdentifier: "com..app", name: "App"))
        try expectEqual(MediaAllowedApplication(bundleIdentifier: " com.example.player ", name: " ")?.name,
                        "com.example.player")
    }

    static func empty() throws {
        try expectEqual(MediaAllowedApplication.parse(.array([])), [])
    }
}
