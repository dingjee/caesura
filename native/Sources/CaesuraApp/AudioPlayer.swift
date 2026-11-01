import AVFoundation
import AppKit
import CaesuraCore

/// Native audio playback. Break sounds use the macOS system sounds
/// (/System/Library/Sounds): every default and built-in theme value maps to one
/// fixed system sound ("Glass"), explicit custom files still play directly.
/// There is no bundled sound theme selection anymore, but the legacy audio
/// settings and custom assets are neither removed, migrated nor cleared.
/// "silence" and `silentNotifications` play nothing; a failed playback is
/// logged and safely ignored.
final class AudioPlayer {
    private var currentPlayer: AVAudioPlayer?
    private var currentSystemSound: NSSound?
    private let settings: SettingsStore

    /// The system sound used for every non-silence built-in value.
    static let systemSoundName = "Glass"

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// What a settings value plays: an explicit custom file or the fixed system
    /// sound. `nil` values ("silence", empty) play nothing.
    enum Playback {
        case file(URL)
        case systemSound(String)
    }

    /// Custom files keep resolving like before: absolute and `~/` paths directly,
    /// bare names as `<data>/audio/<name>.wav` (the custom override wins over the
    /// built-in mapping, so existing custom setups keep working).
    func resolve(_ value: String) -> Playback? {
        guard !value.isEmpty, value != "silence" else { return nil }
        if value.hasPrefix("/") || value.hasPrefix("~") {
            let expanded = (value as NSString).expandingTildeInPath
            return .file(URL(fileURLWithPath: expanded))
        }
        let filename = value.hasSuffix(".wav") ? value : "\(value).wav"
        guard IdeaSanitizer.isAllowedAudioFilename(filename) else {
            return .systemSound(Self.systemSoundName)
        }
        let custom = AppPaths.audioDirectory().appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: custom.path) {
            return .file(custom)
        }
        return .systemSound(Self.systemSoundName)
    }

    func systemSound(named name: String) -> NSSound? {
        if let sound = NSSound(named: name) { return sound }
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        return try? NSSound(contentsOf: url, byReference: true)
    }

    func play(value: String) {
        guard !settings.getBool("silentNotifications") else { return }
        guard let playback = resolve(value) else { return }
        let volume = Float(min(max(settings.getDouble("volume"), 0), 1))
        switch playback {
        case .file(let url):
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = volume
                player.play()
                currentPlayer = player
                Log.info("Caesura: playing \(url.path) (volume: \(player.volume))")
            } catch {
                Log.error("Caesura: audio playback failed for '\(value)': \(error)")
            }
        case .systemSound(let name):
            guard let sound = systemSound(named: name) else {
                Log.error("Caesura: system sound '\(name)' unavailable for '\(value)'")
                return
            }
            sound.volume = volume
            guard sound.play() else {
                Log.error("Caesura: playing the system sound '\(name)' failed for '\(value)'")
                return
            }
            currentSystemSound = sound
            Log.info("Caesura: playing the system sound \(name) for '\(value)' (volume: \(sound.volume))")
        }
    }
}
