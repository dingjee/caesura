import Foundation

public struct SettingsLoadDiagnostic {
    public enum Kind: String {
        case createdFresh = "created fresh config"
        case loaded = "loaded"
        case malformedReplaced = "malformed config replaced with defaults (bad file backed up)"
        case legacyImported = "legacy Electron config imported (backed up)"
        case unsafeValuesReplaced = "unsafe values replaced with defaults"
        case writeFailed = "write failed"
    }
    public let kind: Kind
    public let detail: String
}

/// JSON-compatible settings store. Uses a separate native location and never writes the
/// user's real Electron settings. Writes are atomic (tmp + rename). Unknown keys are
/// preserved; unsafe known values fall back to defaults (see SettingsPolicy).
public final class SettingsStore {
    public let url: URL
    public private(set) var values: [String: SettingsValue]
    public private(set) var diagnostics: [SettingsLoadDiagnostic] = []

    /// Called after every successful set; the application reinitializes accordingly
    /// (mirrors electron-store `watch` + explicit `save-setting` handling).
    public var onChange: ((String, SettingsValue) -> Void)?

    public init(url: URL, loadNow: Bool = true) {
        self.url = url
        values = DefaultSettings.values
        if loadNow { load() }
    }

    public var readOnlyFailureHandler: ((String) -> Void)?

    // MARK: Access

    public func get(_ key: String) -> SettingsValue? { values[key] }

    public func getBool(_ key: String) -> Bool { values[key]?.boolValue ?? (DefaultSettings.values[key]?.boolValue ?? false) }

    public func getMillis(_ key: String) -> Int64 {
        let fallback = DefaultSettings.values[key]?.doubleValue ?? 0
        let value = values[key]?.doubleValue ?? fallback
        // A finite double can still be outside Int64: clamp instead of trapping.
        guard value.isFinite else { return 0 }
        if value >= Double(Int64.max) { return Int64.max }
        if value <= Double(Int64.min) { return Int64.min }
        return Int64(value)
    }

    public func getDouble(_ key: String) -> Double {
        let fallback = DefaultSettings.values[key]?.doubleValue ?? 0
        return values[key]?.doubleValue ?? fallback
    }

    public func getString(_ key: String) -> String { values[key]?.stringValue ?? (DefaultSettings.values[key]?.stringValue ?? "") }

    /// The value of a count with a range: an integer inside the range of the key.
    ///
    /// A missing key, a value of the wrong type and a value outside the range
    /// fall back to the default of the key. The storage already rejects unsafe
    /// values when the file is read; this is the second line of defence for
    /// values that reached the store another way.
    public func getBoundedCount(_ key: String) -> Int {
        let fallback = Int(DefaultSettings.values[key]?.doubleValue ?? 0)
        guard let range = SettingsPolicy.boundedCountKeys[key] else { return fallback }
        guard let raw = values[key]?.doubleValue, raw.isFinite,
              raw == raw.rounded(.towardZero) else { return fallback }
        let whole = Int(raw)
        return range.contains(whole) ? whole : fallback
    }

    /// The value of a multiplier with a range: a finite number inside the range
    /// of the key, clamped into it.
    ///
    /// A missing key and a value of the wrong type fall back to the default of
    /// the key; a value outside the range is clamped into it. The storage
    /// already applies the same rule when the file is read; this is the second
    /// line of defence for values that reached the store another way.
    public func getBoundedDouble(_ key: String) -> Double {
        let fallback = DefaultSettings.values[key]?.doubleValue ?? 0
        guard let range = SettingsPolicy.boundedDoubleKeys[key] else { return fallback }
        guard let raw = values[key]?.doubleValue, raw.isFinite else { return fallback }
        return min(max(raw, range.lowerBound), range.upperBound)
    }

    public func getArray(_ key: String) -> [SettingsValue] { values[key]?.arrayValue ?? [] }

    public func setObject(_ key: String, anyObject: [String: Any]) {
        set(key, SettingsValue.from(json: anyObject))
    }

