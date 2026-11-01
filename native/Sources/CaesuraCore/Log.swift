import Foundation

public enum Log {
    public static var logFileURL: URL = AppPaths.defaultLogURL
    private static let queue = DispatchQueue(label: "caesura.log")
    private static let lock = NSLock()

    public static func configure(dataDirectory: URL) {
        lock.lock()
        logFileURL = dataDirectory.appendingPathComponent("caesura-native.log")
        lock.unlock()
    }

    public static func append(_ level: String, _ message: String) {
        let line = "\(Timestamp.iso(clock: SystemClock())) Caesura [\(level)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        let url = logFileURL
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                handle.write(line.data(using: .utf8) ?? Data())
            } else {
                try? line.data(using: .utf8)?.write(to: url, options: .atomic)
            }
        }
    }

    public static func info(_ message: String) { append("info", message) }
    public static func warn(_ message: String) { append("warn", message) }
    public static func error(_ message: String) { append("error", message) }

    /// Waits for the queued log lines to be written. Used before the app exits,
    /// so the last line is not lost.
    public static func flush() {
        queue.sync {}
    }
}

enum Timestamp {
    static func iso(clock: Clock) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(clock.nowMillis) / 1000))
    }
}
