import Foundation

/// Native replacement for i18next + humanize-duration.
/// - Bundles all 54 locale JSON files unchanged (SPM resources).
/// - `{{interpolation}}` and JSON-v4 plural suffixes (`_one`, `_few`, `_other`, …)
///   selected with CLDR plural rules for the bundled languages.
/// - Falls back to `en` like i18next `fallbackLng: 'en'`.
/// - `dir()` reports RTL for he/fa/ar-family/ur/yi like i18next.
/// - Humanized durations use ICU (Foundation `Duration` formatting) for the unit words,
///   wrapped with the locale's own `utils.remaining`/`utils.elapsed`/`utils.inAbout`
///   strings. Wording can differ from the humanize-duration package (declared limitation
///   in the settings documentation) while staying localized.
public final class Localization {
    public static let rtlLanguages: Set<String> = ["ar", "ajp", "arz", "fa", "he", "ur", "yi"]

    private let bundle: Bundle
    private var caches: [String: [String: Any]] = [:]
    private var languageCache: [String: Any]?
    public private(set) var language: String = "en"

    private func resourceSubdirectory(_ name: String) -> String? {
        // SPM .copy strips the "Resources/" segment in built bundles; older layouts keep it.
        for candidate in [name, "Resources/\(name)"] {
            if bundle.path(forResource: "en", ofType: "json", inDirectory: candidate) != nil
                || (bundle.urls(forResourcesWithExtension: "json", subdirectory: candidate) ?? []).count > 0 {
                return candidate
            }
        }
        return name
    }

    private func localesSubdirectory() -> String {
        resourceSubdirectory("locales") ?? "locales"
    }

    public static var availableLanguages: [String] {
        let bundle = Bundle.module
        let candidates = ["locales", "Resources/locales"]
        for candidate in candidates {
            let paths = bundle.urls(forResourcesWithExtension: "json", subdirectory: candidate) ?? []
            if !paths.isEmpty {
                return paths.compactMap { $0.deletingPathExtension().lastPathComponent }.sorted()
            }
        }
        return []
    }

    public init(bundle: Bundle? = nil) {
        self.bundle = bundle ?? .module
    }

    // MARK: Dictionary access

    private func dictionary(for language: String) -> [String: Any]? {
        if let cached = caches[language] { return cached }
        guard let url = bundle.url(forResource: language, withExtension: "json", subdirectory: localesSubdirectory()),
              let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        caches[language] = object
        return object
    }

    public func setLanguage(_ code: String) {
        let normalized = dictionary(for: code) != nil ? code : "en"
        language = normalized
        languageCache = dictionary(for: normalized)
    }

    private var currentDictionary: [String: Any] {
        if let languageCache { return languageCache }
        setLanguage(language)
        return languageCache ?? [:]
    }

    public func dir() -> String {
        Self.rtlLanguages.contains(language) || Self.rtlLanguages.contains(baseLanguage(language)) ? "rtl" : "ltr"
    }

    private func baseLanguage(_ code: String) -> String {
        code.split(separator: "-").first.map(String.init) ?? code
    }

    // MARK: Translation

    public func t(_ key: String, options: [String: Any] = [:]) -> String {
        if let count = options["count"] {
            let number = (count as? NSNumber)?.doubleValue ?? (count as? Double) ?? (count as? Int).map(Double.init) ?? 0
            return pluralized(key: key, count: number, options: options)
        }
        if let value = resolve(key: key, languageCode: language) {
            return interpolate(value, options: options)
        }
        if let value = resolve(key: key, languageCode: "en") {
            return interpolate(value, options: options)
        }
        return key
    }

    /// Returns the raw object under a key (for idea lists), like i18next returnObjects.
    public func subtree(_ key: String, languageCode: String? = nil) -> [String: Any]? {
        let code = languageCode ?? language
        return resolveObject(key: key, languageCode: code) ?? resolveObject(key: key, languageCode: "en")
    }

