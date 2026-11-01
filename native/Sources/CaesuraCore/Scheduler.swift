import Foundation

/// Deterministic scheduler driven by an injected clock.
/// No real timers inside the core: `plan` records a deadline on the injected clock;
/// the application schedules actual callbacks against `deadlineMillis`, tests advance
/// the clock and call into the planner.
public final class Scheduler {
    public let clock: Clock
    public private(set) var delay: Int64 = 0
    public private(set) var reference: String?
    public private(set) var plannedAtMillis: Int64 = 0
    /// Legacy: `timeLeft` is `false` when nothing is planned.
    public private(set) var isCancelled = true
    /// True once the plan has fired. The reference stays (legacy keeps the scheduler
    /// object), but the event must not be emitted again — otherwise a break that waits
    /// for a manual finish would repeat its event forever.
    public private(set) var hasFired = false

    public init(clock: Clock) {
        self.clock = clock
    }

    public var timeLeft: Int64? {
        if isCancelled { return nil }
        return plannedAtMillis + delay - clock.nowMillis
    }

    public func plan(delay: Int64, reference: String) {
        self.delay = max(0, delay)
        self.reference = reference
        plannedAtMillis = clock.nowMillis
        isCancelled = false
        hasFired = false
    }

    /// Marks the current plan as fired (the event has been emitted).
    public func markFired() {
        hasFired = true
    }

    /// Re-anchors the plan after wall-clock jumps (suspend/resume): the remaining time
    /// now counts from the current instant.
    public func correct() {
        guard !isCancelled, let left = timeLeft else { return }
        plannedAtMillis = clock.nowMillis
        delay = max(0, left)
    }

    public func cancel() {
        isCancelled = true
        reference = nil
        delay = 0
        hasFired = false
    }

    /// True when the plan is due at the current clock instant.
    public var isDue: Bool {
        guard !isCancelled else { return false }
        return clock.nowMillis >= plannedAtMillis + delay
    }
}
