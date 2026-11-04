import Foundation
import CaesuraCore

/// Regression tests for the acceptance findings that were fixed in the native port.
enum RegressionTests {
    static func registerAll() {
        TestRunner.register("regression: fresh config is really written to disk", freshConfigIsWritten)
        TestRunner.register("regression: repeated saves keep a valid config file", repeatedSaves)
        TestRunner.register("regression: legacy import creates a valid config file", importCreatesFile)
        TestRunner.register("regression: restart roundtrip keeps every value", restartRoundtrip)
        TestRunner.register("regression: no temporary files are left behind", noTempLeftovers)
        TestRunner.register("regression: unwritable config reports the failure", unwritableConfig)
        TestRunner.register("regression: legacy assets are copied without overwriting", legacyAssets)
        TestRunner.register("regression: legacy contributor stamp is imported", legacyStamp)
        TestRunner.register("regression: health accounting matches the legacy rules", healthAccounting)
        TestRunner.register("regression: pause stops and resume restarts the pollers", pauseStopsPollers)
        TestRunner.register("regression: clock format translates Luxon tokens", clockFormat)
        TestRunner.register("regression: unknown clock tokens stay valid ICU patterns", clockFormatUnknownTokens)
        TestRunner.register("regression: CLI server survives stop/restart and partial frames", cliServerRestart)
        TestRunner.register("regression: valid settings domains are preserved", settingsDomains)
        TestRunner.register("regression: huge numbers do not trap getMillis", hugeNumbers)
        TestRunner.register("regression: a fresh profile contains no exercise tips", defaultIdeaDataSets)
        TestRunner.register("regression: JSON numbers stay numbers", jsonNumbers)
        TestRunner.register("regression: a scheduled event fires only once", eventFiresOnce)
        TestRunner.register("regression: the clock renders the documented format", clockFormatOutput)
        TestRunner.register("regression: the break foreground follows the background", foregroundColors)
    }

    // MARK: Single fire

    static func eventFiresOnce() throws {
        let clock = ManualClock()
        let store = SettingsStore(url: URL(fileURLWithPath: "/dev/null/unused.json"), loadNow: false)
        store.applyForTesting(DefaultSettings.values)
        let planner = BreaksPlanner(clock: clock, settings: store)
        var finishEvents = 0
        planner.onEvent = { event in
            if case .finishMicrobreak = event { finishEvents += 1 }
        }
        planner.breakStarted(shouldPlaySound: true)
        clock.advance(20000)
        planner.fireIfDue()
        planner.fireIfDue()
        planner.fireIfDue()
        try expectEqual(finishEvents, 1, "a scheduled event must not repeat")
        // The reference is kept (legacy keeps the scheduler object), so the strict mode
        // checks still see the running break.
        try expectEqual(planner.scheduler.reference, "finishMicrobreak")
    }

    // MARK: JSON numbers

    static func jsonNumbers() throws {
        let dir = SettingsStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        // The number 1 must not be read as the boolean true.
        try "{\"breakInterval\":1,\"microbreakPostponesLimit\":1,\"microbreak\":true,\"volume\":0}".write(to: url, atomically: true, encoding: .utf8)
        let store = SettingsStore(url: url)
        try expectEqual(store.get("breakInterval"), .int(1), "the number 1 must stay a number")
        try expectEqual(store.get("microbreakPostponesLimit"), .int(1))
        try expectEqual(store.get("microbreak"), .bool(true), "a real boolean must stay a boolean")
        try expectEqual(store.get("volume"), .int(0))
        try expectEqual(store.getMillis("breakInterval"), 1)
        try expectEqual(store.getMillis("volume"), 0)
    }

    // MARK: Settings domains