    private func pluralized(key: String, count: Double, options: [String: Any]) -> String {
        let category = PluralRules.category(language: baseLanguage(language), count: count)
        let candidates = ["\(key)_\(category)", key, "\(key)_other"]
        for candidate in candidates {
            if let value = resolve(key: candidate, languageCode: language) {
                return interpolate(value, options: options)
            }
        }
        let englishCategory = PluralRules.category(language: "en", count: count)
        for candidate in ["\(key)_\(englishCategory)", "\(key)_other", key] {
            if let value = resolve(key: candidate, languageCode: "en") {
                return interpolate(value, options: options)
            }
        }
        return key
    }

    private func resolve(key: String, languageCode: String) -> String? {
        var node: Any = dictionary(for: languageCode) ?? [:]
        var next: Any = node
        for component in key.split(separator: ".") {
            guard let dict = next as? [String: Any], let value = dict[String(component)] else { return nil }
            next = value
        }
        node = next
        return node as? String
    }

    private func resolveObject(key: String, languageCode: String) -> [String: Any]? {
        var next: Any = dictionary(for: languageCode) ?? [:]
        for component in key.split(separator: ".") {
            guard let dict = next as? [String: Any], let value = dict[String(component)] else { return nil }
            next = value
        }
        return next as? [String: Any]
    }

    private func interpolate(_ template: String, options: [String: Any]) -> String {
        // Pass 1: resolve {{name}} placeholders.
        var result = replacePlaceholders(template, options: options)
        // Pass 2+: resolve i18next nested translations `$t(key, { 'name': value })`.
        for _ in 0..<5 {
            let next = replaceNestedTranslations(result, options: options)
            if next == result { break }
            result = next
        }
        return result
    }

    private func replacePlaceholders(_ template: String, options: [String: Any]) -> String {
        var result = template
        let pattern = try! NSRegularExpression(pattern: "\\{\\{(\\w+)\\}\\}")
        let range = NSRange(result.startIndex..., in: result)
        var replacements: [(NSRange, String)] = []
        pattern.enumerateMatches(in: result, range: range) { match, _, _ in
            guard let match, let nameRange = Range(match.range(at: 1), in: result) else { return }
            let name = String(result[nameRange])
            let replacement = Self.renderOption(options[name])
            replacements.append((match.range, replacement))
        }
        for (range, replacement) in replacements.reversed() {
            if let swiftRange = Range(range, in: result) {
                result.replaceSubrange(swiftRange, with: replacement)
            }
        }
        return result
    }

    /// Matches `$t(key, { 'name': value, ... })` where values are literals produced by
    /// pass 1 (numbers or single-quoted strings).
    private func replaceNestedTranslations(_ template: String, options: [String: Any]) -> String {
        let pattern = try! NSRegularExpression(pattern: #"\$t\(([\w.]+)(?:,\s*\{([^}]*)\})?\)"#)
        let range = NSRange(template.startIndex..., in: template)
        var replacements: [(NSRange, String)] = []
        pattern.enumerateMatches(in: template, range: range) { match, _, _ in
            guard let match else { return }
            guard let keyRange = Range(match.range(at: 1), in: template) else { return }
            let key = String(template[keyRange])
            var callOptions: [String: Any] = [:]
            if match.range(at: 2).location != NSNotFound, let optionsRange = Range(match.range(at: 2), in: template) {
                let rawString = String(template[optionsRange])
                let pairPattern = try! NSRegularExpression(pattern: #"'(\w+)'\s*:\s*('(?:[^'\\]|\\.)*'|[\w.+-]+)"#)
                let pairRange = NSRange(rawString.startIndex..., in: rawString)
                pairPattern.enumerateMatches(in: rawString, range: pairRange) { pair, _, _ in
                    guard let pair, let nameRange = Range(pair.range(at: 1), in: rawString),
                          let valueRange = Range(pair.range(at: 2), in: rawString) else { return }
                    let name = String(rawString[nameRange])
                    let value = String(rawString[valueRange])
                    if value.hasPrefix("'") {
                        callOptions[name] = value
                            .replacingOccurrences(of: "\\'", with: "'")
                            .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                    } else if let number = Double(value) {
                        callOptions[name] = number
                    } else {
                        callOptions[name] = value
                    }
                }
            }
            replacements.append((match.range, t(key, options: callOptions)))
        }
        var result = template
        for (range, replacement) in replacements.reversed() {
            if let swiftRange = Range(range, in: result) {
                result.replaceSubrange(swiftRange, with: replacement)
            }
        }
        _ = options
        return result
    }

    static func renderOption(_ value: Any?) -> String {
        guard let value else { return "" }
        switch value {
        case let n as NSNumber: return renderNumber(n.doubleValue)
        case let d as Double: return renderNumber(d)
        case let i as Int: return String(i)
        case let i64 as Int64: return String(i64)
        case let s as String: return s
        default: return String(describing: value)
        }
    }

    static func renderNumber(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int(value))
        }
        return "\(value)"
    }

