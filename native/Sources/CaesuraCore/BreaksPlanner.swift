import Foundation

/// Events emitted by the planner; the application maps them to windows, sounds and
/// notifications, exactly like legacy main.js subscribed to BreaksPlanner events.
public enum PlannerEvent: Equatable {
    case startMicrobreakNotification
    case startBreakNotification
    case startMicrobreak
    case startBreak
    case finishMicrobreak(shouldPlaySound: Bool, shouldPlanNext: Bool)
    case finishBreak(shouldPlaySound: Bool, shouldPlanNext: Bool)
    case resumeBreaks
    case updateToolTip
    /// Application should (re)start its idle/DND/exclusion pollers after a resume.
    case restartPollers
    /// Application should stop its idle/DND/exclusion pollers while paused.
    case stopPollers
    case naturalBreaksPoller(shouldUse: Bool)
    case dndPoller(shouldUse: Bool)
}

/// Deterministic port of app/breaksPlanner.js plus the pause-cause wiring that legacy
/// performed in its constructor. Time is injected; nothing here creates real timers.
public final class BreaksPlanner {
    public let clock: Clock
    public private(set) var settings: SettingsStore
    public private(set) var scheduler: Scheduler

    public private(set) var breakNumber = 0
    public private(set) var postponesNumber = 0
    public private(set) var isPaused = false
    public private(set) var pollersSuspended = false

    public private(set) var idleMachine: IdleStateMachine
    public private(set) var dndMachine = DndStateMachine()
    public private(set) var exclusionsMachine: ExclusionsStateMachine

    public var onEvent: ((PlannerEvent) -> Void)?

    private var pendingFinishShouldPlaySound = true

    public init(clock: Clock, settings: SettingsStore) {
        self.clock = clock
        self.settings = settings
        self.scheduler = Scheduler(clock: clock)
        self.idleMachine = IdleStateMachine(inactivityResetMillis: settings.getMillis("naturalBreaksInactivityResetTime"))
        self.exclusionsMachine = ExclusionsStateMachine(rule: .firstActive(in: settings.getArray("appExclusions")))
    }

    // MARK: Scheduling (legacy nextBreak/nextBreakAfterNotification/postpone/skip)

    public func nextBreak() {
        postponesNumber = 0
        scheduler.cancel()
        let shouldBreak = settings.getBool("break")
        let shouldMicrobreak = settings.getBool("microbreak")
        let interval = settings.getMillis("microbreakInterval")
        let breakNotification = settings.getBool("breakNotification")
        let breakNotificationInterval = settings.getMillis("breakNotificationInterval")
        let microbreakNotification = settings.getBool("microbreakNotification")
        let microbreakNotificationInterval = settings.getMillis("microbreakNotificationInterval")

        if !shouldBreak && shouldMicrobreak {
            if microbreakNotification {
                scheduler.plan(delay: interval - microbreakNotificationInterval, reference: "startMicrobreakNotification")
            } else {
                scheduler.plan(delay: interval, reference: "startMicrobreak")
            }
        } else if shouldBreak && !shouldMicrobreak {
            if breakNotification {
                scheduler.plan(delay: interval * (settings.getMillis("breakInterval") + 1) - breakNotificationInterval,
                               reference: "startBreakNotification")
            } else {
                scheduler.plan(delay: interval * (settings.getMillis("breakInterval") + 1), reference: "startBreak")
            }
        } else if shouldBreak && shouldMicrobreak {
            breakNumber += 1
            let breakInterval = settings.getMillis("breakInterval") + 1
            if breakNumber % Int(breakInterval) == 0 {
                if breakNotification {
                    scheduler.plan(delay: interval - breakNotificationInterval, reference: "startBreakNotification")
                } else {
                    scheduler.plan(delay: interval, reference: "startBreak")
                }
            } else {
                if microbreakNotification {
                    scheduler.plan(delay: interval - microbreakNotificationInterval, reference: "startMicrobreakNotification")
                } else {
                    scheduler.plan(delay: interval, reference: "startMicrobreak")
                }
            }
        }
    }

