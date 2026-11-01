import Foundation
import CaesuraCore

enum UtilsTests {
    static func registerAll() {
        TestRunner.register("utils: minutesRemaining", minutesRemaining)
        TestRunner.register("utils: background color with transparency", backgroundColor)
        TestRunner.register("utils: opaque ink color strips alpha", opaqueColor)
        TestRunner.register("utils: opacity percent conversion", opacityPercent)
        TestRunner.register("utils: opacity binding round trip through the store", opacityStoreRoundTrip)
        TestRunner.register("utils: semver comparison", semver)
        TestRunner.register("utils: keyboard shortcut formatting", shortcut)
        TestRunner.register("utils: break health effect values", healthEffect)
        TestRunner.register("utils: the poem is grouped into paragraphs by its punctuation", paragraphs)
        TestRunner.register("utils: the golden ratio", goldenRatio)
        TestRunner.register("health: danger accounting gated by mode", danger)
    }

    /// The golden ratio: the step of the type scale and of the transparency of
    /// the background modes.
    static func goldenRatio() throws {
        let phi = Utils.goldenRatio
        // φ² = φ + 1
        try expectTrue(abs((phi * phi - phi - 1)) < 1e-9, "the golden ratio has to solve x² = x + 1")
        // The transparency of the three background modes: 1, 1/φ, 1/φ² — every
        // step is a factor of φ.
        let solid = 1.0
        let translucent = 1 / phi
        let frosted = 1 / (phi * phi)
        try expectTrue(abs(solid / translucent - phi) < 1e-9, "solid → translucent is a step of φ")
        try expectTrue(abs(translucent / frosted - phi) < 1e-9, "translucent → frosted is a step of φ")
        try expectTrue(frosted < translucent && translucent < solid)
    }

    /// The lines of the poem are kept, and a line that ends a sentence closes
    /// its paragraph.
    static func paragraphs() throws {
        let stanza: [IdeaNode] = [
            .text("The browns, the olives, and the yellows died,", bold: false, italic: false),
            .lineBreak,
            .text("And were swept up to heaven; where they glowed", bold: false, italic: false),
            .lineBreak,
            .text("Each dawn and set of sun till Christmastide,", bold: false, italic: false),
            .lineBreak,
            .text("And when the land lay pale for them, pale-snowed.", bold: false, italic: false)
        ]
        // The stanza has no sentence end until its last line: it stays one
        // paragraph with its line breaks.
        let paragraphs = IdeaParagraphs.paragraphs(from: stanza)
        try expectEqual(paragraphs.count, 1)
        try expectTrue(paragraphs[0].contains(.text("The browns, the olives, and the yellows died,",
                                                  bold: false, italic: false)))
        try expectTrue(paragraphs[0].contains(.lineBreak))
        try expectTrue(paragraphs[0].contains(.text("And when the land lay pale for them, pale-snowed.",
                                                  bold: false, italic: false)))
        // A sentence that ends in the middle closes its paragraph: the lines
        // after it are the next paragraph.
        let twoSentences: [IdeaNode] = [
            .text("The first sentence ends here.", bold: false, italic: false),
            .lineBreak,
            .text("The second one follows.", bold: false, italic: false)
        ]
        let split = IdeaParagraphs.paragraphs(from: twoSentences)
        try expectEqual(split.count, 2)
        try expectFalse(split[0].contains(.lineBreak))
        try expectTrue(split[1].contains(.text("The second one follows.", bold: false, italic: false)))
        // A trailing line break does not leave an empty paragraph behind.
        let trailing = IdeaParagraphs.paragraphs(from: [.text("One line.", bold: false, italic: false), .lineBreak])
        try expectEqual(trailing.count, 1)
        // The Chinese full stop ends a sentence as well.
        try expectTrue(IdeaParagraphs.endsSentence([.text("一句诗。", bold: false, italic: false)]))
        try expectFalse(IdeaParagraphs.endsSentence([.text("一句诗，", bold: false, italic: false)]))
    }

    static func minutesRemaining() throws {
        try expectEqual(Utils.minutesRemaining(90000), 2)
        try expectEqual(Utils.minutesRemaining(29 * 60000 + 40000), 30)
        try expectEqual(Utils.minutesRemaining(nil), 0)
    }

    static func backgroundColor() throws {
        try expectEqual(Utils.backgroundColor(color: "#478484", transparentMode: false, opacity: 0.9), "#478484FF")
        try expectEqual(Utils.backgroundColor(color: "#478484", transparentMode: true, opacity: 0.9), "#478484E6")
        // Legacy concatenates the stored color verbatim (no case normalization).
        try expectEqual(Utils.backgroundColor(color: "#ffffff", transparentMode: true, opacity: 0.5), "#ffffff80")
    }

    static func opaqueColor() throws {
        try expectEqual(Utils.opaqueColor("#1D1F21E6"), "#1D1F21")
        try expectEqual(Utils.opaqueColor("#1D1F21"), "#1D1F21")
        try expectEqual(Utils.opaqueColor("#1D1F2100"), "#1D1F21")
        try expectEqual(Utils.opaqueColor("478484E6"), "478484")
        try expectEqual(Utils.opaqueColor("not-a-colour"), "not-a-colour")
        try expectEqual(Utils.opaqueColor("1234567z"), "1234567z")
    }