    // MARK: Mutation

    public func set(_ key: String, _ value: SettingsValue) {
        // A known key never keeps an unsafe value: it falls back to the default
        // of the key, the same way the file load does it.
        let safe = SettingsPolicy.sanitized(key: key, value: value,
                                            default: DefaultSettings.values[key] ?? .null) ?? value
        values[key] = safe
        persist()
        onChange?(key, safe)
    }

    public func remove(_ key: String) {
        values.removeValue(forKey: key)
        persist()
    }

    /// Writes a value without notifying the observers.
    ///
    /// Used by the state the application owns itself (the rotation of the
    /// poems): writing it must not run the `onChange` chain, because that
    /// chain reinitializes parts of the app (the idea decks, the machines of the
    /// planner) and a progress write must never restart the scheduler.
    public func setWithoutNotification(_ key: String, _ value: SettingsValue) {
        values[key] = value
        persist()
    }

    public func updateWithoutNotification(_ newValues: [String: SettingsValue]) {
        values = newValues
        persist()
    }

    /// Merges an externally supplied object (e.g. a remote sync payload) over the
    /// defaults, applying the same safety policy as a file load: unknown keys are
    /// preserved, unsafe known values fall back to their default.
    public func mergeSanitized(_ object: [String: SettingsValue]) {
        values = mergeDefaultsAndSanitize(object)
        persist()
    }

    /// In-memory only (tests): replaces values without touching disk.
    public func applyForTesting(_ newValues: [String: SettingsValue]) {
        values = newValues
    }

    // MARK: Persistence

    public func load() {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if persist() {
                diagnostics.append(SettingsLoadDiagnostic(kind: .createdFresh, detail: url.path))
            }
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            diagnostics.append(SettingsLoadDiagnostic(kind: .malformedReplaced, detail: "unreadable file \(url.path)"))
            values = DefaultSettings.values
            _ = persist()
            return
        }
        let parsed: SettingsValue
        do {
            parsed = try SettingsValue.from(jsonObject: data)
        } catch {
            backupMalformed(data)
            diagnostics.append(SettingsLoadDiagnostic(kind: .malformedReplaced, detail: "\(error)"))
            values = DefaultSettings.values
            _ = persist()
            return
        }
        guard var object = parsed.objectValue else {
            backupMalformed(data)
            diagnostics.append(SettingsLoadDiagnostic(kind: .malformedReplaced, detail: "config root is not an object"))
            values = DefaultSettings.values
            _ = persist()
            return
        }
        object = mergeDefaultsAndSanitize(object)
        values = object
        diagnostics.append(SettingsLoadDiagnostic(kind: .loaded, detail: url.path))
    }

    /// Legacy one-time import. If the native config file does not exist yet and a legacy
    /// Electron config exists, import it: back up the original into the native dir, apply
    /// the legacy migrations, sanitize, and persist. Never touches the legacy file.
    @discardableResult
    public func importLegacyConfigIfPresent(legacyURL: URL) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return false }
        guard let data = try? Data(contentsOf: legacyURL),
              let parsed = try? SettingsValue.from(jsonObject: data),
              let object = parsed.objectValue else { return false }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backupURL = url.deletingLastPathComponent().appendingPathComponent("legacy-config-backup.json")
        try? data.write(to: backupURL, options: .atomic)
        let migrated = LegacyMigrations.apply(object)
        values = mergeDefaultsAndSanitize(migrated, sanitizeIdeas: false)
        persist()
        diagnostics.append(SettingsLoadDiagnostic(kind: .legacyImported, detail: legacyURL.path))
        return true
    }

    @discardableResult
    public func persist() -> Bool {
        do {
            let data = try SettingsValue.object(values).jsonData()
            try writeAtomically(data)
            return true
        } catch {
            let message = "Caesura: saving settings failed: \(error)"
            Log.error(message)
            readOnlyFailureHandler?(message)
            return false
        }
    }

    /// Atomic write: a temporary file in the same directory followed by a rename.
    /// `replaceItemAt` is only usable when the destination already exists, so the
    /// first save (fresh config, legacy import) goes through `rename(2)`.
    private func writeAtomically(_ data: Data) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".config-\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        defer { try? fm.removeItem(at: tmp) }
        if fm.fileExists(atPath: url.path),
           (try? fm.replaceItemAt(url, withItemAt: tmp, backupItemName: nil, options: [])) != nil {
            return
        }
        guard rename(tmp.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "could not write \(url.path) (errno \(errno))"])
        }
    }

    private func mergeDefaultsAndSanitize(_ object: [String: SettingsValue], sanitizeIdeas: Bool = true) -> [String: SettingsValue] {
        var result = DefaultSettings.values
        var replaced: [String] = []
        for (key, value) in object {
            if key == "breakIdeas" || key == "microbreakIdeas" {
                // Custom ideas may be any JSON array; default is empty placeholder.
                result[key] = value.arrayValue != nil ? value : DefaultSettings.values[key]!
                continue
            }
            if let replacement = SettingsPolicy.sanitized(key: key, value: value, default: DefaultSettings.values[key] ?? .null) {
                result[key] = replacement
                replaced.append(key)
            } else {
                result[key] = value
            }
        }
        if !replaced.isEmpty {
            diagnostics.append(SettingsLoadDiagnostic(kind: .unsafeValuesReplaced, detail: replaced.joined(separator: ", ")))
        }
        return result
    }

    private func backupMalformed(_ data: Data) {
        let backupURL = url.deletingLastPathComponent().appendingPathComponent("malformed-config-backup.json")
        try? data.write(to: backupURL, options: .atomic)
    }
}