    public func nextBreakAfterNotification() {
        scheduler.cancel()
        let scheduledBreakType = self.scheduledBreakType
        let breakNotificationInterval = settings.getMillis("\(scheduledBreakType)NotificationInterval")
        let eventName = "start\(scheduledBreakType.prefix(1).uppercased())\(scheduledBreakType.dropFirst())"
        scheduler.plan(delay: breakNotificationInterval, reference: eventName)
    }

    public func postponeCurrentBreak() {
        scheduler.cancel()
        postponesNumber += 1
        var postponeTime: Int64
        var eventName: String
        let scheduledBreakType = self.scheduledBreakType
        let notification = settings.getBool("\(scheduledBreakType)Notification")
        if notification && settings.getMillis("\(scheduledBreakType)PostponeTime") > settings.getMillis("\(scheduledBreakType)NotificationInterval") {
            postponeTime = settings.getMillis("\(scheduledBreakType)PostponeTime") - settings.getMillis("\(scheduledBreakType)NotificationInterval")
            eventName = "start\(scheduledBreakType.prefix(1).uppercased())\(scheduledBreakType.dropFirst())Notification"
        } else {
            postponeTime = settings.getMillis("\(scheduledBreakType)PostponeTime")
            eventName = "start\(scheduledBreakType.prefix(1).uppercased())\(scheduledBreakType.dropFirst())"
        }
        scheduler.plan(delay: postponeTime, reference: eventName)
        onEvent?(.updateToolTip)
    }

    public func skipToMicrobreak(delay: Int64 = 100) {
        scheduler.cancel()
        let shouldBreak = settings.getBool("break")
        let shouldMicrobreak = settings.getBool("microbreak")
        if shouldBreak && shouldMicrobreak {
            let breakInterval = Int(settings.getMillis("breakInterval")) + 1
            if breakNumber % breakInterval == 0 {
                breakNumber = 1
            }
        }
        scheduler.plan(delay: delay, reference: "startMicrobreak")
        onEvent?(.updateToolTip)
    }

    public func skipToBreak(delay: Int64 = 100) {
        scheduler.cancel()
        let shouldBreak = settings.getBool("break")
        let shouldMicrobreak = settings.getBool("microbreak")
        if shouldBreak && shouldMicrobreak {
            let breakInterval = Int(settings.getMillis("breakInterval")) + 1
            breakNumber = breakInterval
        }
        scheduler.plan(delay: delay, reference: "startBreak")
        onEvent?(.updateToolTip)
    }

    public func clear() {
        scheduler.cancel()
        breakNumber = 0
        postponesNumber = 0
    }

    public func pause(_ milliseconds: Int64) {
        clear()
        isPaused = true
        pollersSuspended = true
        // Legacy stops the idle/DND/exclusion managers while paused.
        onEvent?(.stopPollers)
        if milliseconds != 1 {
            scheduler.plan(delay: milliseconds, reference: "resumeBreaks")
        }
    }

    public func resume() {
        scheduler.cancel()
        isPaused = false
        exclusionsMachine.reset()
        nextBreak()
        if pollersSuspended {
            pollersSuspended = false
            onEvent?(.restartPollers)
        }
    }

    /// Wall-clock correction after suspend/resume.
    public func correctScheduler() {
        scheduler.correct()
    }

    public func reset() {
        clear()
        resume()
    }

    // MARK: Break lifecycle wiring (legacy 'microbreakStarted'/'breakStarted')

    public func breakStarted(shouldPlaySound: Bool) {
        pendingFinishShouldPlaySound = shouldPlaySound
        scheduler.plan(delay: settings.getMillis("microbreakDuration"), reference: "finishMicrobreak")
    }

    public func longBreakStarted(shouldPlaySound: Bool) {
        pendingFinishShouldPlaySound = shouldPlaySound
        scheduler.plan(delay: settings.getMillis("breakDuration"), reference: "finishBreak")
    }

    /// Application-driven feeds: update the state machine, then run the legacy handler.
    public func applyIdle(idleMillis: Int64) {
        handleIdleUpdate(idleMachine.update(idleMillis: idleMillis))
    }

