import AppKit
import SwiftUI
import CaesuraCore

/// The native adapters of the shared tween tokens.
///
/// The core owns the durations (`TransitionTokens`) and the one gentle cubic
/// family (`TransitionCurve`); this file is the only place where they become
/// a SwiftUI animation or an AppKit timing function. No transition of the app
/// carries an animation literal of its own any more, and every transition
/// answers to the same curve.
///
/// The core stays Foundation-only: the adapters live here, in the native app.
enum Tween {
    /// The SwiftUI animation of a transition: the shared curve over the
    /// shared duration.
    static func animation(millis: Int64, curve: TransitionCurve) -> Animation {
        let points = curve.controlPoints
        return Animation.timingCurve(points.x1, points.y1, points.x2, points.y2,
                                     duration: seconds(millis))
    }

    /// The Core Animation timing function of the shared curve.
    static func timingFunction(_ curve: TransitionCurve) -> CAMediaTimingFunction {
        let points = curve.controlPoints
        return CAMediaTimingFunction(controlPoints: Float(points.x1), Float(points.y1),
                                     Float(points.x2), Float(points.y2))
    }

    /// The duration of a transition in seconds (AppKit speaks seconds).
    static func seconds(_ millis: Int64) -> TimeInterval {
        TimeInterval(millis) / 1000
    }

    /// True when the system asks for less movement: the transitions then
    /// happen at once, without a curve.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Runs an AppKit animation with the shared duration and the shared
    /// curve. With reduced motion the change happens at once.
    static func appKit(_ millis: Int64, _ curve: TransitionCurve,
                       _ body: @escaping (NSAnimationContext) -> Void,
                       completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0 : seconds(millis)
            context.timingFunction = timingFunction(curve)
            body(context)
        }, completionHandler: completion)
    }
}

// MARK: - The named transitions

extension Tween {
    /// The reveal of a break window: the entry rises from the origin, the
    /// exit settles gently back towards it — both on the ripple curve.
    static var breakEntry: Animation {
        animation(millis: TransitionTokens.breakEntryMillis, curve: .ripple)
    }

    static var breakExit: Animation {
        animation(millis: TransitionTokens.breakExitMillis, curve: .ripple)
    }

    /// The handover of the brightness between the lines of a poem.
    static var emphasisHandover: Animation {
        animation(millis: TransitionTokens.emphasisHandoverMillis, curve: .standard)
    }

    /// Small feedback (the toast) appears and disappears.
    static var smallFeedback: Animation {
        animation(millis: TransitionTokens.smallFeedbackMillis, curve: .entering)
    }

    static var smallFeedbackDismiss: Animation {
        animation(millis: TransitionTokens.smallFeedbackDismissMillis, curve: .exiting)
    }
}