    // MARK: Duration formatting

    public func humanizeDuration(_ millis: Int64, units allowed: [String]? = nil) -> String {
        let unitTable: [(name: String, seconds: Int, icu: ICUUnit)] = [
            ("days", 86400, .days),
            ("hours", 3600, .hours),
            ("minutes", 60, .minutes),
            ("seconds", 1, .seconds)
        ]
        let totalSeconds = Double(millis) / 1000.0
        for unit in unitTable {
            if let allowed, !allowed.contains(unit.name) { continue }
            let rounded = (totalSeconds / Double(unit.seconds)).rounded()
            if rounded >= 1 {
                return icuDuration(seconds: rounded * Double(unit.seconds), unit: unit.icu)
            }
        }
        // Everything below the smallest allowed unit still names that unit.
        let fallbackUnit = unitTable.last { unit in allowed?.contains(unit.name) ?? true } ?? unitTable[3]
        return icuDuration(seconds: 0, unit: fallbackUnit.icu)
    }

    private enum ICUUnit {
        case days, hours, minutes, seconds
    }

    private func icuDuration(seconds: Double, unit: ICUUnit) -> String {
        let locale = Locale(identifier: language)
        let style: Duration.UnitsFormatStyle
        switch unit {
        case .days:
            style = .units(allowed: [.days], width: .wide, maximumUnitCount: 1)
        case .hours:
            style = .units(allowed: [.hours], width: .wide, maximumUnitCount: 1)
        case .minutes:
            style = .units(allowed: [.minutes], width: .wide, maximumUnitCount: 1)
        case .seconds:
            style = .units(allowed: [.seconds], width: .wide, maximumUnitCount: 1)
        }
        return Duration.seconds(seconds).formatted(style.locale(locale))
    }

    // Legacy utils.js wrappers.
    public func formatTimeRemaining(_ milliseconds: Int64) -> String {
        t("utils.remaining", options: ["count": humanizeDuration(milliseconds)])
    }

    public func formatElapsedDuration(_ milliseconds: Int64) -> String {
        t("utils.elapsed", options: ["count": humanizeDuration(milliseconds)])
    }

    public func formatTimeIn(_ milliseconds: Int64) -> String {
        t("utils.inAbout", options: ["count": humanizeDuration(milliseconds, units: ["days", "hours", "minutes"])])
    }

    public func formatUnitAndValue(unit: String, value: Double) -> String {
        if unit == "seconds" {
            if value < 60 {
                return t("utils.seconds", options: ["count": value.rounded(.towardZero)])
            }
            let val = ((value / 60) * 10).rounded() / 10
            return t("utils.minutes", options: ["count": val])
        }
        return t("utils.\(unit)", options: ["count": value.rounded(.towardZero)])
    }
}

