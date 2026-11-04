import Foundation

/// The poem under the cursor.
///
/// While the cursor rests on the body of the poem or on its credit, the poem
/// stays visible as one group — also past the end of its normal envelope.
/// A hover that calls a hidden or partly faded poem back does not snap it to
/// full strength: the poem eases in from the alpha it showed when the cursor
/// arrived (`Entry`). When the cursor leaves, the poem fades out softly from
/// the alpha it had reached, so a leave during that entry never flashes it to
/// full opacity; a leave during the normal envelope never makes the poem
/// disappear earlier than it would have without the cursor, because the two
/// visibilities are merged and the stronger one wins.
///
/// Hovering never outlasts the break: at the captured duration of the break
/// the poem is gone, hovered or not. Moving the cursor into the hidden poem's
/// area calls it back (while the break still runs).
///
/// All times are measured from the start of the break, exactly like
/// `PoemTimeline.opacity(at:)`.
public enum PoemRetention {
    /// The fade after the cursor has left the poem.
    public static let leaveFadeMillis: Int64 = 1_000
    /// How long the hover takes to ease the poem back in (the shared token).
    public static let entryFadeMillis: Int64 = TransitionTokens.poemHoverEntryMillis

    /// A hover entry in progress: the alpha the poem showed when the cursor
    /// arrived, and how long ago it arrived.
    public struct Entry: Equatable {
        /// The alpha the entry eases the poem up from.
        public let seedAlpha: Double
        /// The time since the cursor arrived, in milliseconds.
        public let millisSinceBegan: Int64

        public init(seedAlpha: Double, millisSinceBegan: Int64) {
            self.seedAlpha = seedAlpha
            self.millisSinceBegan = millisSinceBegan
        }
    }

    /// The visibility of the poem at that moment.
    ///
    /// `hovering` is true while the cursor sits on the body or the credit;
    /// `millisSinceLeft` measures the time since it left (nil while it never
    /// was on the poem). `entry` is present while the cursor is easing a
    /// hidden or partly faded poem back in; without it a hover is at full
    /// strength at once. `leaveSeedAlpha` is the alpha the poem had reached
    /// when the cursor left (1 keeps the plain one-second fade).
    /// Reduced motion appears and disappears at once, but keeps the same
    /// visible window as the normal envelope.
    public static func opacity(timeline: PoemTimeline, elapsedMillis: Int64,
                               breakDurationMillis: Int64, hovering: Bool,
                               millisSinceLeft: Int64?, reduceMotion: Bool,
                               entry: Entry? = nil, leaveSeedAlpha: Double = 1) -> Double {
        // The break caps everything: after its captured duration the poem is
        // gone, hovered or not.
        guard elapsedMillis >= 0, elapsedMillis < breakDurationMillis, breakDurationMillis > 0
        else { return 0 }
        let normal = timeline.opacity(at: elapsedMillis, reduceMotion: reduceMotion)
        let retention: Double
        if hovering {
            if reduceMotion {
                retention = 1
            } else if let entry = entry {
                let eased = TransitionCurve.entering.value(
                    at: Double(entry.millisSinceBegan) / Double(entryFadeMillis))
                retention = entry.seedAlpha + (1 - entry.seedAlpha) * eased
            } else {
                retention = 1
            }
        } else if !reduceMotion, let sinceLeft = millisSinceLeft, sinceLeft >= 0 {
            retention = max(0, leaveSeedAlpha * (1 - Double(sinceLeft) / Double(leaveFadeMillis)))
        } else {
            retention = 0
        }
        return max(normal, retention)
    }
}