    static func settingsDomains() throws {
        let dir = SettingsStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        // West/south coordinates, a numeric morning hour, zero postpone limits and a
        // zero break interval are all valid legacy values.
        try """
        {"posLatitude":-33.8688,"posLongitude":-151.2093,"morningHour":7,
         "microbreakPostponesLimit":0,"breakPostponesLimit":0,"breakInterval":0}
        """.write(to: url, atomically: true, encoding: .utf8)
        let store = SettingsStore(url: url)
        try expectEqual(store.getDouble("posLatitude"), -33.8688, "a negative latitude must be preserved")
        try expectEqual(store.getDouble("posLongitude"), -151.2093, "a negative longitude must be preserved")
        try expectEqual(store.get("morningHour")?.doubleValue, 7, "a numeric morning hour must be preserved")
        try expectEqual(store.getMillis("microbreakPostponesLimit"), 0, "a postpone limit of 0 is valid")
        try expectEqual(store.getMillis("breakPostponesLimit"), 0, "a postpone limit of 0 is valid")
        try expectEqual(store.getMillis("breakInterval"), 0, "a break interval of 0 is valid")

        // "sunrise" stays a valid morning hour.
        try "{\"morningHour\":\"sunrise\"}".write(to: url, atomically: true, encoding: .utf8)
        let sunriseStore = SettingsStore(url: url)
        try expectEqual(sunriseStore.getString("morningHour"), "sunrise")

        // A morning hour of the wrong type falls back to the default.
        try "{\"morningHour\":{}}".write(to: url, atomically: true, encoding: .utf8)
        let brokenStore = SettingsStore(url: url)
        try expectEqual(brokenStore.get("morningHour")?.doubleValue, 6, "an invalid morning hour falls back")
    }

    static func hugeNumbers() throws {
        let dir = SettingsStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try "{\"microbreakDuration\":1e300,\"unknownBig\":1e300}".write(to: url, atomically: true, encoding: .utf8)
        let store = SettingsStore(url: url)
        // Must not trap.
        let value = store.getMillis("microbreakDuration")
        try expectTrue(value > 0, "a huge duration must be clamped, not trapped")
    }

    // MARK: Default ideas

    static func defaultIdeaDataSets() throws {
        let store = SettingsStore(url: URL(fileURLWithPath: "/dev/null/unused.json"), loadNow: false)
        store.applyForTesting(DefaultSettings.values)
        try expectTrue(store.getArray("breakIdeas").isEmpty)
        try expectTrue(store.getArray("microbreakIdeas").isEmpty)
        let localization = Localization()
        for language in Localization.availableLanguages {
            localization.setLanguage(language)
            try expectTrue(IdeasLoader.miniIdeas(settings: store, localization: localization).isEmpty)
            try expectTrue(IdeasLoader.longIdeas(settings: store, localization: localization).isEmpty)
        }
    }

    // MARK: Settings persistence

