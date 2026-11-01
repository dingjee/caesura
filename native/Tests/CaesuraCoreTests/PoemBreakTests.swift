import Foundation
import CaesuraCore

enum PoemBreakTests {
    static func registerAll() {
        TestRunner.register("poem break: the session captures the whole poem", sessionCapturesThePoem)
        TestRunner.register("poem break: the CLI names only the parts of the break", breakPartsResolve)
        TestRunner.register("poem break: the standard envelopes are three and five seconds", timelineStandard)
        TestRunner.register("poem break: the poem fades in, holds and fades out", timelineOpacity)
        TestRunner.register("poem break: a short break scales the whole envelope", timelineScaled)
        TestRunner.register("poem break: an illegal break duration shows nothing", timelineIllegalDuration)
        TestRunner.register("poem break: reduced motion appears and disappears at once", timelineReduceMotion)
        TestRunner.register("poem break: the poem is gone when the break ends", timelineFollowsTheBreak)
        TestRunner.register("poem break: the kind and the mode of a session are two things", kindAndMode)
    }

    // MARK: Helpers

    static func makePoem(id: String = "p1", lines: [String]) -> Poem {
        Poem(id: id, title: "Test Poem", author: "Test Author", lines: lines,
             excerpt: Array(lines.prefix(2)), seasons: [], months: [],
             authorBorn: nil, authorDied: nil, source: "test")
    }

    /// The poem of the session cases: eleven words on two lines.
    static let twoLines = ["Hope is the thing with feathers", "That perches in the soul"]

    static func session(_ poem: Poem, mini: Bool) -> PoemBreakSession {
        PoemBreakSession.revealing(poem: poem, mini: mini, startedAt: 1_000,
                                   durationMillis: mini ? 3_000 : 5_000,
                                   revealedBefore: 0)
    }

    // MARK: Session

    /// The break shows the whole poem: the session carries every line of it.
    static func sessionCapturesThePoem() throws {
        let poem = makePoem(lines: twoLines)
        let mini = session(poem, mini: true)
        try expectEqual(mini.lines, twoLines, "the session carries the whole poem")
        try expectEqual(mini.poemId, "p1")
        try expectEqual(mini.title, "Test Poem")
        try expectEqual(mini.author, "Test Author")
        try expectEqual(mini.startedAt, 1_000)
        try expectEqual(mini.durationMillis, 3_000)
        try expectTrue(mini.mini)
        try expectEqual(mini.totalWords, 11, "the eleven words of the poem are counted")

        let long = session(poem, mini: false)
        try expectEqual(long.lines, twoLines, "the session carries the whole poem")
        try expectFalse(long.mini)
        try expectEqual(long.durationMillis, 5_000)

        // A poem without lines shows nothing, but it is still a valid session.
        let empty = session(makePoem(lines: []), mini: true)
        try expectEqual(empty.lines.count, 0)
        try expectEqual(empty.totalWords, 0)
    }

    /// The kind of a session says what it counts, the mode says what the window
    /// draws. The break that completes the poem shows the whole poem as well,
    /// but it is not a repetition.
    static func kindAndMode() throws {
        let poem = makePoem(lines: ["one two three"])
        let advancing = PoemBreakSession.revealing(poem: poem, mini: true, startedAt: 0,
                                                    durationMillis: 3_000, revealedBefore: 0)
        try expectEqual(advancing.kind, .advancing)
        try expectEqual(advancing.mode, .revealing)

        let unlocking = PoemBreakSession.revealing(poem: poem, mini: false, startedAt: 0,
                                                    durationMillis: 5_000, revealedBefore: 0)
        try expectEqual(unlocking.kind, .unlocking, "the break that completes the poem unlocks it")
        try expectEqual(unlocking.mode, .full, "the complete poem is shown in full")

        let repeating = PoemBreakSession.complete(poem: poem, mini: true, startedAt: 0,
                                                   durationMillis: 3_000)
        try expectEqual(repeating.kind, .repeating)
        try expectEqual(repeating.mode, .full)
        try expectEqual(repeating.revealedBefore, repeating.revealedAfter,
                        "a repetition reveals nothing new")
        try expectEqual(repeating.totalWords, 3)
    }

    /// The CLI names the parts of a break it wants to change; the parts it does
    /// not name stay as they are.
    static func breakPartsResolve() throws {
        let defaults = (title: "The poem", text: "The verses of the poem")
        let both = PoemBreakParts.resolve(title: "Focus", text: "Look away",
                                          defaultTitle: defaults.title, defaultText: defaults.text)
        try expectEqual(both.title, "Focus")
        try expectEqual(both.text, "Look away")

        let onlyTitle = PoemBreakParts.resolve(title: "Focus", text: nil,
                                               defaultTitle: defaults.title, defaultText: defaults.text)
        try expectEqual(onlyTitle.title, "Focus")
        try expectEqual(onlyTitle.text, defaults.text, "the body stays the default one")

        let onlyText = PoemBreakParts.resolve(title: nil, text: "Look away",
                                              defaultTitle: defaults.title, defaultText: defaults.text)
        try expectEqual(onlyText.title, defaults.title, "the title stays the default one")
        try expectEqual(onlyText.text, "Look away")

        let none = PoemBreakParts.resolve(title: nil, text: nil,
                                          defaultTitle: defaults.title, defaultText: defaults.text)
        try expectEqual(none.title, defaults.title)
        try expectEqual(none.text, defaults.text)

        try expectFalse(PoemBreakParts.hasCustomPart(title: nil, text: nil))
        try expectFalse(PoemBreakParts.hasCustomPart(title: "", text: "   "))
        try expectTrue(PoemBreakParts.hasCustomPart(title: "Focus", text: nil))
        try expectTrue(PoemBreakParts.hasCustomPart(title: nil, text: "Look away"))
    }

