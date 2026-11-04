import Foundation
import CaesuraCore

/// The shared tween tokens and the radial reveal geometry: the curve of every
/// transition and the reach of the wave that opens a break.
enum MotionTests {
    static func registerAll() {
        TestRunner.register("motion: the curve starts at zero and ends at one", curveEndpoints)
        TestRunner.register("motion: the curve clamps outside its range", curveClamping)
        TestRunner.register("motion: the curve never goes back", curveIsMonotonic)
        TestRunner.register("motion: the ripple wave rises and lands gently", rippleWaveIsGentleAtItsEnds)
        TestRunner.register("motion: the wave reaches every corner of every window", waveCoversEveryCorner)
        TestRunner.register("motion: the wave reaches a pointer outside the windows", waveCoversAnOutsidePointer)
        TestRunner.register("motion: a hidden wave shows nothing", hiddenWaveIsClear)
    }

    // MARK: The curve

    /// The endpoints are exact: a transition that starts at zero and ends at
    /// one never lands beside it.
    static func curveEndpoints() throws {
        for curve in [TransitionCurve.entering, .exiting, .standard, .ripple] {
            try expectEqual(curve.value(at: 0), 0, "the curve \(curve) must start at exactly 0")
            try expectEqual(curve.value(at: 1), 1, "the curve \(curve) must end at exactly 1")
        }
    }

    /// A raw elapsed fraction outside [0,1] is clamped, never extrapolated.
    static func curveClamping() throws {
        let curve = TransitionCurve.entering
        try expectEqual(curve.value(at: -3), 0)
        try expectEqual(curve.value(at: 7), 1)
        try expectEqual(curve.value(at: -3), curve.value(at: 0))
        try expectEqual(curve.value(at: 7), curve.value(at: 1))
    }

    /// The curve only ever moves forward: the wave never goes back.
    static func curveIsMonotonic() throws {
        for curve in [TransitionCurve.entering, .exiting, .standard, .ripple] {
            var previous = -1.0
            for step in 0...100 {
                let value = curve.value(at: Double(step) / 100)
                try expectTrue(value >= previous, "the curve \(curve) went back at \(step)")
                previous = value
            }
        }
    }

    /// The dedicated ripple tween moves gently at both ends: in the first
    /// tenth of the wave only a small fraction of the radius has grown (no
    /// burst out of the origin) and in the last tenth only a small fraction
    /// is left to collapse (no abrupt vanish). The shapes the wave used
    /// before moved fast exactly at these ends, so a regression back to
    /// them fails here.
    static func rippleWaveIsGentleAtItsEnds() throws {
        let ripple = TransitionCurve.ripple
        let atStart = ripple.value(at: 0.1)
        let nearEnd = ripple.value(at: 0.9)
        try expectTrue(atStart > 0 && atStart < 0.1,
                       "the wave must rise gently from the origin (reached \(atStart) at a tenth)")
        try expectTrue(nearEnd < 1 && nearEnd > 0.9,
                       "the wave must settle gently into its end (left \(1 - nearEnd) at a tenth)")
        try expectTrue(TransitionCurve.entering.value(at: 0.1) > atStart,
                       "the old entering shape burst at its start; ripple must be gentler")
        try expectTrue(TransitionCurve.exiting.value(at: 0.9) < nearEnd,
                       "the old exiting shape vanished abruptly at its end; ripple must be gentler")
    }

    // MARK: The wave

    /// The wave reaches the furthest corner of every window it opens, even
    /// when the windows sit at negative coordinates or with a gap between
    /// them: at the end of the reveal every pixel of every window is shown.
    static func waveCoversEveryCorner() throws {
        let targets = [
            GlobalRect(x: -1_920, y: -200, width: 1_280, height: 800),
            GlobalRect(x: 0, y: 0, width: 1_280, height: 800)
        ]
        let origin = GlobalPoint(x: -640, y: 400)
        let plan = RadialRevealPlan(origin: origin, targets: targets)
        for target in targets {
            for corner in [GlobalRect.Corner.topLeft, .topRight, .bottomLeft, .bottomRight] {
                let distance = origin.distance(toCorner: corner, of: target)
                try expectTrue(distance <= plan.radius,
                               "the corner \(corner) at \(distance) is outside the wave (\(plan.radius))")
                try expectEqual(RadialReveal.alpha(distance: distance, radius: plan.radius,
                                                    feather: plan.feather), 1,
                                "the corner \(corner) must be fully shown")
            }
        }
    }

    /// The pointer may sit outside every window: the wave still reaches the
    /// last corner of the last display.
    static func waveCoversAnOutsidePointer() throws {
        let target = GlobalRect(x: 100, y: 100, width: 400, height: 300)
        let origin = GlobalPoint(x: -2_000, y: -1_000)
        let plan = RadialRevealPlan(origin: origin, targets: [target])
        let furthest = origin.furthestCornerDistance(of: target)
        try expectTrue(furthest > 0)
        try expectEqual(plan.radius, furthest + plan.feather)
        try expectEqual(RadialReveal.alpha(distance: furthest, radius: plan.radius,
                                            feather: plan.feather), 1)
        // Beyond the wave nothing is shown.
        try expectEqual(RadialReveal.alpha(distance: plan.radius + 1, radius: plan.radius,
                                            feather: plan.feather), 0)
    }

    /// The hidden endpoint is exact: at radius 0 the wave shows nothing, not
    /// even at its own origin.
    static func hiddenWaveIsClear() throws {
        let plan = RadialRevealPlan(origin: GlobalPoint(x: 10, y: 10),
                                    targets: [GlobalRect(x: 0, y: 0, width: 100, height: 100)])
        try expectEqual(RadialReveal.radius(at: 0, plan: plan), 0)
        try expectEqual(RadialReveal.alpha(distance: 0, radius: 0, feather: plan.feather), 0)
        try expectEqual(RadialReveal.alpha(distance: 50, radius: 0, feather: plan.feather), 0)
    }
}
