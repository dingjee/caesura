import Foundation

/// Applications whose system media sessions remain playing during breaks.
/// Bundle identity is the policy key; the name is only a display label.
public struct MediaAllowedApplication: Equatable, Identifiable {
    public static let settingKey = "mediaPlaybackAllowedApps"
    public let bundleIdentifier: String
    public let name: String
    public var id: String { bundleIdentifier.lowercased() }

    public init?(bundleIdentifier: String, name: String) {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard identifier.contains("."), !identifier.hasPrefix("."), !identifier.hasSuffix("."),
              !identifier.contains(".."), identifier.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        self.bundleIdentifier = identifier
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = label.isEmpty ? identifier : label
    }

    public static let defaults: [Self] = [
        Self(bundleIdentifier: "com.spotify.client", name: "Spotify")!,
        Self(bundleIdentifier: "com.alger.music.trial", name: "AlgerMusic")!,
    ]

    public var settingsValue: SettingsValue {
        .object(["bundleIdentifier": .string(bundleIdentifier), "name": .string(name)])
    }

    public static func parse(_ value: SettingsValue?) -> [Self] {
        guard let entries = value?.arrayValue else { return defaults }
        var seen: Set<String> = []
        let applications: [Self] = entries.compactMap { entry in
            guard let object = entry.objectValue,
                  let identifier = object["bundleIdentifier"]?.stringValue,
                  let application = Self(bundleIdentifier: identifier,
                    name: object["name"]?.stringValue ?? identifier),
                  seen.insert(application.id).inserted else { return nil }
            return application
        }
        // An intentional empty array clears the list; wholly malformed data
        // retains the default music exemptions instead of silently losing them.
        return applications.isEmpty && !entries.isEmpty ? defaults : applications
    }
}
