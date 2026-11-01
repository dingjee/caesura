import Foundation
import CaesuraCore

enum IdeasTests {
    static func registerAll() {
        TestRunner.register("ideas: enabled filter", enabledFilter)
        TestRunner.register("ideas: shuffle never repeats within a deck", shuffleDeck)
        TestRunner.register("ideas: custom ideas from settings", customIdeas)
        TestRunner.register("ideas: built-in exercise tips are absent", bundledIdeas)
    }

    static func enabledFilter() throws {
        let data: [SettingsValue] = [
            .object(["data": .string("a"), "enabled": .bool(true)]),
            .object(["data": .string("b"), "enabled": .bool(false)]),
            .object(["data": .string("c"), "enabled": .bool(true)])
        ]
        let ideas = IdeasLoader.ideas(from: data)
        try expectEqual(ideas.count, 2)
        try expectTrue(ideas.contains(.string("a")))
        try expectTrue(ideas.contains(.string("c")))
    }

    static func shuffleDeck() throws {
        let deck = Shuffled<Int>((1...20).map { $0 })
        var seen = Set<Int>()
        for _ in 0..<20 {
            let value = deck.randomElement
            try expectNotNil(value)
            try expectFalse(seen.contains(value!), "no immediate repeat within one deck")
            seen.insert(value!)
        }
        // Deck exhausted -> rebuilt, all values again
        let again = deck.randomElement
        try expectNotNil(again)
    }

    static func customIdeas() throws {
        let store = SettingsStore(url: URL(fileURLWithPath: "/dev/null/unused.json"), loadNow: false)
        var values = DefaultSettings.values
        values["useIdeasFromSettings"] = .bool(true)
        values["microbreakIdeas"] = .array([
            .object(["data": .string("custom mini"), "enabled": .bool(true)]),
            .object(["data": .string("disabled"), "enabled": .bool(false)])
        ])
        values["breakIdeas"] = .array([
            .object(["data": .array([.string("Custom title"), .string("Custom text")]), "enabled": .bool(true)])
        ])
        store.applyForTesting(values)
        let localization = Localization()
        localization.setLanguage("en")
        let minis = IdeasLoader.miniIdeas(settings: store, localization: localization)
        try expectEqual(minis, ["custom mini"])
        let longs = IdeasLoader.longIdeas(settings: store, localization: localization)
        try expectEqual(longs.count, 1)
        try expectEqual(longs[0].title, "Custom title")
        try expectEqual(longs[0].text, "Custom text")
    }

    static func bundledIdeas() throws {
        let store = SettingsStore(url: URL(fileURLWithPath: "/dev/null/unused.json"), loadNow: false)
        store.applyForTesting(DefaultSettings.values)
        let localization = Localization()
        for language in ["en", "zh-CN"] {
            localization.setLanguage(language)
            try expectTrue(IdeasLoader.miniIdeas(settings: store, localization: localization).isEmpty)
            try expectTrue(IdeasLoader.longIdeas(settings: store, localization: localization).isEmpty)
        }
    }
}
