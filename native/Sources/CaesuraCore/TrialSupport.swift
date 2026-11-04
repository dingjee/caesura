import Foundation

/// Stable trial identity and non-destructive first-run profile imports.
/// Existing destination profiles and all migration source files are preserved.
///
/// 2026-11-03 (authorized maintenance migration): the persistent trial now
/// owns `~/Library/Application Support/Caesura` and the ordinary native app
/// owns `~/Library/Application Support/CaesuraNative`. The previous native
/// directories (`StretchlyNativeTrial`, `StretchlyNative`) are one-time import
/// sources only; the first-run import never overwrites an existing profile
/// and never deletes or modifies its source.
public enum TrialSupport {
    public static let trialBundleIdentifier = "net.hovancik.stretchly.trial"
    public static let trialDirectoryName = "Caesura"
    public static let ordinaryDirectoryName = "CaesuraNative"

    /// True when the running executable belongs to the trial app: the packaged GUI app
    /// itself, or the CLI bundled inside the trial `.app`.
    public static var isTrial: Bool {
        Bundle.main.bundleIdentifier == trialBundleIdentifier || packagedBundleIdentifier == trialBundleIdentifier
    }

    /// The bundle identifier of the `.app` containing the current executable, or nil for
    /// unpackaged binaries (`swift run`, the test runner, a standalone CLI).
    public static var packagedBundleIdentifier: String? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let appURL = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard appURL.pathExtension == "app", let bundle = Bundle(url: appURL) else { return nil }
        return bundle.bundleIdentifier
    }

    /// Imports a previous native profile into a new ordinary or trial installation.
    /// Isolated runs (`--data-dir`, `CAESURA_NATIVE_DATA_DIR`) never import, so a test
    /// launch of the trial bundle cannot pull the real profile into a test directory.
    ///
    /// The trial reads its own previous directory first (`StretchlyNativeTrial`
    /// wins over the old ordinary `StretchlyNative`); the ordinary app only
    /// ever imports the old ordinary profile, never the trial's.
    public static func importCompatibleProfileIfNeeded() {
        guard !AppPaths.isIsolatedRun else { return }
        let destination = AppPaths.dataDirectory()
        let sources = isTrial
            ? ["StretchlyNativeTrial", "StretchlyNative"]
            : ["StretchlyNative"]
        let support = destination.deletingLastPathComponent()
        for name in sources {
            if importProfile(from: support.appendingPathComponent(name), to: destination) { break }
        }
    }

    /// Copies the settings file and the custom assets from `source` into `destination`
    /// without overwriting any existing file. Returns false when the destination profile
    /// already exists or the source has no config to import.
    @discardableResult
    public static func importProfile(from source: URL, to destination: URL) -> Bool {
        let fm = FileManager.default
        let sourceConfig = source.appendingPathComponent("config.json")
        let destinationConfig = destination.appendingPathComponent("config.json")
        if fm.fileExists(atPath: destinationConfig.path) {
            Log.info("Caesura: trial profile already exists, keeping it")
            return false
        }
        guard fm.fileExists(atPath: sourceConfig.path) else {
            Log.info("Caesura: no ordinary native profile found to import into the trial")
            return false
        }
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try fm.copyItem(at: sourceConfig, to: destinationConfig)
        } catch {
            Log.warn("Caesura: could not import the ordinary native config into the trial: \(error)")
            return false
        }
        // The source config is already native-format, so no migration runs; migrations
        // apply only to legacy Electron imports.
        let assets = LegacyAssets.importAssets(legacyDirectory: source, nativeDirectory: destination)
        Log.info("Caesura: trial profile imported (audio: \(assets.copiedAudio), images: \(assets.copiedImages), stamp: \(assets.importedStamp))")
        return true
    }

}