    public func applyDnd(enabled: Bool) {
        handleDndUpdate(dndMachine.update(enabled: enabled))
    }

    public func applyExclusion(matched: String?) {
        handleExclusionUpdate(exclusionsMachine.update(matched: matched))
    }

    // MARK: Pause causes

    public func handleIdleUpdate(_ output: IdleStateMachine.Output) {
        switch output {
        case .clearBreakScheduler:
            // Legacy: !isPaused && ref !== finish* && ref !== null
            if !isPaused, let reference = scheduler.reference,
               reference != "finishMicrobreak", reference != "finishBreak" {
                clear()
                Log.info("Caesura: pausing breaks because of idle time")
            }
        case .naturalBreakFinished:
            // Legacy: !isPaused && ref !== finish* (nil reference passes).
            if !isPaused, scheduler.reference != "finishMicrobreak", scheduler.reference != "finishBreak",
               !dndMachine.isOnDnd {
                reset()
                Log.info("Caesura: resuming breaks after idle time")
                onEvent?(.updateToolTip)
            }
        case .none:
            break
        }
    }

    public func handleDndUpdate(_ output: DndStateMachine.Output) {
        switch output {
        case .dndStarted:
            if !isPaused, let reference = scheduler.reference,
               reference != "finishMicrobreak", reference != "finishBreak" {
                clear()
                Log.info("Caesura: pausing breaks for Do Not Disturb")
                onEvent?(.updateToolTip)
            } else {
                dndMachine.forceOff()
            }
        case .dndFinished:
            if !isPaused, scheduler.reference != "finishMicrobreak", scheduler.reference != "finishBreak" {
                reset()
                Log.info("Caesura: resuming breaks for Do Not Disturb")
                onEvent?(.updateToolTip)
            }
        case .none:
            break
        }
    }

    public func handleExclusionUpdate(_ output: ExclusionsStateMachine.Output) {
        switch output {
        case .started(let rule, let exclusion):
            if rule == "pause" {
                if !isPaused, let reference = scheduler.reference,
                   reference != "finishMicrobreak", reference != "finishBreak" {
                    clear()
                    Log.info("Caesura: pausing breaks as 'pause' exclusion found running: '\(exclusion)'")
                    onEvent?(.updateToolTip)
                } else if !isPaused && scheduler.reference == "finishBreak" {
                    onEvent?(.finishBreak(shouldPlaySound: false, shouldPlanNext: false))
                    clear()
                    Log.info("Caesura: closing current and pausing breaks as 'pause' exclusion found running: '\(exclusion)'")
                    onEvent?(.updateToolTip)
                } else if !isPaused && scheduler.reference == "finishMicrobreak" {
                    onEvent?(.finishMicrobreak(shouldPlaySound: false, shouldPlanNext: false))
                    clear()
                    Log.info("Caesura: closing current and pausing breaks as 'pause' exclusion found running: '\(exclusion)'")
                    onEvent?(.updateToolTip)
                } else {
                    exclusionsMachine.forceOff()
                }
            } else if rule == "resume" {
                if !isPaused, scheduler.reference != "finishMicrobreak", scheduler.reference != "finishBreak" {
                    reset()
                    Log.info("Caesura: resuming breaks as 'resume' exclusion found running: '\(exclusion)'")
                    onEvent?(.updateToolTip)
                }
            }
        case .finished(let rule):
            if rule == "pause" {
                if !isPaused, scheduler.reference != "finishMicrobreak", scheduler.reference != "finishBreak" {
                    reset()
                    Log.info("Caesura: resuming breaks as no 'pause' exclusion found running")
                    onEvent?(.updateToolTip)
                }
            } else if rule == "resume" {
                if !isPaused, let reference = scheduler.reference,
                   reference != "finishMicrobreak", reference != "finishBreak" {
                    clear()
                    Log.info("Caesura: pausing breaks as no 'resume' exclusion found running")
                    onEvent?(.updateToolTip)
                } else {
                    exclusionsMachine.forceOn()
                }
            }
        case .none:
            break
        }
    }

    /// Application stops/resumes its pollers through these (legacy pause/resume did this directly).
    public func pollersDidStop() {}

