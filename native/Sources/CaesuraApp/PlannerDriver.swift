import Foundation
import CaesuraCore

/// Owns real timers for the deterministic planner (the core owns no timers).
/// A single re-armed DispatchSourceTimer fires at the planner's current deadline;
/// every planner state change re-arms it. Suspend/resume wall-clock correction is
/// handled by the planner's `correctScheduler`.
final class PlannerDriver {
    private let planner: BreaksPlanner
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "stretchy.planner-driver".replacingOccurrences(of: "stretchy", with: "caesura"))

    init(planner: BreaksPlanner) {
        self.planner = planner
    }

    /// Re-arm for the current plan. Call after every planner transition.
    func reschedule() {
        timer?.cancel()
        timer = nil
        guard planner.scheduler.reference != nil, !planner.scheduler.isCancelled else { return }
        // A plan that already fired must not be armed again — that would be a busy loop.
        guard !planner.scheduler.hasFired else { return }
        let left = planner.scheduler.timeLeft ?? 0
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + DispatchTimeInterval.milliseconds(Int(max(0, left))))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.planner.fireIfDue()
                self.reschedule()
            }
        }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