    static func freshConfigIsWritten() throws {
        let dir = SettingsStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        // The default initialisation loads (and therefore creates) the config file.
        let store = SettingsStore(url: url)
        try expectTrue(FileManager.default.fileExists(atPath: url.path),
                       "a fresh store must create the config file")
        let data = try Data(contentsOf: url)
        let parsed = try SettingsValue.from(jsonObject: data)
        try expectNotNil(parsed.objectValue, "the created config file must contain a JSON object")
        try expectTrue(store.diagnostics.contains { $0.kind == .createdFresh })

        // The application path: import first, then load — the file must exist afterwards.
        let other = SettingsStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: other) }
        let otherURL = other.appendingPathComponent("config.json")
        let deferred = SettingsStore(url: otherURL, loadNow: false)
        deferred.load()
        try expectTrue(FileManager.default.fileExists(atPath: otherURL.path),
                       "loading a missing config must create it")
    }

    static func repeatedSaves() throws {
        let dir = SettingsStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let store = SettingsStore(url: url, loadNow: false)
        store.set("breakInterval", .int(3))
        store.set("microbreakInterval", .int(120000))
        store.set("language", .string("de"))
        let parsed = try SettingsValue.from(jsonObject: try Data(contentsOf: url))
        let object = parsed.objectValue
        try expectNotNil(object, "the saved config must contain a JSON object")
        try expectEqual(object?["breakInterval"]?.doubleValue, 3.0)
        try expectEqual(object?["microbreakInterval"]?.doubleValue, 120000.0)
        try expectEqual(object?["language"]?.stringValue, "de")
    }

    static func importCreatesFile() throws {
        let dir = SettingsStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appendingPathComponent("legacy-config.json")
        try "{\"microbreakInterval\":900000}".write(to: legacyURL, atomically: true, encoding: .utf8)
        let url = dir.appendingPathComponent("config.json")
        let store = SettingsStore(url: url, loadNow: false)
        try expectTrue(store.importLegacyConfigIfPresent(legacyURL: legacyURL))
        try expectTrue(FileManager.default.fileExists(atPath: url.path),
                       "the import must create the native config file")
        let reread = SettingsStore(url: url)
        try expectEqual(reread.getMillis("microbreakInterval"), 900000)
    }

    static func restartRoundtrip() throws {
        let dir = SettingsStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let store = SettingsStore(url: url, loadNow: false)
        store.set("breakDuration", .int(120000))
        store.set("breakStrictMode", .bool(true))
        store.set("customKey", .string("kept"))
        let reread = SettingsStore(url: url)
        try expectEqual(reread.getMillis("breakDuration"), 120000)
        try expectEqual(reread.getBool("breakStrictMode"), true)
        try expectEqual(reread.getString("customKey"), "kept")
    }

    static func noTempLeftovers() throws {
        let dir = SettingsStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let store = SettingsStore(url: url, loadNow: false)
        for index in 0..<5 {
            store.set("breakInterval", .int(Int64(index + 1)))
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let temporaries = leftovers.filter { $0.hasPrefix(".config-") }
        try expectEqual(temporaries.count, 0, "temporary files left behind: \(temporaries)")
    }

    static func unwritableConfig() throws {
        let dir = SettingsStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        let store = SettingsStore(url: locked.appendingPathComponent("config.json"), loadNow: false)
        var reported: String?
        store.readOnlyFailureHandler = { message in reported = message }
        let persisted = store.persist()
        try expectFalse(persisted, "writing into a read-only directory must fail")
        try expectNotNil(reported, "the read-only failure must be reported to the user")
    }

    // MARK: Legacy assets

    static func legacyAssets() throws {
        let dir = SettingsStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("legacy")
        let native = dir.appendingPathComponent("native")
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("audio"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: native.appendingPathComponent("audio"), withIntermediateDirectories: true)
        try Data("legacy-audio".utf8).write(to: legacy.appendingPathComponent("audio/custom.wav"))
        try Data("legacy-image".utf8).write(to: legacy.appendingPathComponent("images/picture.png"))
        // A native file with the same name must not be overwritten.
        try Data("native-audio".utf8).write(to: native.appendingPathComponent("audio/custom.wav"))

        let result = LegacyAssets.importAssets(legacyDirectory: legacy, nativeDirectory: native)
        try expectEqual(result.copiedAudio, 0, "an existing native audio file must win")
        try expectEqual(result.skipped, 1)
        try expectEqual(result.copiedImages, 1)
        let copied = try Data(contentsOf: native.appendingPathComponent("images/picture.png"))
        try expectEqual(String(data: copied, encoding: .utf8), "legacy-image")
        let kept = try Data(contentsOf: native.appendingPathComponent("audio/custom.wav"))
        try expectEqual(String(data: kept, encoding: .utf8), "native-audio")
        // The legacy directory is read-only for the importer.
        try expectTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("audio/custom.wav").path))
    }

    static func legacyStamp() throws {
        let dir = SettingsStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("legacy")
        let native = dir.appendingPathComponent("native")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        try "2026-10-26T10:00:00.000+00:00".write(to: legacy.appendingPathComponent("stamp"),
                                                 atomically: true, encoding: .utf8)
        let result = LegacyAssets.importAssets(legacyDirectory: legacy, nativeDirectory: native)
        try expectTrue(result.importedStamp, "a legitimate stamp must be imported")
        try expectTrue(FileManager.default.fileExists(atPath: native.appendingPathComponent("stamp").path))

        // Garbage is not imported.
        let other = SettingsStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: other) }
        try "not a timestamp".write(to: legacy.appendingPathComponent("stamp"), atomically: true, encoding: .utf8)
        let second = LegacyAssets.importAssets(legacyDirectory: legacy, nativeDirectory: other)
        try expectFalse(second.importedStamp, "garbage must not be imported as a stamp")
    }

    // MARK: Health accounting

    static func healthAccounting() throws {
        try expectEqual(HealthPolicy.postponed(), 1, "legacy postpone raises the danger by 1 for Mini and Long")
        try expectEqual(HealthPolicy.completed(mini: true), -1)
        try expectEqual(HealthPolicy.completed(mini: false), -2)
        try expectEqual(HealthPolicy.skipped(mini: true), 1)
        try expectEqual(HealthPolicy.skipped(mini: false), 2)
        try expectEqual(HealthPolicy.paused(mini: true), 1)
        try expectEqual(HealthPolicy.paused(mini: false), 2)

        let tracker = HealthTracker(modeEnabled: true)
        tracker.increase(HealthPolicy.postponed())
        try expectEqual(tracker.danger, 1)
    }

    // MARK: Pollers

    static func pauseStopsPollers() throws {
        let store = SettingsStore(url: URL(fileURLWithPath: "/dev/null/unused.json"), loadNow: false)
        store.applyForTesting(DefaultSettings.values)
        let planner = BreaksPlanner(clock: ManualClock(), settings: store)
        var events: [PlannerEvent] = []
        planner.onEvent = { events.append($0) }

        planner.nextBreak()
        events.removeAll()
        planner.pause(1)
        try expectTrue(events.contains(.stopPollers), "pausing must stop the pollers")

        events.removeAll()
        planner.resume()
        let restarts = events.filter { $0 == .restartPollers }.count
        try expectEqual(restarts, 1, "resuming must restart the pollers exactly once")
    }

    // MARK: Clock format

    static func clockFormat() throws {
        // Luxon "tt" is a time-with-seconds macro, not the ICU "tt" (AM/PM marker).
        let timeWithSeconds = ClockFormat.icuPattern(fromLuxon: "tt")
        try expectTrue(timeWithSeconds.contains("ss"), "the time must show seconds, got '\(timeWithSeconds)'")
        try expectFalse(timeWithSeconds.contains("tt"), "the Luxon macro must be translated, got '\(timeWithSeconds)'")
        let formatter = ClockFormat.formatter(fromLuxon: "tt")
        let text = formatter.string(from: Date(timeIntervalSince1970: 0))
        try expectTrue(text.contains(":"), "the time must be rendered, got '\(text)'")

        // Luxon "T"/"TT" are 24 hour macros.
        try expectTrue(ClockFormat.icuPattern(fromLuxon: "TT").contains("HH"))
        try expectTrue(ClockFormat.icuPattern(fromLuxon: "T").contains("HH"))

        // The documented legacy format: "cccc, D, tt" is weekday + short date + time.
        let documented = ClockFormat.icuPattern(fromLuxon: "cccc, D, tt")
        try expectTrue(documented.contains("EEEE"), "cccc is the weekday name, got '\(documented)'")
        try expectTrue(documented.contains("M/d/y"), "D is the short date macro, got '\(documented)'")
        try expectFalse(documented.contains("'D'"), "D must not be a literal, got '\(documented)'")

        // Every produced pattern must be accepted by DateFormatter.
        for format in ["tt", "t", "T", "TT", "cccc, D, tt", "yyyy-MM-dd HH:mm:ss", "hh:mm a", "D", "f", "F"] {
            let pattern = ClockFormat.icuPattern(fromLuxon: format)
            let formatter = DateFormatter()
            formatter.dateFormat = pattern
            _ = formatter.string(from: Date())
        }
    }

    static func clockFormatUnknownTokens() throws {
        // 'b' is not an ICU pattern letter: it must be emitted as a literal.
        let pattern = ClockFormat.icuPattern(fromLuxon: "b")
        try expectTrue(pattern.contains("'b'"), "unknown letters must be quoted, got '\(pattern)'")
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        try expectEqual(formatter.string(from: Date(timeIntervalSince1970: 0)), "b")

        // Quoted literals stay literal.
        let quoted = ClockFormat.icuPattern(fromLuxon: "'at' HH")
        let quotedFormatter = DateFormatter()
        quotedFormatter.dateFormat = quoted
        try expectTrue(quotedFormatter.string(from: Date()).contains("at"))
    }

    static func clockFormatOutput() throws {
        // The documented legacy format, rendered for a fixed date.
        let formatter = ClockFormat.formatter(fromLuxon: "cccc, D, tt",
                                              locale: Locale(identifier: "en_US_POSIX"))
        formatter.timeZone = TimeZone(identifier: "UTC")
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 26
        components.hour = 19
        components.minute = 21
        components.second = 5
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: components)!
        let text = formatter.string(from: date)
        try expectFalse(text.contains("'"), "the formatted time must not contain apostrophes, got '\(text)'")
        try expectEqual(text, "Monday, 10/26/2026, 7:21:05 PM",
                       "the documented format must render weekday, short date and time with seconds")
    }

    // MARK: Foreground colours

    static func foregroundColors() throws {
        // A light background needs a dark foreground (legacy: black on Snow white).
        try expectEqual(Utils.foregroundColor(forBackground: "#ffffff"), "#000000")
        try expectEqual(Utils.foregroundColor(forBackground: "#FFFFFF"), "#000000")
        // The built-in dark themes keep the light foreground.
        try expectEqual(Utils.foregroundColor(forBackground: "#478484"), "#FFFFFF")
        try expectEqual(Utils.foregroundColor(forBackground: "#633738"), "#FFFFFF")
        try expectEqual(Utils.foregroundColor(forBackground: "#1d1f21"), "#FFFFFF")
        try expectEqual(Utils.foregroundColor(forBackground: "#567890"), "#FFFFFF")
        // A light warm grey (Coffee kisses) must not use white text.
        try expectEqual(Utils.foregroundColor(forBackground: "#a49898"), "#000000")
        // An unusable colour falls back to the light foreground.
        try expectEqual(Utils.foregroundColor(forBackground: "not-a-color"), "#FFFFFF")
    }

    // MARK: CLI server

    static func cliServerRestart() throws {
        let dir = SettingsStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketURL = dir.appendingPathComponent("cli.sock")
        let server = CliServer()
        try expectTrue(server.start(socketURL: socketURL), "first bind failed: \(server.lastError)")
        server.stop()
        // Stopping twice must not close a reused descriptor.
        server.stop()
        try expectTrue(server.start(socketURL: socketURL), "rebind after stop failed: \(server.lastError)")

        // A client that sends a partial frame must not block the server.
        let partial = socket(AF_UNIX, SOCK_STREAM, 0)
        try expectTrue(partial >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let connected = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(partial, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try expectEqual(connected, 0, "could not connect to the test socket")
        _ = write(partial, "{\"argv\":[\"pa", 11)

        let expectation = DispatchSemaphore(value: 0)
        var received: [String] = []
        server.onArgv = { argv in
            received = argv
            expectation.signal()
            return nil
        }
        let result = CliForwarder.forward(argvJSON: Data("{\"argv\":[\"pause\"]}".utf8), socketURL: socketURL)
        try expectEqual(result, .forwarded, "the server must still accept a complete frame")
        try expectTrue(expectation.wait(timeout: .now() + 5) == .success, "the complete frame was not dispatched")
        try expectEqual(received, ["pause"])
        close(partial)
        server.stop()
    }
}
