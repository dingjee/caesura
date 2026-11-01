import AppKit
import CaesuraCore

/// Opt-in lifecycle regression runner (development only).
///
/// `CAESURA_LIFECYCLE_TEST=<steps>` starts the runner after the app finished
/// launching. The runner drives the real windows of the app — it opens and closes
/// them, runs breaks and checks the menu bar item.
///
/// Every step runs in its own run loop turn (a timer, not a plain dispatch block),
/// so the main autorelease pool is drained between the steps. A window that is
/// released twice — once by its owner, once by the autorelease pool — crashes the
/// app exactly there, and the drain is what makes the difference visible.
///
/// Without the environment variable the runner is never created and the app behaves
/// exactly as before.
final class LifecycleTestRunner {
    /// A sequence of steps. `repeat:<count>:` repeats the steps of the sequence.
    private struct Segment {
        var cycles: Int
        var steps: [String]
    }

    private let coordinator: AppCoordinator
    private var segments: [Segment] = []
    private var segmentIndex = 0
    private var stepIndex = 0
    private var cycleIndex = 0

    /// The pause between two steps. It is long enough for the run loop to finish
    /// the current turn (and with it the autorelease pool) before the next step
    /// starts.
    private static let stepDelay: TimeInterval = 0.05

    /// `repeat:<cycles>:<step>,<step>,…` or a plain list of steps. Sequences are
    /// separated by `;`, so a long observation can follow the repeated ones:
    /// `repeat:3:preferences,preferences-close;wait:180,tray`.
    init?(coordinator: AppCoordinator, spec: String) {
        // The runner drives the real windows of the app: it only runs in an
        // isolated profile.
        guard AppPaths.isIsolatedRun else { return nil }
        self.coordinator = coordinator
        for part in spec.split(separator: ";") {
            var text = String(part)
            var cycles = 1
            if text.hasPrefix("repeat:") {
                text = String(text.dropFirst("repeat:".count))
                guard let separator = text.firstIndex(of: ":") else { return nil }
                cycles = Int(text[text.startIndex..<separator]) ?? 1
                text = String(text[text.index(after: separator)...])
            }
            let steps = text.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if steps.isEmpty { continue }
            segments.append(Segment(cycles: max(1, cycles), steps: steps))
        }
        if segments.isEmpty { return nil }
    }

    func start() {
        // Preflight: the isolated test places its windows on the secondary display,
        // so that the display of the user is never covered. Without a secondary
        // display the test fails — it never falls back to the main display. A test
        // may ask for the main display explicitly
        // (CAESURA_NATIVE_TEST_MAIN_DISPLAY=1); the app then logs that it covers
        // the display of the user.
        guard NSScreen.screens.count > 1 || AppPaths.allowsMainDisplayInIsolatedRun else {
            fail("no secondary display is attached (the isolated test needs one)")
            return
        }
        let steps = segments.reduce(0) { $0 + $1.steps.count * $1.cycles }
        let display = NSScreen.screens.count > 1 ? NSScreen.screens[1] : NSScreen.main
        Log.info("Caesura: lifecycle test started (\(segments.count) sequence(s), \(steps) step(s), " +
                 "display: \(display?.frame ?? CGRect.zero))")
        scheduleNext()
    }

    private func scheduleNext() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stepDelay) { [weak self] in
            self?.runNextStep()
        }
    }

    private func runNextStep() {
        guard segmentIndex < segments.count else {
            succeed()
            return
        }
        let segment = segments[segmentIndex]
        if stepIndex < segment.steps.count {
            let step = segment.steps[stepIndex]
            stepIndex += 1
            perform(step)
            return
        }
        if cycleIndex + 1 < segment.cycles {
            cycleIndex += 1
            stepIndex = 0
            Log.info("Caesura: lifecycle test: cycle \(cycleIndex + 1) of \(segment.cycles)")
            scheduleNext()
            return
        }
        segmentIndex += 1
        stepIndex = 0
        cycleIndex = 0
        scheduleNext()
    }

    private func perform(_ step: String) {
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "preferences":
            coordinator.lifecycleOpenPreferences()
        case "preferences-close":
            coordinator.lifecycleClosePreferences()
        case "mini":
            coordinator.lifecycleStartMiniBreak()
        case "postpone":
            coordinator.lifecyclePostponeBreak()
        case "skip":
            coordinator.lifecycleSkipBreak()
        case "released":
            guard parts.count > 1 else {
                fail("the step 'released' needs a window name")
                return
            }
            guard coordinator.lifecycleWindowReleased(parts[1]) else {
                fail("the window '\(parts[1])' was not released after its close")
                return
            }
            Log.info("Caesura: lifecycle test: the window '\(parts[1])' was released")
        case "tray":
            guard coordinator.statusBar.isStatusItemVisible else {
                fail("the menu bar item is not visible (present: \(coordinator.statusBar.isStatusItemPresent))")
                return
            }
            Log.info("Caesura: lifecycle test: the menu bar item is visible")
        case "tray-hide":
            coordinator.lifecycleHideTray()
        case "refresh":
            coordinator.statusBar.refresh()
        case "relayout":
            coordinator.lifecycleRelayout()
        case "break-visible":
            guard coordinator.lifecycleBreakWindowVisible() else {
                fail("the running break has no visible window")
                return
            }
            Log.info("Caesura: lifecycle test: the break window is visible")
        case "wait":
            let seconds = Double(parts.count > 1 ? parts[1] : "1") ?? 1
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.runNextStep()
            }
            return
        case "quit":
            Log.info("Caesura: lifecycle test: quitting")
            coordinator.lifecycleQuit()
            reportUnfinishedQuit()
            return
        default:
            fail("unknown step '\(step)'")
            return
        }
        Log.info("Caesura: lifecycle test: step \(parts[0])")
        scheduleNext()
    }

    /// The app terminates itself; if it is still alive afterwards, the quit was
    /// refused (strict break mode) and the test failed.
    private func reportUnfinishedQuit() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.fail("the app did not quit")
        }
    }

    private func succeed() {
        Log.info("Caesura: lifecycle test finished successfully")
        Log.flush()
        // The app terminates itself: the normal termination path runs the
        // remaining clean up instead of skipping it with exit().
        coordinator.lifecycleQuit()
        reportUnfinishedQuit()
    }

    private func fail(_ message: String) {
        Log.error("Caesura: lifecycle test failed: \(message)")
        Log.flush()
        exit(1)
    }
}
