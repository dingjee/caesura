import Foundation
import CaesuraCore

enum PoemPresenceTests {
    static func registerAll() {
        TestRunner.register("poem presence: a short complete poem keeps the standard envelope", fullTimelineShortPoem)
        TestRunner.register("poem presence: the complete poem is visible for its reading time", fullTimelineReadingTime)
        TestRunner.register("poem presence: the reading window never outlasts the break", fullTimelineCappedByTheBreak)
        TestRunner.register("poem presence: an illegal break duration shows nothing", fullTimelineIllegalDuration)
        TestRunner.register("poem presence: hovering keeps the poem visible past its envelope", retentionHoverHolds)
        TestRunner.register("poem presence: hovering never outlasts the break", retentionCapsAtTheBreak)
        TestRunner.register("poem presence: leaving fades the poem out softly", retentionLeaveFade)
        TestRunner.register("poem presence: leaving early never ends the poem sooner than planned", retentionNeverEarlierThanPlanned)
        TestRunner.register("poem presence: moving back in calls the poem back", retentionReenter)
        TestRunner.register("poem presence: the hidden area calls the poem back", retentionReinvokeAfterHiding)
        TestRunner.register("poem presence: reduced motion appears and disappears at once", retentionReduceMotion)
        TestRunner.register("poem presence: a hover entry eases the poem back in", retentionEntryTween)
        TestRunner.register("poem presence: an entry continues from the alpha on screen", retentionEntryReseedsFromCurrent)
        TestRunner.register("poem presence: a leave during the entry fades from the reached alpha", retentionEntryInterruptedByLeave)
        TestRunner.register("poem presence: reduced motion and the break cap the entry", retentionEntryReduceMotionAndDeadline)
    }

    // MARK: Helpers

    /// The standard envelope of a Mini break: 500 in, 1500 hold, 1000 out.
    static let mini = PoemTimeline.standard(mini: true)
    /// A Mini break of twenty seconds.
    static let miniDuration: Int64 = 20_000

    // MARK: The envelope of the complete poem

    /// A short poem needs no more room than the standard envelope gives it.
    static func fullTimelineShortPoem() throws {
        // Eleven words read in three seconds: more than the Mini hold.
        let elevenWords = PoemTimeline.full(mini: true, toDuration: miniDuration, wordCount: 11)
        try expectEqual(elevenWords.fadeInMillis, 500)
        try expectEqual(elevenWords.fadeOutMillis, 1000)
        try expectEqual(elevenWords.holdMillis, 3000, "220 words a minute: 11 words in 3 s")
        try expectEqual(elevenWords.totalMillis, 4500)

        // A Long break holds for 3.5 s anyway: the poem does not stretch it.
        let long = PoemTimeline.full(mini: false, toDuration: miniDuration, wordCount: 11)
        try expectEqual(long.holdMillis, 3500)
    }

    /// A longer poem is visible for about its reading time.
    static func fullTimelineReadingTime() throws {
        // Sixty-six words read in eighteen seconds.
        let long = PoemTimeline.full(mini: false, toDuration: 30_000, wordCount: 66)
        try expectEqual(long.holdMillis, 18_000, "220 words a minute: 66 words in 18 s")
        try expectEqual(long.totalMillis, 19_500)

        // A poem of no words keeps the standard hold.
        let empty = PoemTimeline.full(mini: true, toDuration: miniDuration, wordCount: 0)
        try expectEqual(empty.holdMillis, 1500)
    }

    /// However long the text is, the poem is gone when the break ends.
    static func fullTimelineCappedByTheBreak() throws {
        let huge = PoemTimeline.full(mini: true, toDuration: miniDuration, wordCount: 600)
        try expectEqual(huge.totalMillis, miniDuration, "the envelope is capped by the break")
        try expectEqual(huge.holdMillis, 18_500, "the fades keep their share")

        // A break shorter than the fades keeps every phase's ratio.
        let tiny = PoemTimeline.full(mini: true, toDuration: 1_000, wordCount: 3)
        try expectTrue(tiny.totalMillis > 0 && tiny.totalMillis <= 1_000,
                       "the envelope fits into 1000 ms")
        try expectTrue(tiny.fadeInMillis > 0 && tiny.holdMillis > 0 && tiny.fadeOutMillis > 0,
                       "every phase keeps a part of the short break")
    }

    static func fullTimelineIllegalDuration() throws {
        for duration in [0, -1, -5_000] {
            let timeline = PoemTimeline.full(mini: true, toDuration: Int64(duration), wordCount: 10)
            try expectEqual(timeline.totalMillis, 0, "an illegal duration shows nothing")
        }
    }

    // MARK: Hover retention

