import Foundation

/// The names of the controls that stop and start a playback, and the verdict
/// over every name one control carries.
///
/// The list is small and closed: only an exact name of a real button counts,
/// no substring ever matches. A control is identified by **all** of its
/// accessibility names together — the title, the description and the help
/// text — because the semantic name ("Pause (k)", "Play (k)") can end up in
/// any of the three, and a non-semantic title (a video or page title) must
/// never shadow a meaningful description. A control whose names contradict
/// each other ("Pause" and "Play" at once) states nothing and is never
/// touched: the state stays unknown, never a guess.
public enum PlaybackNames {
    /// The names of the controls that stop a playback, lower-case and without
    /// a shortcut bracket.
    public static let pauseNames: Set<String> = ["pause", "pausa", "pauza", "pausiert",
                                                 "пауза", "暂停", "暫停", "一時停止", "일시정지", "일시 정지"]
    /// The names of the controls that start a playback.
    public static let playNames: Set<String> = ["play", "lecture", "wiedergabe", "reproducir", "riproduci",
                                                "afspelen", "odtwarzaj", "воспроизвести", "播放", "再生", "재생"]

    /// Is the name one a control that stops the playback carries?
    public static func isPauseName(_ name: String) -> Bool {
        pauseNames.contains(normalizedControlName(name))
    }

    /// Is the name one a control that starts the playback carries?
    public static func isPlayName(_ name: String) -> Bool {
        playNames.contains(normalizedControlName(name))
    }

    /// Reduces the name of a control to the word that matters: trimmed and
    /// lower-case, with one supported trailing shortcut annotation removed.
    /// Web players expose "Pause (k)", "暂停 (k)" or the spoken
    /// "Play keyboard shortcut k" through Safari accessibility.
    public static func normalizedControlName(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // YouTube also exposes spoken shortcut labels through Safari AX,
        // e.g. "Play keyboard shortcut k" after a pause. Strip only the
        // exact suffix with one ASCII key, never arbitrary explanatory text.
        if let marker = text.range(of: " keyboard shortcut ", options: .backwards) {
            let key = text[marker.upperBound...]
            if key.utf8.count == 1, let byte = key.utf8.first,
               (97...122).contains(byte) || (48...57).contains(byte) {
                text = String(text[..<marker.lowerBound])
            }
        } else if text.count > 2, text.hasSuffix(")"),
           let open = text.lastIndex(of: "("),
           let close = text.lastIndex(of: ")"),
           open < close,
           text.distance(from: text.index(after: open), to: close) <= 6 {
            text = String(text[text.startIndex..<open])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// What one control states, as far as its names go.
    public enum Verdict: Equatable {
        /// A name that stops the playback is there.
        case pause
        /// A name that starts the playback is there.
        case play
    }

    /// The verdict over every name a control carries, whatever attribute it
    /// came from. `nil` when no name matches, and `nil` too when the names
    /// contradict each other — a control that says both is never pressed.
    public static func classify(_ names: [String]) -> Verdict? {
        let saysPause = names.contains(where: isPauseName)
        let saysPlay = names.contains(where: isPlayName)
        switch (saysPause, saysPlay) {
        case (true, false):
            return .pause
        case (false, true):
            return .play
        default:
            return nil
        }
    }
}