    // MARK: Timeline

    static func timelineStandard() throws {
        let mini = PoemTimeline.standard(mini: true)
        try expectEqual(mini.fadeInMillis, 500)
        try expectEqual(mini.holdMillis, 1500)
        try expectEqual(mini.fadeOutMillis, 1000)
        try expectEqual(mini.totalMillis, 3000)
        let long = PoemTimeline.standard(mini: false)
        try expectEqual(long.fadeInMillis, 500)
        try expectEqual(long.holdMillis, 3500)
        try expectEqual(long.fadeOutMillis, 1000)
        try expectEqual(long.totalMillis, 5000)
    }

    static func timelineOpacity() throws {
        let mini = PoemTimeline.standard(mini: true)
        try expectEqual(mini.opacity(at: 0), 0, "before the start nothing is visible")
        try expectEqual(mini.opacity(at: 250), 0.5, "the fade in is linear")
        try expectEqual(mini.opacity(at: 500), 1, "the fade in is over")
        try expectEqual(mini.opacity(at: 2000), 1, "the hold ends at the fade out")
        try expectEqual(mini.opacity(at: 2500), 0.5, "the fade out is linear")
        try expectEqual(mini.opacity(at: 3000), 0, "the poem is gone after the fade out")
        try expectEqual(mini.opacity(at: 9000), 0)
        try expectFalse(mini.isVisible(at: 0))
        try expectTrue(mini.isVisible(at: 500))
        try expectTrue(mini.isVisible(at: 2000))
        try expectFalse(mini.isVisible(at: 3000))
        try expectFalse(mini.isVisible(at: 3001))
    }

    static func timelineScaled() throws {
        let scaled = PoemTimeline.scaled(mini: true, toDuration: 1000)
        try expectTrue(scaled.totalMillis <= 1000, "the envelope never outlasts the break")
        try expectTrue(scaled.fadeInMillis > 0 && scaled.holdMillis > 0 && scaled.fadeOutMillis > 0,
                      "every phase keeps a part of the short break")
        let total = Double(scaled.totalMillis)
        try expectTrue(abs(Double(scaled.fadeInMillis) / total - 500.0 / 3000.0) < 0.01,
                      "the fade in keeps its ratio")
        try expectTrue(abs(Double(scaled.holdMillis) / total - 1500.0 / 3000.0) < 0.01,
                      "the hold keeps its ratio")
        try expectTrue(abs(Double(scaled.fadeOutMillis) / total - 1000.0 / 3000.0) < 0.01,
                      "the fade out keeps its ratio")

        // A long break keeps the standard envelope.
        try expectEqual(PoemTimeline.scaled(mini: false, toDuration: 60_000),
                        PoemTimeline.standard(mini: false))

        // A very short break stays inside its duration.
        let tiny = PoemTimeline.scaled(mini: true, toDuration: 120)
        try expectTrue(tiny.totalMillis > 0 && tiny.totalMillis <= 120,
                      "the envelope fits into 120 ms")
    }

    static func timelineIllegalDuration() throws {
        for duration in [0, -1, -5_000] {
            let scaled = PoemTimeline.scaled(mini: true, toDuration: Int64(duration))
            try expectEqual(scaled.totalMillis, 0, "an illegal duration shows nothing")
            try expectEqual(scaled.opacity(at: 0), 0)
            try expectEqual(scaled.opacity(at: 100), 0)
            try expectFalse(scaled.isVisible(at: 10))
        }
    }

    static func timelineReduceMotion() throws {
        let mini = PoemTimeline.standard(mini: true)
        try expectEqual(mini.opacity(at: 0, reduceMotion: true), 1, "the poem appears at once")
        try expectEqual(mini.opacity(at: 2_999, reduceMotion: true), 1)
        try expectEqual(mini.opacity(at: 3_000, reduceMotion: true), 0, "the poem disappears at once")
        try expectEqual(mini.opacity(at: -1, reduceMotion: true), 0)
    }

    /// The envelope follows the break: the poem is shown while the break lasts
    /// and is gone when it ends. The time comes from the caller, never from the
    /// wall clock.
    static func timelineFollowsTheBreak() throws {
        let clock = ManualClock(start: 1_000)
        let startedAt = clock.nowMillis
        let duration: Int64 = 3_000
        let timeline = PoemTimeline.scaled(mini: true, toDuration: duration)
        try expectEqual(timeline.opacity(at: clock.nowMillis - startedAt), 0,
                        "the poem starts with the break")
        clock.advance(500)
        try expectTrue(timeline.isVisible(at: clock.nowMillis - startedAt),
                       "the poem is visible during the break")
        clock.advance(duration - 500)
        try expectFalse(timeline.isVisible(at: clock.nowMillis - startedAt),
                        "the poem is gone when the break ends")
    }
}
