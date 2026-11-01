import Foundation
import CaesuraCore

enum TrialProfileTests {
    static func registerAll() {
        TestRunner.register("trial: first import copies settings and assets without changing the source", firstImport)
        TestRunner.register("trial: later imports preserve the user's trial settings and assets", preservesTrial)
        TestRunner.register("trial: first import preserves existing destination assets", preservesAssets)
        TestRunner.register("trial: missing source config does not create a profile", missingSource)
    }

    private static func fixture(_ body: (URL, URL) throws -> Void) throws {
        let directory = SettingsStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("ordinary"), directory.appendingPathComponent("trial"))
    }

    private static func write(_ text: String, at directory: URL, path: String) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private static func read(_ directory: URL, path: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(path))
    }

    private static func firstImport() throws {
        try fixture { source, destination in
            let files = [
                "config.json": "{\"microbreakInterval\":123456,\"language\":\"zh-CN\",\"futureSetting\":true,\"poemRotation\":{\"position\":4,\"showings\":2,\"reveal\":{\"words\":19}},\"poemRevealProgress\":{\"previous\":7},\"_migratedOpenAtLogin\":true}",
                "audio/custom.wav": "custom audio",
                "images/custom.png": "custom image"
            ]
            for (path, content) in files { try write(content, at: source, path: path) }
            try expectTrue(TrialSupport.importProfile(from: source, to: destination))
            for (path, content) in files {
                try expectEqual(read(destination, path: path), Data(content.utf8))
                try expectEqual(read(source, path: path), Data(content.utf8))
            }
            try write("trial audio", at: destination, path: "audio/custom.wav")
            try expectEqual(read(source, path: "audio/custom.wav"), Data("custom audio".utf8))
        }
    }

    private static func preservesTrial() throws {
        try fixture { source, destination in
            try write("{\"language\":\"en\"}", at: source, path: "config.json")
            try write("ordinary audio", at: source, path: "audio/custom.wav")
            try expectTrue(TrialSupport.importProfile(from: source, to: destination))
            let trialConfig = "{\"language\":\"zh-CN\",\"microbreakInterval\":987654}"
            try write(trialConfig, at: destination, path: "config.json")
            try write("trial audio", at: destination, path: "audio/custom.wav")
            try write("{\"language\":\"fr\"}", at: source, path: "config.json")
            try expectFalse(TrialSupport.importProfile(from: source, to: destination))
            try expectEqual(read(destination, path: "config.json"), Data(trialConfig.utf8))
            try expectEqual(read(destination, path: "audio/custom.wav"), Data("trial audio".utf8))
            try expectEqual(read(source, path: "config.json"), Data("{\"language\":\"fr\"}".utf8))
        }
    }

    private static func preservesAssets() throws {
        try fixture { source, destination in
            try write("{}", at: source, path: "config.json")
            try write("ordinary audio", at: source, path: "audio/custom.wav")
            try write("trial audio", at: destination, path: "audio/custom.wav")
            try expectTrue(TrialSupport.importProfile(from: source, to: destination))
            try expectEqual(read(destination, path: "audio/custom.wav"), Data("trial audio".utf8))
        }
    }

    private static func missingSource() throws {
        try fixture { source, destination in
            try expectFalse(TrialSupport.importProfile(from: source, to: destination))
            try expectFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }
}
