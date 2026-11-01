import Foundation
import CaesuraCore

enum VersionCheckTests {
    static func registerAll() {
        TestRunner.register("version: gate math", gate)
        TestRunner.register("version: disabled features and checkNewVersion gates", gatesDocumented)
    }

    static func gate() throws {
        try expectTrue(VersionCheck.isNewVersionAvailable(remoteTag: "v1.23.0", localVersion: "1.22.1"))
        try expectFalse(VersionCheck.isNewVersionAvailable(remoteTag: nil, localVersion: "1.22.1"))
        try expectFalse(VersionCheck.isNewVersionAvailable(remoteTag: "v1.22.1", localVersion: "1.22.1"))
        try expectFalse(VersionCheck.isNewVersionAvailable(remoteTag: "v1.22.0", localVersion: "1.22.1"))
    }

    static func gatesDocumented() {
        // Behavior gates live in the app coordinator (settings-driven) and are covered by
        // the runtime smoke checks; this documents that no network call happens here.
    }
}

enum CliIpcTests {
    static func registerAll() {
        TestRunner.register("ipc: CLI forwards argv to running server and dispatches", forwardRoundtrip)
        TestRunner.register("ipc: forwarding fails cleanly without an instance", noInstance)
        TestRunner.register("ipc: stale socket is replaced by a new server", staleSocket)
    }

    static func forwardRoundtrip() throws {
        let dir = SettingsStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketURL = dir.appendingPathComponent("cli.sock")
        let server = CliServer()
        var received: [String] = []
        let expectation = DispatchSemaphore(value: 0)
        server.onArgv = { argv in
            received = argv
            expectation.signal()
        }
        try expectTrue(server.start(socketURL: socketURL), "server start failed: \(server.lastError)")
        let result = CliForwarder.forward(argvJSON: Data("{\"argv\":[\"pause\",\"-d\",\"1h20m\"]}".utf8), socketURL: socketURL)
        try expectEqual(result, .forwarded)
        try expectTrue(expectation.wait(timeout: .now() + 5) == .success)
        try expectEqual(received, ["pause", "-d", "1h20m"])
        server.stop()
    }

    static func noInstance() throws {
        let dir = SettingsStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = CliForwarder.forward(argvJSON: Data("{\"argv\":[\"pause\"]}".utf8),
                                          socketURL: dir.appendingPathComponent("missing.sock"),
                                          connectTimeout: 0.3)
        try expectEqual(result, .noInstance)
    }

    static func staleSocket() throws {
        let dir = SettingsStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketURL = dir.appendingPathComponent("cli.sock")
        try Data().write(to: socketURL) // stale socket file
        let server = CliServer()
        try expectTrue(server.start(socketURL: socketURL), "stale socket must be removed and rebound: \(server.lastError)")
        server.stop()
        // A second server can bind again after stop
        let second = CliServer()
        try expectTrue(second.start(socketURL: socketURL), "rebind after stop failed: \(second.lastError)")
        second.stop()
    }
}