/// CLDR plural-rule categories for exactly the bundled locales. Operands:
/// n = |value|, i = integer part, v = fraction-digit count, f = fraction digits.
public enum PluralRules {
    public static func category(language: String, count: Double) -> String {
        let n = abs(count)
        let i = floor(n)
        let fractional = n - i
        // v: number of visible fraction digits; f: their value.
        var v = 0
        var f = 0
        if fractional > 0 {
            var text = String(fractional)
            text.removeFirst(2) // "0."
            v = text.count
            f = Int(text.prefix(9)) ?? 0
        }
        let mod10 = Int(i.truncatingRemainder(dividingBy: 10))
        let mod100 = Int(i.truncatingRemainder(dividingBy: 100))

        switch language {
        case "ajp", "arz":
            if n == 0 { return "zero" }
            if n == 1 { return "one" }
            if n == 2 { return "two" }
            if mod100._in(3...10) { return "few" }
            if mod100._in(11...99) { return "many" }
            return "other"
        case "be":
            if mod10 == 1, mod100 != 11 { return "one" }
            if mod10._in(2...4), !(12...14).contains(mod100) { return "few" }
            if mod10 == 0 || mod10._in(5...9) || (11...14).contains(mod100) { return "many" }
            return "other"
        case "bg", "gl", "nb-NO", "pu", "ta", "tr", "el", "hu", "mk", "eo":
            if n == 1 { return "one" }
            return "other"
        case "bn", "fa", "gu", "hi":
            if i == 0 || n == 1 { return "one" }
            return "other"
        case "cs", "sk":
            if i == 1, v == 0 { return "one" }
            if i._in(2...4), v == 0 { return "few" }
            if v != 0 { return "many" }
            return "other"
        case "cy":
            if n == 0 { return "zero" }
            if n == 1 { return "one" }
            if n == 2 { return "two" }
            if n == 3 { return "few" }
            if n == 6 { return "many" }
            return "other"
        case "da":
            if n == 1 { return "one" }
            return "other"
        case "de", "en", "et", "fi", "nl", "sv", "yi", "ca":
            if i == 1, v == 0 { return "one" }
            return "other"
        case "es", "it", "pt", "pt-BR":
            if language == "es" {
                if n == 1 { return "one" }
            } else if language == "pt" || language == "pt-BR" {
                if i._in(0...1) { return "one" }
            } else { // it
                if i == 1, v == 0 { return "one" }
            }
            return "other"
        case "eu", "np", "ro":
            if language == "ro" {
                if i == 1, v == 0 { return "one" }
                if v != 0 || n == 0 || mod100._in(1...19) { return "few" }
                return "other"
            }
            if n == 1 { return "one" }
            return "other"
        case "fil":
            if v == 0, i._in(0...3) { return "one" }
            return "other"
        case "he":
            if i == 1, v == 0 { return "one" }
            if i == 2, v == 0 { return "two" }
            if v == 0, n > 10, mod10 == 0 { return "many" }
            return "other"
        case "id", "ja", "ko", "th", "vi", "zh-CN", "zh-TW":
            return "other"
        case "lt":
            if mod10 == 1, !(11...19).contains(mod100) { return "one" }
            if mod10._in(2...9), !(11...19).contains(mod100) { return "few" }
            if fractional != 0 { return "many" }
            return "other"
        case "lv":
            if mod10 == 0 || (11...19).contains(mod100) || (v == 2 && (f / 10) % 10 == 0) { return "zero" }
            if mod10 == 1, mod100 != 11, v == 2 && (f % 10) == 1 && (f / 10) % 10 != 1 { return "one" }
            return "other"
        case "pl":
            if i == 1, v == 0 { return "one" }
            if v == 0, mod10._in(2...4), !(12...14).contains(mod100) { return "few" }
            if v == 0, (mod10._in(0...1) && mod10 != 1 && i != 0) || (mod10._in(5...9)) || ((12...14).contains(mod100)) {
                return "many"
            }
            return "other"
        case "ru", "uk":
            if v == 0, mod10 == 1, mod100 != 11 { return "one" }
            if v == 0, mod10._in(2...4), !(12...14).contains(mod100) { return "few" }
            if v == 0, mod10 == 0 || mod10._in(5...9) || (11...14).contains(mod100) { return "many" }
            return "other"
        case "si":
            if n == 0 || n == 1 || (i == 0 && f == 1) { return "one" }
            return "other"
        case "sl":
            if mod100 == 1 { return "one" }
            if mod100 == 2 { return "two" }
            if (3...4).contains(mod100) || v != 0 { return "few" }
            return "other"
        case "sr":
            if v == 0, mod10 == 1, mod100 != 11 { return "one" }
            if v == 0, mod10._in(2...4), !(12...14).contains(mod100) { return "few" }
            return "other"
        default:
            if i == 1, v == 0 { return "one" }
            return "other"
        }
    }
}

private extension Int {
    func _in(_ range: ClosedRange<Int>) -> Bool {
        range.contains(self)
    }
}

private extension Double {
    func _in(_ range: ClosedRange<Int>) -> Bool {
        range.contains(Int(self))
    }
}
