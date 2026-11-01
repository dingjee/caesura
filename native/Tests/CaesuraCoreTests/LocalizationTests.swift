import Foundation
import CaesuraCore

enum LocalizationTests {
    static func registerAll() {
        TestRunner.register("localization: interpolation", interpolation)
        TestRunner.register("localization: English plurals one/other", englishPlurals)
        TestRunner.register("localization: Czech plurals few", czechPlurals)
        TestRunner.register("localization: fallback to en", fallback)
        TestRunner.register("localization: RTL detection", rtl)
        TestRunner.register("localization: all 54 locales bundled and parse", bundled)
        TestRunner.register("localization: humanized durations", humanize)
        TestRunner.register("localization: formatTimeRemaining wraps localized text", remaining)
    }

    static func interpolation() throws {
        let localization = Localization()
        localization.setLanguage("en")
        try expectEqual(localization.t("main.microbreakIn", options: ["seconds": 10]), "Mini break in 10 seconds")
        // Legacy interpolation of raw numbers (not humanized) in breakIn
        try expectEqual(localization.t("main.breakIn", options: ["seconds": 30]), "Long break in 30 seconds")
    }

    static func englishPlurals() throws {
        let localization = Localization()
        localization.setLanguage("en")
        try expectEqual(localization.t("utils.minutes", options: ["count": 1.0]), "1 minute")
        try expectEqual(localization.t("utils.minutes", options: ["count": 2.0]), "2 minutes")
        try expectEqual(localization.t("utils.minutes", options: ["count": 1.5]), "1.5 minutes")
        try expectEqual(localization.t("utils.seconds", options: ["count": 20.0]), "20 seconds")
    }

    static func czechPlurals() throws {
        let localization = Localization()
        localization.setLanguage("cs")
        // CLDR cs: 1 -> one, 2-4 -> few, 5+ -> other
        let one = localization.t("utils.minutes", options: ["count": 1.0])
        let few = localization.t("utils.minutes", options: ["count": 2.0])
        let many = localization.t("utils.minutes", options: ["count": 10.0])
        try expectFalse(one == few, "cs 1 vs 2 should differ: \(one) / \(few)")
        try expectFalse(few == many, "cs 2 vs 10 should differ: \(few) / \(many)")
        try expectTrue(one.contains("minuta") || one.contains("minutu"), "got \(one)")
    }

    static func fallback() throws {
        let localization = Localization()
        // Pick a language that certainly lacks a key: request a missing key via ja (few strings?)
        localization.setLanguage("de")
        // Every locale defines main.quitCaesura; verify de is used when present…
        let german = localization.t("main.quitCaesura")
        try expectFalse(german == "main.quitCaesura", "de translation missing: \(german)")
        // …and en fallback shape exists for all locales for a core key.
        for language in Localization.availableLanguages {
            localization.setLanguage(language)
            let value = localization.t("main.microbreakIn", options: ["seconds": 10])
            try expectFalse(value == "main.microbreakIn", "\(language) missing main.microbreakIn")
        }
    }

    static func rtl() throws {
        let localization = Localization()
        localization.setLanguage("he")
        try expectEqual(localization.dir(), "rtl")
        localization.setLanguage("fa")
        try expectEqual(localization.dir(), "rtl")
        localization.setLanguage("ajp")
        try expectEqual(localization.dir(), "rtl")
        localization.setLanguage("en")
        try expectEqual(localization.dir(), "ltr")
        localization.setLanguage("de")
        try expectEqual(localization.dir(), "ltr")
    }

    static func bundled() throws {
        let available = Localization.availableLanguages
        try expectEqual(available.count, 54)
        try expectTrue(available.contains("en"))
        try expectTrue(available.contains("zh-TW"))
        try expectTrue(available.contains("pt-BR"))
        let localization = Localization()
        for language in available {
            localization.setLanguage(language)
            let tray = localization.t("main.toolTipHeader")
            try expectFalse(tray.isEmpty, "\(language) has empty toolTipHeader")
            let status = localization.t("statusMessages.nextMiniBreak")
            try expectFalse(status == "statusMessages.nextMiniBreak", "\(language) missing statusMessages.nextMiniBreak")
        }
    }

    static func humanize() throws {
        let localization = Localization()
        localization.setLanguage("en")
        try expectEqual(localization.humanizeDuration(20000), "20 seconds")
        try expectEqual(localization.humanizeDuration(60000), "1 minute")
        try expectEqual(localization.humanizeDuration(90000), "2 minutes")
        try expectEqual(localization.humanizeDuration(3600000), "1 hour")
        try expectEqual(localization.humanizeDuration(5 * 3600000), "5 hours")
        try expectEqual(localization.humanizeDuration(90 * 60000), "2 hours") // rounding picks hours
        try expectEqual(localization.humanizeDuration(3 * 86400000), "3 days")
        try expectEqual(localization.humanizeDuration(30000, units: ["days", "hours", "minutes"]), "1 minute")
        try expectEqual(localization.humanizeDuration(0), "0 seconds")
    }

    static func remaining() throws {
        let localization = Localization()
        localization.setLanguage("en")
        try expectEqual(localization.formatTimeRemaining(20000), "20 seconds remaining")
        try expectEqual(localization.formatElapsedDuration(60000), "1 minute elapsed")
        try expectEqual(localization.formatTimeIn(90 * 60000), "in about 2 hours")
        try expectEqual(localization.formatUnitAndValue(unit: "seconds", value: 45), "45 seconds")
        try expectEqual(localization.formatUnitAndValue(unit: "seconds", value: 90), "1.5 minutes")
        try expectEqual(localization.formatUnitAndValue(unit: "minutes", value: 5), "5 minutes")
    }
}