public enum LegacyMigrations {
    /// Ports the electron-store migrations (1.13.0 … 1.22.0) onto a raw legacy object.
    public static func apply(_ input: [String: SettingsValue]) -> [String: SettingsValue] {
        var s = input
        // 1.13.0
        if let old = s["pauseBreaksShortcut"]?.stringValue {
            s["pauseBreaksToggleShortcut"] = .string(old)
            s.removeValue(forKey: "pauseBreaksShortcut")
        }
        s.removeValue(forKey: "resumeBreaksShortcut")
        // 1.17.0
        if let old = s["showBreakActionsInStrictMode"]?.boolValue {
            s["showTrayMenuInStrictMode"] = .bool(old)
            s.removeValue(forKey: "showBreakActionsInStrictMode")
        }
        // 1.19.0
        if let legacyAudio = s["audio"]?.stringValue {
            s["longBreakAudio"] = .string(legacyAudio)
            s.removeValue(forKey: "audio")
        }
        if let playing = s["microbreakStartSoundPlaying"]?.boolValue {
            let mini = playing ? (s["miniBreakAudio"]?.stringValue ?? "crystal-glass") : "silence"
            s["miniBreakStartSound"] = .string(mini)
            s.removeValue(forKey: "microbreakStartSoundPlaying")
        }
        if let playing = s["breakStartSoundPlaying"]?.boolValue {
            let long = playing ? (s["longBreakAudio"]?.stringValue ?? "crystal-glass") : "silence"
            s["longBreakStartSound"] = .string(long)
            s.removeValue(forKey: "breakStartSoundPlaying")
        }
        // 1.20.0
        if let timeInTray = s["timeToBreakInTray"]?.boolValue {
            s["trayIconStyle"] = .string(timeInTray ? "time" : "default")
            s.removeValue(forKey: "timeToBreakInTray")
        }
        // 1.22.0
        if let inverted = s["useMonochromeInvertedTrayIcon"]?.boolValue {
            s["trayIconThemeSource"] = .string(inverted ? "dark" : "system")
            s.removeValue(forKey: "useMonochromeInvertedTrayIcon")
        }
        if s["appExclusionsCheckInterval"]?.doubleValue == 1000 {
            s["appExclusionsCheckInterval"] = .int(2000)
        }
        return s
    }
}
