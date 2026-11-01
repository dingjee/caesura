import Foundation
import CaesuraCore

/// Behavioural regressions for the playback control names and the verdict
/// over every name one control carries. These are **synthetic** label sets:
/// no real browser AX snapshot is involved. They pin a conditional defect of
/// the previous code path — when a non-semantic accessibility title (a video
/// or page title) accompanies a recognised name ("Pause (k)", "Play (k)"),
/// the first-non-empty rule masked the state name, which broke the discovery
/// of the control, the confirmation of the pause and the check before the
/// resume at once.
enum PlaybackNamesTests {
    static func registerAll() {
        TestRunner.register("playback names: shortcut labels match exactly", shortcutLabels)
        TestRunner.register("playback names: no substring of a name ever matches", exactNamesOnly)
        TestRunner.register("playback names: a non-semantic title does not shadow the state", titleShadowing)
        TestRunner.register("playback names: every name attribute counts, help included", everyAttributeCounts)
        TestRunner.register("playback names: contradicting names state nothing", contradictionIsNeverAGuess)
        TestRunner.register("playback names: the pause and play whitelists are disjoint", whitelistsAreDisjoint)
    }

    // MARK: Exact names

    static func shortcutLabels() throws {
        // The shortcut bracket of the web players is removed before matching.
        try expectEqual(PlaybackNames.classify(["Pause (k)"]), .pause)
        try expectEqual(PlaybackNames.classify(["暂停 (k)"]), .pause)
        try expectEqual(PlaybackNames.classify(["일시정지 (k)"]), .pause)
        try expectEqual(PlaybackNames.classify(["Play (k)"]), .play)
        try expectEqual(PlaybackNames.classify(["再生 (k)"]), .play)
        try expectEqual(PlaybackNames.classify(["재생 (k)"]), .play)
        // Case and surrounding whitespace do not matter; a shortcut wider than
        // the known one is part of the name and does not match.
        try expectEqual(PlaybackNames.classify(["  PAUSE  "]), .pause)
        try expectEqual(PlaybackNames.classify(["Wiedergabe"]), .play)
        try expectNil(PlaybackNames.classify(["Pause (shift + space)"]))
    }

    static func exactNamesOnly() throws {
        // The whitelist is small and closed: a name that merely contains the
        // word states nothing, so no control is ever pressed on a guess.
        try expectNil(PlaybackNames.classify(["Autoplay"]))
        try expectNil(PlaybackNames.classify(["Replay"]))
        try expectNil(PlaybackNames.classify(["Pause video"]))
        try expectNil(PlaybackNames.classify(["Press k to play or pause"]))
        try expectNil(PlaybackNames.classify(["Sunday lofi stream"]))
    }

    // MARK: The shadowing fix

    static func titleShadowing() throws {
        // The names of one control arrive in attribute order; a non-semantic
        // title first must not hide a meaningful name behind it — neither
        // while looking for the control ("pause" means the video plays) nor
        // while confirming the flip afterwards ("play" means it is paused).
        let playing = ["Sunday lofi stream", "Pause (k)"]
        let paused = ["Sunday lofi stream", "Play (k)"]
        try expectEqual(PlaybackNames.classify(playing), .pause,
                        "the video with a page title must still be recognised as playing")
        try expectEqual(PlaybackNames.classify(paused), .play,
                        "the same control must report the pause through the same names")
        // The resume guard reads the very same names: only a clear "play" may
        // resume, a clear "pause" reports the video as playing again.
        try expectTrue(PlaybackNames.classify(paused) == .play, "a paused video may be resumed")
        try expectFalse(PlaybackNames.classify(playing) == .play, "a playing video must not be resumed again")
    }

    static func everyAttributeCounts() throws {
        // Title, description and help are read as one set of names: the
        // semantic state may live in any of the three attributes.
        try expectEqual(PlaybackNames.classify(["Tip: press k to toggle", "pause"]), .pause)
        try expectEqual(PlaybackNames.classify(["", "播放"]), .play)
        // Duplicate names from two attributes change nothing.
        try expectEqual(PlaybackNames.classify(["Pause (k)", "Pause (k)"]), .pause)
        // A control with no names at all states nothing.
        try expectNil(PlaybackNames.classify([]))
    }

    // MARK: Never a guess

    static func contradictionIsNeverAGuess() throws {
        // A control that names both directions states nothing and is never
        // pressed — the state stays unknown instead of becoming a guess.
        try expectNil(PlaybackNames.classify(["Pause", "Play"]))
        try expectNil(PlaybackNames.classify(["暂停 (k)", "Play (k)"]))
    }

    static func whitelistsAreDisjoint() throws {
        // The contradiction rule silently voids any name that lands in both
        // whitelists, so the whitelists must stay disjoint for every entry.
        for pause in PlaybackNames.pauseNames {
            try expectFalse(PlaybackNames.playNames.contains(pause),
                            "'\(pause)' must not name both directions")
            try expectTrue(PlaybackNames.isPauseName(pause), "'\(pause)' must pause")
        }
        for play in PlaybackNames.playNames {
            try expectFalse(PlaybackNames.pauseNames.contains(play),
                            "'\(play)' must not name both directions")
            try expectTrue(PlaybackNames.isPlayName(play), "'\(play)' must play")
        }
    }
}