    public func naturalBreaks(shouldUse: Bool) {
        onEvent?(.naturalBreaksPoller(shouldUse: shouldUse))
    }

    public func doNotDisturb(shouldUse: Bool) {
        if shouldUse {
            onEvent?(.dndPoller(shouldUse: true))
        } else {
            onEvent?(.dndPoller(shouldUse: false))
            if !isPaused && scheduler.reference == nil {
                reset()
            }
        }
    }

    /// Reinitialize from (possibly changed) settings: new rules, new reset time.
    public func reinitializeMachines() {
        exclusionsMachine = ExclusionsStateMachine(rule: .firstActive(in: settings.getArray("appExclusions")))
        idleMachine = IdleStateMachine(inactivityResetMillis: settings.getMillis("naturalBreaksInactivityResetTime"))
    }

    // MARK: Derived state

    public var scheduledBreakType: String {
        let shouldBreak = settings.getBool("break")
        let shouldMicrobreak = settings.getBool("microbreak")
        let breakInterval = Int(settings.getMillis("breakInterval")) + 1
        if shouldBreak && shouldMicrobreak {
            return breakNumber % breakInterval != 0 ? "microbreak" : "break"
        } else if !shouldBreak {
            return "microbreak"
        } else {
            return "break"
        }
    }

    public var timeToNextBreak: Int64? {
        guard let reference = scheduler.reference else { return nil }
        switch reference {
        case "startMicrobreak", "startBreak":
            return scheduler.timeLeft
        case "startBreakNotification":
            return scheduler.timeLeft.map { $0 + (settings.getBool("breakNotification") ? settings.getMillis("breakNotificationInterval") : 0) }
        case "startMicrobreakNotification":
            return scheduler.timeLeft.map { $0 + (settings.getBool("microbreakNotification") ? settings.getMillis("microbreakNotificationInterval") : 0) }
        default:
            return nil
        }
    }

    public var progressInterval: Int64? {
        guard let reference = scheduler.reference else { return nil }
        switch reference {
        case "startMicrobreak", "startBreak":
            return scheduler.delay
        case "startBreakNotification":
            return scheduler.delay + settings.getMillis("breakNotificationInterval")
        case "startMicrobreakNotification":
            return scheduler.delay + settings.getMillis("microbreakNotificationInterval")
        default:
            return nil
        }
    }

    public var progressPercentage: Int {
        guard let total = progressInterval, let remaining = timeToNextBreak,
              total > 0 else { return 0 }
        let progress = 1.0 - (Double(remaining) / Double(total))
        return max(0, min(100, Int((progress * 100).rounded())))
    }

    /// Fire the scheduled event when the injected clock reached its deadline.
    /// A plan fires only once: a break that waits for a manual finish keeps its
    /// scheduler reference (legacy behaviour) but must not repeat the event.
    public func fireIfDue() {
        guard scheduler.isDue, !scheduler.hasFired, let reference = scheduler.reference else { return }
        scheduler.markFired()
        switch reference {
        case "startMicrobreakNotification":
            onEvent?(.startMicrobreakNotification)
        case "startBreakNotification":
            onEvent?(.startBreakNotification)
        case "startMicrobreak":
            onEvent?(.startMicrobreak)
        case "startBreak":
            onEvent?(.startBreak)
        case "finishMicrobreak":
            onEvent?(.finishMicrobreak(shouldPlaySound: pendingFinishShouldPlaySound, shouldPlanNext: true))
        case "finishBreak":
            onEvent?(.finishBreak(shouldPlaySound: pendingFinishShouldPlaySound, shouldPlanNext: true))
        case "resumeBreaks":
            onEvent?(.resumeBreaks)
        default:
            break
        }
    }
}

extension ExclusionsStateMachine.Rule {
    /// First active rule, like legacy `settings.get('appExclusions').find(ex => ex.active)`.
    public static func firstActive(in array: [SettingsValue]) -> ExclusionsStateMachine.Rule? {
        for entry in array {
            if let rule = ExclusionsStateMachine.Rule.from(settingsValue: entry), rule.active {
                return rule
            }
        }
        return nil
    }
}