    /// Without the cursor, the retention is the normal envelope.
    static func retentionHoverHolds() throws {
        // Past the end of the normal envelope (3 s) the poem is gone.
        try expectEqual(mini.opacity(at: 3_500), 0)
        // The cursor on the poem keeps it visible.
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 3_500,
                                              breakDurationMillis: miniDuration,
                                              hovering: true, millisSinceLeft: nil,
                                              reduceMotion: false), 1)
        // Also inside the normal envelope the cursor keeps it at full strength.
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 2_000,
                                              breakDurationMillis: miniDuration,
                                              hovering: true, millisSinceLeft: nil,
                                              reduceMotion: false), 1)
        // Without the cursor the retention is the envelope itself.
        for elapsed: Int64 in [0, 250, 1_000, 2_750, 3_100] {
            try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: elapsed,
                                                  breakDurationMillis: miniDuration,
                                                  hovering: false, millisSinceLeft: nil,
                                                  reduceMotion: false),
                            mini.opacity(at: elapsed),
                            "no hover, no change at \(elapsed)")
        }
    }

    /// The break caps the retention: at its captured duration the poem is
    /// gone, hovered or not.
    static func retentionCapsAtTheBreak() throws {
        let last = miniDuration - 1
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: last,
                                              breakDurationMillis: miniDuration,
                                              hovering: true, millisSinceLeft: nil,
                                              reduceMotion: false), 1)
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: miniDuration,
                                              breakDurationMillis: miniDuration,
                                              hovering: true, millisSinceLeft: nil,
                                              reduceMotion: false), 0,
                        "the break hides the poem")
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: miniDuration + 5_000,
                                              breakDurationMillis: miniDuration,
                                              hovering: true, millisSinceLeft: nil,
                                              reduceMotion: false), 0)
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 1_000,
                                              breakDurationMillis: 0,
                                              hovering: true, millisSinceLeft: nil,
                                              reduceMotion: false), 0,
                        "an illegal duration shows nothing")
    }

    /// After the cursor left, the poem fades out over one second.
    static func retentionLeaveFade() throws {
        // The cursor left after the poem faded out on its own (2.9 s): the
        // soft fade keeps it for another second.
        let leaveAt: Int64 = 2_900
        let justBegan = PoemRetention.opacity(timeline: mini, elapsedMillis: leaveAt + 1,
                                              breakDurationMillis: miniDuration,
                                              hovering: false, millisSinceLeft: 1,
                                              reduceMotion: false)
        try expectTrue(justBegan > 0.99, "the fade has just begun, got \(justBegan)")
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: leaveAt + 500,
                                              breakDurationMillis: miniDuration,
                                              hovering: false, millisSinceLeft: 500,
                                              reduceMotion: false),
                        0.5, "halfway through the fade")
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: leaveAt + 1_000,
                                              breakDurationMillis: miniDuration,
                                              hovering: false, millisSinceLeft: 1_000,
                                              reduceMotion: false),
                        0, "the fade is over")
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: leaveAt + 5_000,
                                              breakDurationMillis: miniDuration,
                                              hovering: false, millisSinceLeft: 5_000,
                                              reduceMotion: false),
                        0)
    }

    /// A leave during the normal envelope never makes the poem disappear
    /// earlier than it would have without the cursor.
    static func retentionNeverEarlierThanPlanned() throws {
        // The cursor left after one second, in the middle of the hold. The
        // leave fade alone would hide the poem at 2 s — the planned envelope
        // holds it until its own fade-out.
        let sinceLeftAt2500: Int64 = 1_500
        let at1900 = PoemRetention.opacity(timeline: mini, elapsedMillis: 1_900,
                                           breakDurationMillis: miniDuration,
                                           hovering: false, millisSinceLeft: 900,
                                           reduceMotion: false)
        try expectEqual(at1900, 1, "the planned hold keeps the poem past the leave fade")
        // At 2500 ms the planned envelope itself is halfway through its
        // fade-out (the leave fade is long over): the poem fades as planned,
        // never earlier.
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 2_500,
                                              breakDurationMillis: miniDuration,
                                              hovering: false,
                                              millisSinceLeft: sinceLeftAt2500,
                                              reduceMotion: false),
                        mini.opacity(at: 2_500), "the planned fade-out runs on")
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 3_100,
                                              breakDurationMillis: miniDuration,
                                              hovering: false, millisSinceLeft: 2_100,
                                              reduceMotion: false),
                        0, "the poem is gone")
    }

    /// Moving the cursor back in restores the poem at once.
    static func retentionReenter() throws {
        // The cursor left after the envelope, the poem is halfway through its
        // leave fade — and the cursor comes back.
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 3_400,
                                              breakDurationMillis: miniDuration,
                                              hovering: true, millisSinceLeft: 500,
                                              reduceMotion: false), 1,
                        "the cursor is back on the poem")
    }

    /// The hidden poem's area calls the poem back while the break still runs.
    static func retentionReinvokeAfterHiding() throws {
        // The poem faded out long ago; the cursor arrives on the hidden area.
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 8_000,
                                              breakDurationMillis: miniDuration,
                                              hovering: true, millisSinceLeft: nil,
                                              reduceMotion: false), 1)
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 8_000,
                                              breakDurationMillis: miniDuration,
                                              hovering: false, millisSinceLeft: nil,
                                              reduceMotion: false), 0,
                        "without the cursor the area stays empty")
    }

    /// Reduced motion appears and disappears at once, but keeps the same
    /// visible window.
    static func retentionReduceMotion() throws {
        // Inside the normal window the poem is visible at once.
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 1_000,
                                              breakDurationMillis: miniDuration,
                                              hovering: false, millisSinceLeft: nil,
                                              reduceMotion: true), 1)
        // After the cursor left, the poem disappears at once — but only when
        // the normal window is over.
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 2_000,
                                              breakDurationMillis: miniDuration,
                                              hovering: false, millisSinceLeft: 500,
                                              reduceMotion: true), 1,
                        "the normal window keeps the poem")
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 3_400,
                                              breakDurationMillis: miniDuration,
                                              hovering: false, millisSinceLeft: 400,
                                              reduceMotion: true), 0,
                        "no soft fade for reduced motion")
        // The cursor on the poem keeps it visible.
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 4_000,
                                              breakDurationMillis: miniDuration,
                                              hovering: true, millisSinceLeft: nil,
                                              reduceMotion: true), 1)
    }

    /// A hover that calls a hidden or partly faded poem back eases it in
    /// over the shared token instead of snapping it to full strength.
    static func retentionEntryTween() throws {
        let seed = 0.5
        let atStart = PoemRetention.opacity(timeline: mini, elapsedMillis: 8_000,
                                            breakDurationMillis: miniDuration,
                                            hovering: true, millisSinceLeft: nil,
                                            reduceMotion: false,
                                            entry: PoemRetention.Entry(seedAlpha: seed, millisSinceBegan: 0))
        try expectEqual(atStart, seed, "the entry starts at the alpha on screen")
        let midway = PoemRetention.opacity(timeline: mini, elapsedMillis: 8_000,
                                           breakDurationMillis: miniDuration,
                                           hovering: true, millisSinceLeft: nil,
                                           reduceMotion: false,
                                           entry: PoemRetention.Entry(seedAlpha: seed,
                                                        millisSinceBegan: PoemRetention.entryFadeMillis / 2))
        try expectTrue(midway > seed && midway < 1,
                       "halfway through the entry it is between seed and full, got \(midway)")
        let done = PoemRetention.opacity(timeline: mini, elapsedMillis: 8_000,
                                         breakDurationMillis: miniDuration,
                                         hovering: true, millisSinceLeft: nil,
                                         reduceMotion: false,
                                         entry: PoemRetention.Entry(seedAlpha: seed,
                                                      millisSinceBegan: PoemRetention.entryFadeMillis))
        try expectEqual(done, 1, "the entry ends at full strength")
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 8_000,
                                              breakDurationMillis: miniDuration,
                                              hovering: true, millisSinceLeft: nil,
                                              reduceMotion: false,
                                              entry: PoemRetention.Entry(seedAlpha: seed,
                                                           millisSinceBegan: PoemRetention.entryFadeMillis + 300)),
                        1, "after the entry the hover holds the poem as before")
        // From the hidden state the entry begins at zero and climbs.
        let hidden = PoemRetention.opacity(timeline: mini, elapsedMillis: 8_000,
                                           breakDurationMillis: miniDuration,
                                           hovering: true, millisSinceLeft: nil,
                                           reduceMotion: false,
                                           entry: PoemRetention.Entry(seedAlpha: 0, millisSinceBegan: 0))
        try expectEqual(hidden, 0, "an entry from hidden starts invisible")
        let hiddenMidway = PoemRetention.opacity(timeline: mini, elapsedMillis: 8_000,
                                                 breakDurationMillis: miniDuration,
                                                 hovering: true, millisSinceLeft: nil,
                                                 reduceMotion: false,
                                                 entry: PoemRetention.Entry(seedAlpha: 0,
                                                              millisSinceBegan: PoemRetention.entryFadeMillis / 2))
        try expectTrue(hiddenMidway > 0 && hiddenMidway < 1,
                       "the entry from hidden is under way, got \(hiddenMidway)")
        // The entry never moves back and never hides what the normal
        // envelope already shows.
        var previous = 0.0
        for sinceBegan in stride(from: Int64(0), through: PoemRetention.entryFadeMillis, by: 25) {
            let value = PoemRetention.opacity(timeline: mini, elapsedMillis: 8_000,
                                              breakDurationMillis: miniDuration,
                                              hovering: true, millisSinceLeft: nil,
                                              reduceMotion: false,
                                              entry: PoemRetention.Entry(seedAlpha: 0, millisSinceBegan: sinceBegan))
            try expectTrue(value >= previous, "the entry never eases back")
            previous = value
        }
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 100,
                                              breakDurationMillis: miniDuration,
                                              hovering: true, millisSinceLeft: nil,
                                              reduceMotion: false,
                                              entry: PoemRetention.Entry(seedAlpha: 0, millisSinceBegan: 0)),
                        mini.opacity(at: 100),
                        "the planned envelope stays the lower bound during an entry")
    }

    /// Moving back in continues from the alpha the poem shows at that
    /// moment — it never drops to zero and never jumps to full strength.
    static func retentionEntryReseedsFromCurrent() throws {
        // A leave fade seeded at 0.6 is halfway down when the cursor
        // returns: the entry picks the poem up exactly there.
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 3_400,
                                              breakDurationMillis: miniDuration,
                                              hovering: true, millisSinceLeft: nil,
                                              reduceMotion: false,
                                              entry: PoemRetention.Entry(seedAlpha: 0.3, millisSinceBegan: 0)),
                        0.3, "the re-entry continues where the fade stood")
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 3_400,
                                              breakDurationMillis: miniDuration,
                                              hovering: true, millisSinceLeft: nil,
                                              reduceMotion: false,
                                              entry: PoemRetention.Entry(seedAlpha: 0.3,
                                                           millisSinceBegan: PoemRetention.entryFadeMillis)),
                        1, "and it reaches full strength like any entry")
    }

    /// A leave during an entry fades from the alpha the entry had reached;
    /// it never flashes the poem to full strength first.
    static func retentionEntryInterruptedByLeave() throws {
        // The entry eased a hidden poem up to 0.6 when the cursor left.
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 8_000,
                                              breakDurationMillis: miniDuration,
                                              hovering: false, millisSinceLeft: 0,
                                              reduceMotion: false, leaveSeedAlpha: 0.6),
                        0.6, "the fade starts where the entry stood")
        try expectTrue(PoemRetention.opacity(timeline: mini, elapsedMillis: 8_000,
                                             breakDurationMillis: miniDuration,
                                             hovering: false, millisSinceLeft: 1,
                                             reduceMotion: false, leaveSeedAlpha: 0.6) < 1,
                       "no forced full-opacity flash")
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 8_000,
                                              breakDurationMillis: miniDuration,
                                              hovering: false, millisSinceLeft: 500,
                                              reduceMotion: false, leaveSeedAlpha: 0.6),
                        0.3, "halfway through the same soft fade")
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 8_000,
                                              breakDurationMillis: miniDuration,
                                              hovering: false, millisSinceLeft: 1_000,
                                              reduceMotion: false, leaveSeedAlpha: 0.6),
                        0, "the fade is over after the same second")
        // The planned envelope stays the lower bound: a leave in the hold
        // keeps the poem as long as it was planned.
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 2_000,
                                              breakDurationMillis: miniDuration,
                                              hovering: false, millisSinceLeft: 0,
                                              reduceMotion: false, leaveSeedAlpha: 0.6),
                        1, "the planned hold keeps the poem past the interrupted entry")
    }

    /// Reduced motion restores at once, and the break hides the poem at its
    /// deadline no matter what the entry is doing.
    static func retentionEntryReduceMotionAndDeadline() throws {
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: 8_000,
                                              breakDurationMillis: miniDuration,
                                              hovering: true, millisSinceLeft: nil,
                                              reduceMotion: true,
                                              entry: PoemRetention.Entry(seedAlpha: 0, millisSinceBegan: 0)),
                        1, "reduced motion restores the poem at once")
        try expectEqual(PoemRetention.opacity(timeline: mini, elapsedMillis: miniDuration,
                                              breakDurationMillis: miniDuration,
                                              hovering: true, millisSinceLeft: nil,
                                              reduceMotion: false,
                                              entry: PoemRetention.Entry(seedAlpha: 0.4,
                                                           millisSinceBegan: PoemRetention.entryFadeMillis / 2)),
                        0, "the break deadline cannot be extended by the entry")
        let last = PoemRetention.opacity(timeline: mini, elapsedMillis: miniDuration - 1,
                                         breakDurationMillis: miniDuration,
                                         hovering: true, millisSinceLeft: nil,
                                         reduceMotion: false,
                                         entry: PoemRetention.Entry(seedAlpha: 0,
                                                      millisSinceBegan: PoemRetention.entryFadeMillis / 2))
        try expectTrue(last > 0 && last < 1, "until the deadline the entry is under way, got \(last)")
    }
}