    /// Regression: the default 0.9 is 90 % (the old millis/integer binding showed
    /// 0 %) and intermediate values survive as fractions, not 0/1.
    static func opacityPercent() throws {
        try expectEqual(Utils.opacityPercent(fromStored: 0.9), 90)
        try expectEqual(Utils.opacityPercent(fromStored: 0), 0)
        try expectEqual(Utils.opacityPercent(fromStored: 1), 100)
        try expectEqual(Utils.opacityPercent(fromStored: 0.42).rounded(toPlaces: 6), 42)
        try expectEqual(Utils.opacityPercent(fromStored: .nan), 90) // defensive default
        try expectEqual(Utils.storedOpacity(fromPercent: 42).rounded(toPlaces: 6), 0.42)
        try expectEqual(Utils.storedOpacity(fromPercent: 0), 0)
        try expectEqual(Utils.storedOpacity(fromPercent: 100), 1)
        try expectEqual(Utils.storedOpacity(fromPercent: -5), 0) // slider clamp, display only
        try expectEqual(Utils.storedOpacity(fromPercent: 150), 1)
        try expectEqual(Utils.storedOpacity(fromPercent: .nan), 0)
        // Round trip keeps every middle value.
        for fraction in [0.0, 0.1, 0.5, 0.9, 1.0] {
            let roundTripped = Utils.storedOpacity(fromPercent: Utils.opacityPercent(fromStored: fraction))
            try expectTrue(abs(roundTripped - fraction) < 1e-9)
        }
    }

    /// The binding semantics end to end: get (stored fraction → percent) and
    /// set (percent → stored .double) over a real SettingsStore, with the default
    /// value read back unchanged.
    static func opacityStoreRoundTrip() throws {
        let url = URL(fileURLWithPath: "/nonexistent/caesura-opacity-test/config.json")
        let store = SettingsStore(url: url, loadNow: false)
        // Default profile: 0.9 → 90 %.
        try expectEqual(Utils.opacityPercent(fromStored: store.getDouble("opacity")), 90)
        // 42 % is stored as the fraction 0.42 (the old path persisted the integer 1).
        store.set("opacity", .double(Utils.storedOpacity(fromPercent: 42)))
        try expectEqual(store.get("opacity"), SettingsValue.double(0.42))
        try expectEqual(Utils.opacityPercent(fromStored: store.getDouble("opacity")).rounded(toPlaces: 6), 42)
        // Boundaries survive.
        for (percent, fraction) in [(0.0, 0.0), (50.0, 0.5), (100.0, 1.0)] {
            store.set("opacity", .double(Utils.storedOpacity(fromPercent: percent)))
            try expectEqual(store.getDouble("opacity"), fraction)
        }
    }

    static func semver() throws {
        try expectTrue(Utils.isNewerVersion(candidate: "v1.23.0", current: "1.22.1"))
        try expectFalse(Utils.isNewerVersion(candidate: "v1.22.1", current: "1.22.1"))
        try expectFalse(Utils.isNewerVersion(candidate: "v1.22.0", current: "1.22.1"))
        try expectTrue(Utils.isNewerVersion(candidate: "v2.0.0", current: "1.99.99"))
        try expectTrue(Utils.isNewerVersion(candidate: "v1.22.2", current: "v1.22.1"))
    }

    static func shortcut() throws {
        try expectEqual(Utils.formatKeyboardShortcut("CmdOrCtrl+X"), "Cmd/Ctrl + X")
    }

    static func healthEffect() throws {
        try expectNil(Utils.breakHealthEffect(danger: 2, breakHealthMode: true, themeColor: "#478484"))
        // danger 3 -> strength 0.125: opacity (0.1 + 0.01875)*1.5 = 0.178, blur 85, spread 14
        let effect = Utils.breakHealthEffect(danger: 3, breakHealthMode: true, themeColor: "#478484")
        try expectNotNil(effect)
        try expectEqual(effect?.blur, 85)
        try expectEqual(effect?.spread, 14)
        try expectNil(Utils.breakHealthEffect(danger: 10, breakHealthMode: false, themeColor: "#478484"))
        // danger 10 -> strength 1.0; #ffffff opacityMultiplier 2.0 -> opacity 0.5, blur 120, spread 30
        let strong = Utils.breakHealthEffect(danger: 10, breakHealthMode: true, themeColor: "#FFFFFF")
        try expectEqual(strong?.opacity ?? 0, 0.5)
        try expectEqual(strong?.blur ?? 0, 120)
        try expectEqual(strong?.spread ?? 0, 30)
    }

    static func danger() throws {
        let tracker = HealthTracker(modeEnabled: false)
        tracker.increase(2)
        try expectEqual(tracker.danger, 0) // gated off
        tracker.setMode(enabled: true)
        tracker.increase(2)
        tracker.increase(2)
        try expectEqual(tracker.danger, 4)
        tracker.decrease(1)
        try expectEqual(tracker.danger, 3)
        tracker.increase(100)
        try expectEqual(tracker.danger, 10) // capped at 10
        tracker.decrease(100)
        try expectEqual(tracker.danger, 0)
        tracker.setMode(enabled: false)
        try expectEqual(tracker.danger, 0)
        tracker.reset()
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
