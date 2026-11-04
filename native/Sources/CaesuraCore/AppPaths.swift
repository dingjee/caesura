import Foundation

/// Public access to the core's SPM resource bundle (locales, audio). The application
/// target cannot see `Bundle.module` of this library directly.
public enum CoreResources {
    public static func url(forResource name: String, withExtension ext: String, subdirectory: String) -> URL? {
        let candidates = [subdirectory, "Resources/\(subdirectory)"]
        for candidate in candidates {
            if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: candidate) {
                return url
            }
        }
        return nil
    }
}

/// Paths for the native app. The persistent trial lives in
/// `~/Library/Application Support/Caesura`, the ordinary native app in
/// `~/Library/Application Support/CaesuraNative`; both can be isolated (smoke
/// tests) with `CAESURA_NATIVE_DATA_DIR` or `--data-dir <path>` as the first
/// argument. The legacy Electron directory is only ever read (one-time
/// import) and never written.
public enum AppPaths {
    public static var dataDirectoryOverride: URL?

    /// True when the app runs against an isolated data directory: the `--data-dir`
    /// flag or `CAESURA_NATIVE_DATA_DIR`. An isolated run only touches its own
    /// profile, so it never changes the login item registration of the installed
    /// app and never asks for notification authorization.
    public static var isIsolatedRun: Bool {
        if dataDirectoryOverride != nil { return true }
        if let env = ProcessInfo.processInfo.environment["CAESURA_NATIVE_DATA_DIR"], !env.isEmpty {
            return true
        }
        return false
    }

    /// Test-only opt-in: an isolated run may use the main display when no secondary
    /// display is attached.
    ///
    /// This is never a silent fallback — the run has to ask for it explicitly, it is
    /// only honoured for an isolated run (a normal or trial installation is never
    /// affected) and the app logs that it covers the display of the user.
    public static var allowsMainDisplayInIsolatedRun: Bool {
        guard isIsolatedRun else { return false }
        guard let value = ProcessInfo.processInfo.environment["CAESURA_NATIVE_TEST_MAIN_DISPLAY"] else {
            return false
        }
        return ["1", "true", "yes"].contains(value.lowercased())
    }

    public static func dataDirectory() -> URL {
        if let override = dataDirectoryOverride { return override }
        if let env = ProcessInfo.processInfo.environment["CAESURA_NATIVE_DATA_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        // Not an isolated run: isIsolatedRun stays override/env only, so the trial manages its own login item and notification authorization.
        if TrialSupport.isTrial {
            return support.appendingPathComponent(TrialSupport.trialDirectoryName, isDirectory: true)
        }
        return support.appendingPathComponent(TrialSupport.ordinaryDirectoryName, isDirectory: true)
    }

    public static func configURL(dataDirectory: URL? = nil) -> URL {
        (dataDirectory ?? AppPaths.dataDirectory()).appendingPathComponent("config.json")
    }

    public static func legacyConfigURL() -> URL {
        legacyDataDirectory().appendingPathComponent("config.json")
    }

    /// The legacy Electron userData directory (read-only for the native app).
    public static func legacyDataDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return support.appendingPathComponent("Stretchly", isDirectory: true)
    }

    public static func legacyAudioDirectory() -> URL {
        legacyDataDirectory().appendingPathComponent("audio", isDirectory: true)
    }

    public static func legacyImagesDirectory() -> URL {
        legacyDataDirectory().appendingPathComponent("images", isDirectory: true)
    }

    public static func legacyStampURL() -> URL {
        legacyDataDirectory().appendingPathComponent("stamp")
    }

    public static func stampURL(dataDirectory: URL? = nil) -> URL {
        (dataDirectory ?? AppPaths.dataDirectory()).appendingPathComponent("stamp")
    }

    public static func socketURL(dataDirectory: URL? = nil) -> URL {
        (dataDirectory ?? AppPaths.dataDirectory()).appendingPathComponent("cli.sock")
    }

    public static func audioDirectory(dataDirectory: URL? = nil) -> URL {
        (dataDirectory ?? AppPaths.dataDirectory()).appendingPathComponent("audio", isDirectory: true)
    }

    public static func imagesDirectory(dataDirectory: URL? = nil) -> URL {
        (dataDirectory ?? AppPaths.dataDirectory()).appendingPathComponent("images", isDirectory: true)
    }

    public static var defaultLogURL: URL {
        dataDirectory().appendingPathComponent("caesura-native.log")
    }

    public static let version = "1.22.1"
}
