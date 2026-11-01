import Foundation

/// Shared calculations for timing, layout and appearance.
public enum Utils {
    /// The golden ratio φ: the step of the type scale of the break window and
    /// the step of the transparency of the background modes.
    public static let goldenRatio: Double = 1.618033988749895

    /// Does not consider `postponesLimit`.
    public static func canPostpone(postpone: Bool, passedPercent: Double, postponePercent: Double) -> Bool {
        postpone && passedPercent <= postponePercent
    }

    /// Does not consider `postponesLimit`.
    public static func canSkip(strictMode: Bool, postpone: Bool, passedPercent: Double, postponePercent: Double) -> Bool {
        !((postpone && passedPercent <= postponePercent) || strictMode)
    }

    public static func formatKeyboardShortcut(_ shortcut: String) -> String {
        shortcut.replacingOccurrences(of: "Or", with: "/").replacingOccurrences(of: "+", with: " + ")
    }

    public static func minutesRemaining(_ milliseconds: Int64?) -> Int {
        guard let milliseconds else { return 0 }
        return Int((Double(milliseconds) / 60000.0).rounded())
    }

    /// Legacy `calculateBackgroundColor`: appends alpha hex derived from opacity.
    public static func backgroundColor(color: String, transparentMode: Bool, opacity: Double) -> String {
        var multiplier = 1.0
        if transparentMode {
            multiplier = opacity.isFinite ? opacity : 0.9
        }
        let alpha = Int((multiplier * 255).rounded())
        return color + String(format: "%02X", max(0, min(255, alpha)))
    }

    /// The opacity preference is stored as a fraction (default 0.9) and shown as a
    /// percent. It used to be bound through the millis accessor and the integer
    /// store, so the default 0.9 displayed as 0 % and every intermediate value
    /// collapsed to 0 or 1; these conversions keep the value a Double end to end.
    public static func opacityPercent(fromStored opacity: Double) -> Double {
        opacity.isFinite ? opacity * 100 : 90
    }

    public static func storedOpacity(fromPercent percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        return max(0, min(100, percent)) / 100
    }

