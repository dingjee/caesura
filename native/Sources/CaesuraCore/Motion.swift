import Foundation

/// The shared tween tokens of the app: one place for every animation
/// duration, so no transition carries a scattered literal of its own.
///
/// The durations are calm: a break window arrives in about 900 ms and leaves
/// in about 700 ms, the brightness handover between poem lines and the glide
/// back to the newest words take about 300 ms each, and small feedback (a
/// toast) answers in about 250–300 ms. Poem reveal timing and the scheduler
/// are deliberately NOT expressed here: their pace is part of the poem and
/// stays where it already lives (`PoemTimeline`, `PoemFocus`).
public enum TransitionTokens {
    /// How long the radial reveal of a break window takes to open.
    public static let breakEntryMillis: Int64 = 900
    /// How long the radial reveal of a break window takes to close.
    public static let breakExitMillis: Int64 = 700
    /// How long the brightness handover between poem lines takes.
    public static let emphasisHandoverMillis: Int64 = 300
    /// How long the glide back to the newest words of the poem takes.
    /// How long small feedback (a toast) takes to appear.
    public static let smallFeedbackMillis: Int64 = 250
    /// How long a hover takes to ease the poem back in after it had faded.
    public static let poemHoverEntryMillis: Int64 = 250
    /// How long small feedback (a toast) takes to disappear.
    public static let smallFeedbackDismissMillis: Int64 = 300
}

/// The one gentle cubic family every transition of the app uses.
///
/// `entering` eases out (a soft landing — the reveal decelerates into its
/// final shape), `exiting` eases in (a prompt start that settles gently into
/// the origin), `standard` is the symmetric in-out used for movement
/// inside a window, and `ripple` is the dedicated in-out of the break's
/// radial wave: zero velocity at both ends, so the wave neither bursts out
/// of its origin nor pops its last pixels — it rises, sweeps and settles.
/// All of them are ordinary cubic Béziers through (0,0) and (1,1), evaluated
/// exactly in Foundation so the same curve drives Core Animation, SwiftUI
/// and the core geometry tests.
public enum TransitionCurve {
    case entering
    case exiting
    case standard
    case ripple

    /// The control points (x1, y1, x2, y2) of the cubic Bézier through
    /// (0,0) and (1,1).
    public var controlPoints: (x1: Double, y1: Double, x2: Double, y2: Double) {
        switch self {
        case .entering:
            return (0.25, 0.46, 0.45, 0.94)
        case .exiting:
            return (0.55, 0.06, 0.68, 0.19)
        case .standard:
            return (0.42, 0.0, 0.58, 1.0)
        case .ripple:
            return (0.37, 0.0, 0.63, 1.0)
        }
    }

    /// The normalized output progress [0,1] for the normalized input
    /// progress `t`. Values outside [0,1] clamp, so callers may pass raw
    /// elapsed fractions. The endpoints are exact: 0 in, 1 out.
    public func value(at t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        let p = controlPoints
        let solved = solveT(forX: t, p1: p.x1, p2: p.x2)
        let y = cubicY(p.y1, p.y2, at: solved)
        return min(max(y, 0), 1)
    }

    /// The x coordinate of the cubic Bézier at parameter t.
    private func cubicX(_ p1: Double, _ p2: Double, at t: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }

    /// The y coordinate of the cubic Bézier at parameter t.
    private func cubicY(_ p1: Double, _ p2: Double, at t: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }

    /// The parameter t whose x(t) equals `x`, found by bisection: the x
    /// curve of a cubic Bézier with control x values in [0,1] is monotonic,
    /// so bisection converges quickly and needs no calculus.
    private func solveT(forX x: Double, p1: Double, p2: Double) -> Double {
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if cubicX(p1, p2, at: mid) < x {
                lo = mid
            } else {
                hi = mid
            }
        }
        return (lo + hi) / 2
    }
}
