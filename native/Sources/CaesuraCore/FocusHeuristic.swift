import Foundation

/// Best-effort macOS Focus (Do Not Disturb) detection.
///
/// IMPORTANT LIMITATION (same as legacy): macOS has no public API to read the current
/// Focus status. The legacy darwin branch shells out to `defaults read com.apple.controlcenter
/// "NSStatusItem VisibleCC FocusModes"` (or the pre-Tahoe key) — i.e. it reports whether the
/// Focus menu-bar item is *visible*, which correlates with, but does not prove, an active
/// Focus mode. This adapter preserves exactly that heuristic, isolates the parsing for
/// tests, and never claims real Focus coverage.
public struct FocusHeuristic {
    public static let tahoeKey = "NSStatusItem VisibleCC FocusModes"
    public static let legacyKey = "NSStatusItem Visible FocusModes"

    /// Reader abstraction so tests can inject canned `defaults` output.
    public var readDefault: (String, String) -> String?

    public init(readDefault: @escaping (String, String) -> String? = { domain, key in
        Self.systemReadDefault(domain: domain, key: key)
    }) {
        self.readDefault = readDefault
    }

    /// Runs /usr/bin/defaults with fixed arguments (no shell, no interpolation).
    public static func systemReadDefault(domain: String, key: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", domain, key]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    public static func currentMacOSMajorVersion() -> Int {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion
    }

    /// Legacy `_doNotDisturb` darwin branch. Returns the parsed boolean or nil when the
    /// state is unknown (key missing / command failed) — callers keep the previous state.
    public func isDoNotDisturbEnabled() -> Bool? {
        let major = Self.currentMacOSMajorVersion()
        let key = major >= 26 ? Self.tahoeKey : Self.legacyKey
        guard let output = readDefault("com.apple.controlcenter", key) else {
            return nil
        }
        return Self.parse(output: output)
    }

    /// Legacy parsing: strip everything but alphanumerics and compare to "1".
    public static func parse(output: String) -> Bool {
        let cleaned = output.replacingOccurrences(of: "[^0-9a-zA-Z]", with: "", options: .regularExpression)
        return cleaned == "1"
    }
}
