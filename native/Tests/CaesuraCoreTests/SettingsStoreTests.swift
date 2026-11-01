import Foundation
import CaesuraCore

enum SettingsStoreTests {
    static func registerAll() {
        TestRunner.register("settings: fresh store has all defaults", freshStore)
        TestRunner.register("settings: unknown keys preserved", unknownKeys)
        TestRunner.register("settings: values outside UI ranges preserved (short smoke durations)", outOfRangePreserved)
        TestRunner.register("settings: invalid/unsafe values fall back to defaults", unsafeReplaced)
        TestRunner.register("settings: valid zero and negative values are preserved", zeroValuesPreserved)
        TestRunner.register("settings: malformed file backed up and replaced", malformed)
        TestRunner.register("settings: atomic roundtrip and onChange", roundtrip)
        TestRunner.register("settings: legacy import with backup and migrations", legacyImport)
        TestRunner.register("settings: never touches the legacy file", legacyUntouched)
    }

    static func temporaryDirectory() -> URL {
        // Short names: UNIX socket paths must fit sockaddr_un (104 bytes).
        let suffix = UUID().uuidString.prefix(8)
        let base = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: base).appendingPathComponent("st-\(suffix)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func freshStore() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(url: dir.appendingPathComponent("config.json"))
        try expectEqual(store.getBool("microbreak"), true)
        try expectEqual(store.getMillis("microbreakInterval"), 600000)
        try expectEqual(store.getDouble("opacity"), 0.9)
        try expectTrue(FileManager.default.fileExists(atPath: store.url.path))
    }

    static func unknownKeys() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try "{\"microbreak\":false,\"someFutureKey\":{\"nested\":[1,2]}}".write(to: url, atomically: true, encoding: .utf8)
        let store = SettingsStore(url: url)
        try expectEqual(store.getBool("microbreak"), false)
        try expectNotNil(store.get("someFutureKey"))
        // Survives a rewrite
        store.set("break", .bool(false))
        let reread = SettingsStore(url: url)
        try expectEqual(reread.getBool("microbreak"), false)
        try expectNotNil(reread.get("someFutureKey"))
    }

    static func outOfRangePreserved() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        // UI slider ranges: mini duration 10–600s, interval 5–65min, break interval 1–30.
        // Legacy electron-store never clamped, so valid values outside those ranges stay.
        try "{\"microbreakDuration\":3000,\"microbreakInterval\":4000,\"breakDuration\":2000,\"breakInterval\":40,\"opacity\":0.42}".write(to: url, atomically: true, encoding: .utf8)
        let store = SettingsStore(url: url)
        try expectEqual(store.getMillis("microbreakDuration"), 3000)
        try expectEqual(store.getMillis("microbreakInterval"), 4000)
        try expectEqual(store.getMillis("breakDuration"), 2000)
        try expectEqual(store.getMillis("breakInterval"), 40)
        try expectEqual(store.getDouble("opacity"), 0.42)
    }

    static func unsafeReplaced() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try "{\"microbreakDuration\":\"fast\",\"breakInterval\":1.5,\"microbreak\":\"yes\",\"volume\":-2,\"microbreakInterval\":-1000,\"madeUp\":123}".write(to: url, atomically: true, encoding: .utf8)
        let store = SettingsStore(url: url)
        try expectEqual(store.getMillis("microbreakDuration"), 20000)
        try expectEqual(store.getMillis("breakInterval"), 2) // a fractional count falls back
        try expectEqual(store.getBool("microbreak"), true)
        try expectEqual(store.getMillis("volume"), 1) // default volume int 1
        try expectEqual(store.getMillis("microbreakInterval"), 600000)
        try expectEqual(store.get("madeUp")?.doubleValue, 123) // unknown key kept
        try expectTrue(store.diagnostics.contains { $0.kind == .unsafeValuesReplaced })
    }

    static func zeroValuesPreserved() throws {
        // Zero is a valid legacy value: breakInterval 0 means a long break after every
        // Mini break and a postpone limit of 0 forbids postponing.
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try "{\"breakInterval\":0,\"microbreakPostponesLimit\":0,\"breakPostponesLimit\":0,\"posLatitude\":-33.8688,\"posLongitude\":-151.2093,\"morningHour\":7}".write(to: url, atomically: true, encoding: .utf8)
        let store = SettingsStore(url: url)
        try expectEqual(store.getMillis("breakInterval"), 0)
        try expectEqual(store.getMillis("microbreakPostponesLimit"), 0)
        try expectEqual(store.getMillis("breakPostponesLimit"), 0)
        try expectEqual(store.getDouble("posLatitude"), -33.8688)
        try expectEqual(store.getDouble("posLongitude"), -151.2093)
        try expectEqual(store.get("morningHour")?.doubleValue, 7)
    }

    static func malformed() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try "{not json".write(to: url, atomically: true, encoding: .utf8)
        let store = SettingsStore(url: url)
        try expectEqual(store.getMillis("microbreakInterval"), 600000)
        try expectTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("malformed-config-backup.json").path))
        try expectTrue(store.diagnostics.contains { $0.kind == .malformedReplaced })
    }

    static func roundtrip() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(url: dir.appendingPathComponent("config.json"))
        var observed: [String] = []
        store.onChange = { key, _ in observed.append(key) }
        store.set("breakInterval", .int(4))
        let reread = SettingsStore(url: store.url)
        try expectEqual(reread.getMillis("breakInterval"), 4)
        try expectEqual(observed, ["breakInterval"])
    }

    static func legacyImport() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appendingPathComponent("legacy-config.json")
        try """
        {"microbreakInterval":900000,"audio":"tic-toc","timeToBreakInTray":true,
         "useMonochromeInvertedTrayIcon":true,"pauseBreaksShortcut":"Ctrl+P",
         "appExclusionsCheckInterval":1000,"someUnknown":true}
        """.write(to: legacyURL, atomically: true, encoding: .utf8)
        let store = SettingsStore(url: dir.appendingPathComponent("config.json"), loadNow: false)
        let imported = store.importLegacyConfigIfPresent(legacyURL: legacyURL)
        try expectTrue(imported)
        try expectEqual(store.getMillis("microbreakInterval"), 900000)
        try expectEqual(store.getString("longBreakAudio"), "tic-toc") // migrated from audio
        try expectEqual(store.getString("trayIconStyle"), "time") // migrated
        try expectEqual(store.getString("trayIconThemeSource"), "dark") // migrated
        try expectEqual(store.getString("pauseBreaksToggleShortcut"), "Ctrl+P") // migrated
        try expectEqual(store.getMillis("appExclusionsCheckInterval"), 2000) // migrated 1000 -> 2000
        try expectTrue(store.getBool("someUnknown")) // preserved
        try expectTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("legacy-config-backup.json").path))
        // Second load does not re-import
        let reread = SettingsStore(url: store.url)
        try expectEqual(reread.getMillis("microbreakInterval"), 900000)
    }

    static func legacyUntouched() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appendingPathComponent("legacy-config.json")
        try "{\"microbreakInterval\":900000}".write(to: legacyURL, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: legacyURL)
        let store = SettingsStore(url: dir.appendingPathComponent("config.json"), loadNow: false)
        _ = store.importLegacyConfigIfPresent(legacyURL: legacyURL)
        store.set("microbreakInterval", .int(111))
        let after = try Data(contentsOf: legacyURL)
        try expectEqual(before, after)
    }
}
