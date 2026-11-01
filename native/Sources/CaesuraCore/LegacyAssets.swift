import Foundation

/// One-time migration of the legacy Electron user data that lives outside the
/// settings file: custom `audio/` files, custom `images/` files and the contributor
/// stamp. The legacy directory is only ever read; native files are never overwritten.
public enum LegacyAssets {
    public struct Result: Equatable {
        public var copiedAudio: Int = 0
        public var copiedImages: Int = 0
        public var importedStamp: Bool = false
        public var skipped: Int = 0

        public var isEmpty: Bool {
            copiedAudio == 0 && copiedImages == 0 && !importedStamp
        }
    }

    /// Copies the legacy assets into the native directories. Files that already exist
    /// natively are kept (the native copy wins), the legacy ones are added.
    @discardableResult
    public static func importAssets(legacyDirectory: URL, nativeDirectory: URL) -> Result {
        var result = Result()
        let fm = FileManager.default

        let audioSource = legacyDirectory.appendingPathComponent("audio", isDirectory: true)
        let audioTarget = nativeDirectory.appendingPathComponent("audio", isDirectory: true)
        result.copiedAudio += copyContents(of: audioSource, to: audioTarget, result: &result)

        let imagesSource = legacyDirectory.appendingPathComponent("images", isDirectory: true)
        let imagesTarget = nativeDirectory.appendingPathComponent("images", isDirectory: true)
        result.copiedImages += copyContents(of: imagesSource, to: imagesTarget, result: &result)

        let stampSource = legacyDirectory.appendingPathComponent("stamp")
        let stampTarget = nativeDirectory.appendingPathComponent("stamp")
        if !fm.fileExists(atPath: stampTarget.path),
           fm.fileExists(atPath: stampSource.path),
           let data = try? Data(contentsOf: stampSource),
           let text = String(data: data, encoding: .utf8),
           isPlausibleStamp(text) {
            do {
                try fm.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
                try data.write(to: stampTarget, options: .atomic)
                result.importedStamp = true
            } catch {
                Log.warn("Caesura: could not import legacy contributor stamp: \(error)")
            }
        }
        return result
    }

    /// Copies the files of `source` into `target` without overwriting existing files.
    private static func copyContents(of source: URL, to target: URL, result: inout Result) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return 0 }
        let entries = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
        var copied = 0
        for entry in entries {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let destination = target.appendingPathComponent(entry.lastPathComponent)
            if fm.fileExists(atPath: destination.path) {
                result.skipped += 1
                continue
            }
            do {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try fm.copyItem(at: entry, to: destination)
                copied += 1
            } catch {
                Log.warn("Caesura: could not copy legacy asset \(entry.lastPathComponent): \(error)")
            }
        }
        return copied
    }

    /// A legitimate stamp is an ISO-8601 timestamp (legacy `DateTime.now().toString()`).
    private static func isPlausibleStamp(_ text: String) -> Bool {
        LegacyStamp.parse(text) != nil
    }
}