    /// The theme colour with any trailing alpha pair removed ("#RRGGBBAA" ->
    /// "#RRGGBB"), for ink that must stay fully opaque, independent of
    /// `transparentMode`/`opacity`. Anything that is not an 8-digit hex colour
    /// is returned unchanged.
    public static func opaqueColor(_ color: String) -> String {
        let hexDigits: Set<Character> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
                                         "a", "b", "c", "d", "e", "f",
                                         "A", "B", "C", "D", "E", "F"]
        let index = color.hasPrefix("#") ? color.index(after: color.startIndex) : color.startIndex
        let digits = color[index...]
        guard digits.count == 8, digits.allSatisfy({ hexDigits.contains($0) }) else { return color }
        return String(color.prefix(color.hasPrefix("#") ? 7 : 6))
    }

    /// The readable foreground colour for a break background.
    ///
    /// Legacy uses white text for every theme and switches to black text for the
    /// "Snow white" theme (`body.ffffff` in app/css/break.css). The native port
    /// derives the foreground from the luminance of the actual background, so that
    /// every built-in theme — and every custom colour — stays legible, independent
    /// of the light/dark appearance of the application.
    public static func foregroundColor(forBackground color: String) -> String {
        guard let rgb = rgbComponents(of: color) else { return "#FFFFFF" }
        let luminance = (0.299 * rgb.red + 0.587 * rgb.green + 0.114 * rgb.blue) / 255.0
        return luminance >= 0.55 ? "#000000" : "#FFFFFF"
    }

    /// Parses `#rgb`, `#rrggbb` (with or without an alpha suffix) into components.
    public static func rgbComponents(of color: String) -> (red: Double, green: Double, blue: Double)? {
        var hex = color.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        // Drop a trailing alpha pair ("RRGGBBAA" / "RRGGBB" + alpha).
        if hex.count == 8 { hex = String(hex.prefix(6)) }
        guard hex.count == 3 || hex.count == 6 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value) else { return nil }
        if hex.count == 3 {
            let red = Double((value >> 8) & 0xF) * 17
            let green = Double((value >> 4) & 0xF) * 17
            let blue = Double(value & 0xF) * 17
            return (red, green, blue)
        }
        let red = Double((value >> 16) & 0xFF)
        let green = Double((value >> 8) & 0xFF)
        let blue = Double(value & 0xFF)
        return (red, green, blue)
    }

    /// Semantic version comparison for GitHub `tag_name` values ("v1.23.0").
    /// Returns true when `candidate` is strictly newer than `current`.
    public static func isNewerVersion(candidate: String, current: String) -> Bool {
        let candidateParts = parseSemver(candidate)
        let currentParts = parseSemver(current)
        for index in 0..<3 {
            let c = candidateParts[index]
            let cur = currentParts[index]
            if c != cur { return c > cur }
        }
        return false
    }

    static func parseSemver(_ input: String) -> [Int] {
        var cleaned = input.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("v") { cleaned.removeFirst() }
        // Drop any prerelease suffix.
        if let dash = cleaned.firstIndex(of: "-") {
            cleaned = String(cleaned[..<dash])
        }
        let parts = cleaned.split(separator: ".").map { Int($0) ?? 0 }
        var result = [0, 0, 0]
        for index in 0..<min(3, parts.count) {
            result[index] = max(0, parts[index])
        }
        return result
    }

    /// Color deltas used by the break health indicator.
    public static func dangerColor(forTheme themeColor: String?) -> (r: Int, g: Int, b: Int, opacityMultiplier: Double) {
        let known: [String: (Int, Int, Int, Double)] = [
            "#478484": (255, 36, 36, 1.5),
            "#633738": (255, 50, 80, 1.5),
            "#ffffff": (200, 30, 30, 2.0),
            "#1d1f21": (255, 70, 70, 1.0),
            "#a49898": (255, 36, 36, 1.5),
            "#567890": (255, 36, 36, 1.4)
        ]
        guard let themeColor, let found = known[themeColor.lowercased()] else {
            return (255, 36, 36, 1.0)
        }
        return found
    }

    /// Glow parameters from `applyBreakHealthEffect`; nil when no effect applies.
    public static func breakHealthEffect(danger: Int, breakHealthMode: Bool, themeColor: String?)
    -> (red: Int, green: Int, blue: Int, opacity: Double, blur: Int, spread: Int)? {
        guard breakHealthMode, danger > 2 else { return nil }
        let strength = Double(min(danger - 2, 8)) / 8.0
        let color = dangerColor(forTheme: themeColor)
        let opacity = ((0.1 + strength * 0.15) * color.opacityMultiplier)
        let blur = Int((80 + strength * 40).rounded())
        let spread = Int((12 + strength * 18).rounded())
        return (color.r, color.g, color.b, opacity, blur, spread)
    }
}

/// Color deltas for break events. Kept in the core so the
/// accounting rules are testable without the AppKit layer.
public enum HealthPolicy {
    /// A finished Mini break lowers the danger by 1, a finished Long break by 2.
    public static func completed(mini: Bool) -> Int { mini ? -1 : -2 }

    /// A skipped break raises the danger by 1 (Mini) or 2 (Long).
    public static func skipped(mini: Bool) -> Int { mini ? 1 : 2 }

    /// Pausing while a break runs raises the danger like a skip.
    public static func paused(mini: Bool) -> Int { mini ? 1 : 2 }

    /// Postponing raises the danger by 1 — for Mini *and* Long breaks
    /// (legacy `postponeMicrobreak` and `postponeBreak` both use 1).
    public static func postponed() -> Int { 1 }
}

/// Port of the danger accounting from legacy main.js (`increaseDanger`/`decreaseDanger`).
public final class HealthTracker {    public private(set) var danger = 0
    public private(set) var modeEnabled: Bool

    public init(modeEnabled: Bool) {
        self.modeEnabled = modeEnabled
    }

    public func setMode(enabled: Bool) {
        modeEnabled = enabled
        if !enabled {
            danger = 0
            Log.info("Caesura: danger reset after disabling breakHealthMode")
        }
    }

    public func increase(_ amount: Int) {
        guard modeEnabled else { return }
        danger = min(danger + amount, 10)
        Log.info("Caesura: danger increased to \(danger)")
    }

    public func decrease(_ amount: Int) {
        guard modeEnabled else { return }
        danger = max(danger - amount, 0)
        Log.info("Caesura: danger decreased to \(danger)")
    }

    public func reset() {
        danger = 0
    }
}
