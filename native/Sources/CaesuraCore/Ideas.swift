import Foundation

/// A long break idea (title + text), the element type of the long idea deck.
public struct BreakIdea: Equatable {
    public var title: String
    public var text: String
    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }
}

/// Deck shuffle that guarantees no immediate repeats
/// (each element is drawn once before the deck is rebuilt).
public final class Shuffled<T> {
    private let array: [T]
    private var temp: [T]

    public init(_ array: [T]) {
        self.array = array
        self.temp = array
    }

    public var randomElement: T? {
        guard !array.isEmpty else { return nil }
        if temp.isEmpty {
            temp = array
        }
        let index = Int.random(in: 0..<temp.count)
        return temp.remove(at: index)
    }
}

/// Loads enabled custom break content and optional localized content.
public enum IdeasLoader {
    public static func ideas(from data: [SettingsValue]) -> [SettingsValue] {
        data.filter { $0.objectValue?["enabled"]?.boolValue ?? false }
            .compactMap { $0.objectValue?["data"] }
    }

    /// Custom ideas come from settings (`breakIdeas` / `microbreakIdeas` arrays of
    /// `{ data, enabled }`), defaults from the locale files.
    public static func miniIdeas(settings: SettingsStore, localization: Localization) -> [String] {
        if settings.getBool("useIdeasFromSettings") {
            return ideas(from: settings.getArray("microbreakIdeas")).compactMap(\.stringValue)
        }
        let subtree = localization.subtree("miniBreakIdeas") ?? [:]
        return subtree.keys.sorted().compactMap { key in
            (subtree[key] as? [String: Any])?["text"] as? String
        }
    }

    public static func longIdeas(settings: SettingsStore, localization: Localization) -> [(title: String, text: String)] {
        if settings.getBool("useIdeasFromSettings") {
            return ideas(from: settings.getArray("breakIdeas")).compactMap { value in
                guard let array = value.arrayValue else { return nil }
                let title = array.first?.stringValue ?? ""
                let text = array.count > 1 ? (array[1].stringValue ?? "") : ""
                return (title, text)
            }
        }
        let subtree = localization.subtree("longBreakIdeas") ?? [:]
        return subtree.keys.sorted().compactMap { key in
            guard let entry = subtree[key] as? [String: Any],
                  let title = entry["title"] as? String,
                  let text = entry["text"] as? String else { return nil }
            return (title, text)
        }
    }
}
