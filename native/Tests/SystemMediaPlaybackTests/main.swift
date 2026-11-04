import Foundation

// The isolated harness: the production controller and its fake transport. The
// logging is quiet and cannot write to a persistent profile.
enum Log {
    static func info(_ message: String) {}
    static func warn(_ message: String) {}
    static func error(_ message: String) {}
}

/// The fake transport of the media session: it answers what the test wants and
/// it records every command.
///
/// The worker of the controller writes the state of the fake while the test
/// reads it, so the state is behind a lock and the order of the events is
/// carried by semaphores: the test never polls an array that the worker
/// writes.
final class FakeMediaSource: SystemMediaSessionSource {
    private let lock = NSLock()
    private var currentSession: SystemMediaSession?
    private var pauseOutcome: MediaCommandOutcome = .sent(playingAfter: false)
    private var playOutcome: MediaCommandOutcome = .sent(playingAfter: true)
    private var pauses: [SystemMediaSession] = []
    private var plays: [SystemMediaSession] = []
    private var lists: [Set<String>] = []
    private var reads = 0
    private var nextReadGate: DispatchSemaphore?
    private var nextPauseGate: DispatchSemaphore?

    /// Signalled when a read of a session begins.
    let readStarted = DispatchSemaphore(value: 0)
    /// Signalled when a pause begins.
    let pauseStarted = DispatchSemaphore(value: 0)
    /// Signalled when a play begins.
    let playStarted = DispatchSemaphore(value: 0)

    /// The session that the next read returns.
    var session: SystemMediaSession? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return currentSession
        }
        set {
            lock.lock()
            currentSession = newValue
            lock.unlock()
        }
    }

    /// The outcome of the next pause.
    var pauseOutcomeValue: MediaCommandOutcome {
        get {
            lock.lock()
            defer { lock.unlock() }
            return pauseOutcome
        }
        set {
            lock.lock()
            pauseOutcome = newValue
            lock.unlock()
        }
    }

    /// The outcome of the next play.
    var playOutcomeValue: MediaCommandOutcome {
        get {
            lock.lock()
            defer { lock.unlock() }
            return playOutcome
        }
        set {
            lock.lock()
            playOutcome = newValue
            lock.unlock()
        }
    }

    /// The number of the reads.
    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    /// The sessions the source was asked to pause.
    var pauseRequests: [SystemMediaSession] {
        lock.lock()
        defer { lock.unlock() }
        return pauses
    }

    /// The sessions the source was asked to play.
    var playRequests: [SystemMediaSession] {
        lock.lock()
        defer { lock.unlock() }
        return plays
    }

    /// The lists of the applications that keep playing, as they were told.
    var allowedLists: [Set<String>] {
        lock.lock()
        defer { lock.unlock() }
        return lists
    }

    /// Holds the next read until it is released.
    ///
    /// The signals that are left over are removed first: a wait of the test
    /// must never be satisfied by the read of an earlier call.
    func blockNextRead() {
        drain(readStarted)
        lock.lock()
        nextReadGate = DispatchSemaphore(value: 0)
        lock.unlock()
    }

    /// Releases the held read.
    func releaseNextRead() {
        lock.lock()
        let gate = nextReadGate
        nextReadGate = nil
        lock.unlock()
        gate?.signal()
    }

    /// Holds the next pause until it is released.
    func blockNextPause() {
        drain(pauseStarted)
        lock.lock()
        nextPauseGate = DispatchSemaphore(value: 0)
        lock.unlock()
    }

    /// Releases the held pause.
    func releaseNextPause() {
        lock.lock()
        let gate = nextPauseGate
        nextPauseGate = nil
        lock.unlock()
        gate?.signal()
    }

    /// Removes the signals that are left over.
    private func drain(_ semaphore: DispatchSemaphore) {
        while semaphore.wait(timeout: .now()) == .success {}
    }

    func readSession() -> SystemMediaSession? {
        lock.lock()
        reads += 1
        let gate = nextReadGate
        let session = currentSession
        lock.unlock()
        readStarted.signal()
        // The gate is not cleared here: the release of the test clears it, so
        // that a signal can never be lost.
        if let gate { gate.wait() }
        return session
    }

    func sendPause(expected: SystemMediaSession,
                   allowedBundleIdentifiers: Set<String>) -> MediaCommandOutcome {
        lock.lock()
        pauses.append(expected)
        lists.append(allowedBundleIdentifiers)
        let outcome = pauseOutcome
        let gate = nextPauseGate
        lock.unlock()
        pauseStarted.signal()
        if let gate { gate.wait() }
        // The system reports the state of the media after the command.
        if case .sent(let after) = outcome, let after {
            setPlaying(after)
        }
        return outcome
    }

    func sendPlay(expected: SystemMediaSession,
                  allowedBundleIdentifiers: Set<String>) -> MediaCommandOutcome {
        lock.lock()
        plays.append(expected)
        lists.append(allowedBundleIdentifiers)
        let outcome = playOutcome
        lock.unlock()
        playStarted.signal()
        // The system reports the state of the media after the command.
        if case .sent(let after) = outcome, let after {
            setPlaying(after)
        }
        return outcome
    }

    /// The media of the session plays or waits, as the system reports it.
    private func setPlaying(_ playing: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let session = currentSession else { return }
        currentSession = SystemMediaSession(bundleIdentifier: session.bundleIdentifier,
                                            parentApplicationBundleIdentifier: session.parentApplicationBundleIdentifier,
                                            processIdentifier: session.processIdentifier,
                                            mediaItemIdentifier: session.mediaItemIdentifier,
                                            isPlaying: playing)
    }
}

/// The checks of the controller.
enum SystemMediaPlaybackTests {
    /// A session of the tests.
    static func session(bundle: String = "com.example.player",
                        parent: String? = nil,
                        process: Int? = 4242,
                        item: String? = "item-1",
                        playing: Bool = true) -> SystemMediaSession {
        SystemMediaSession(bundleIdentifier: bundle,
                           parentApplicationBundleIdentifier: parent,
                           processIdentifier: process,
                           mediaItemIdentifier: item,
                           isPlaying: playing)
    }

    static func run() -> [String: Bool] {
        var checks: [String: Bool] = [:]

        // 1. The application on the list keeps playing: its bundle identifier
        //    matches the list.
        do {
            let source = FakeMediaSource()
            source.session = session(bundle: "com.spotify.client")
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: ["com.spotify.client"])
            controller.waitForPendingWork()
            checks["allowlistBundleIsNeverPaused"] = source.pauseRequests.isEmpty
                && !controller.didPause
        }

        // 2. The parent application matches the list: a browser reports the
        //    helper that plays the media.
        do {
            let source = FakeMediaSource()
            source.session = session(bundle: "com.apple.WebKit.GPU", parent: "com.spotify.client")
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: ["com.spotify.client"])
            controller.waitForPendingWork()
            checks["allowlistParentIsNeverPaused"] = source.pauseRequests.isEmpty
                && !controller.didPause
        }

        // 3. Another application is paused and resumed.
        do {
            let source = FakeMediaSource()
            source.session = session()
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: ["com.spotify.client"])
            controller.waitForPendingWork()
            let paused = source.pauseRequests.count == 1 && controller.didPause
            controller.endBreak()
            controller.waitForPendingWork()
            checks["otherApplicationIsPausedAndResumed"] = paused
                && source.playRequests.count == 1
                && !controller.didPause
        }

        // 4. No session at all: nothing is paused.
        do {
            let source = FakeMediaSource()
            source.session = nil
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: [])
            controller.waitForPendingWork()
            checks["noSessionIsNeverPaused"] = source.pauseRequests.isEmpty
                && !controller.didPause
        }

        // 5. A session that does not play: nothing is paused.
        do {
            let source = FakeMediaSource()
            source.session = session(playing: false)
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: [])
            controller.waitForPendingWork()
            checks["pausedSessionIsNeverPaused"] = source.pauseRequests.isEmpty
                && !controller.didPause
        }

        // 6. A session without the identifier of a media item: nothing is
        //    paused, because it could never be resumed with certainty.
        do {
            let source = FakeMediaSource()
            source.session = session(item: nil)
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: [])
            controller.waitForPendingWork()
            checks["unknownItemIsNeverPaused"] = source.pauseRequests.isEmpty
                && !controller.didPause
        }

        // 7. A pause that is not confirmed is not remembered: nothing is
        //    resumed after the break.
        do {
            let source = FakeMediaSource()
            source.session = session()
            source.pauseOutcomeValue = .sent(playingAfter: true)
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: [])
            controller.waitForPendingWork()
            let notRemembered = !controller.didPause
            controller.endBreak()
            controller.waitForPendingWork()
            checks["unconfirmedPauseIsNotResumed"] = notRemembered
                && source.playRequests.isEmpty
        }

        // 8. A refused pause is not remembered either.
        do {
            let source = FakeMediaSource()
            source.session = session()
            source.pauseOutcomeValue = .refused("another media item plays")
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: [])
            controller.waitForPendingWork()
            controller.endBreak()
            controller.waitForPendingWork()
            checks["refusedPauseIsNotResumed"] = !controller.didPause
                && source.playRequests.isEmpty
        }

        // 9. The break ends before the session could be read: the pause never
        //    goes out.
        do {
            let source = FakeMediaSource()
            source.blockNextRead()
            source.session = session()
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: [])
            let reading = source.readStarted.wait(timeout: .now() + 5) == .success
            controller.endBreak()
            source.releaseNextRead()
            controller.waitForPendingWork()
            checks["breakEndsBeforeTheReadDoesNotPause"] = reading
                && source.pauseRequests.isEmpty
        }

        // 10. The pause lands after its break ended and no break runs: the
        //     media plays again.
        do {
            let source = FakeMediaSource()
            source.blockNextPause()
            source.session = session()
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: [])
            let pausing = source.pauseStarted.wait(timeout: .now() + 5) == .success
            controller.endBreak()
            source.releaseNextPause()
            controller.waitForPendingWork()
            checks["latePauseIsRestored"] = pausing && source.playRequests.count == 1
        }

        // 11. Two breaks in a row: the first one is dropped, the second one
        //     pauses the media.
        do {
            let source = FakeMediaSource()
            source.session = session()
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: [])
            controller.beginBreak(allowedBundleIdentifiers: [])
            controller.waitForPendingWork()
            checks["consecutiveBreaksPauseOnce"] = source.pauseRequests.count == 1
        }

        // 12. Another media item plays: the paused one is not resumed.
        do {
            let source = FakeMediaSource()
            source.session = session(item: "item-1")
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: [])
            controller.waitForPendingWork()
            source.session = session(item: "item-2", playing: false)
            controller.endBreak()
            controller.waitForPendingWork()
            checks["changedItemIsNotResumed"] = source.playRequests.isEmpty
        }

        // 13. Another application took over: nothing is resumed.
        do {
            let source = FakeMediaSource()
            source.session = session()
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: [])
            controller.waitForPendingWork()
            source.session = session(bundle: "com.example.other", playing: false)
            controller.endBreak()
            controller.waitForPendingWork()
            checks["changedTargetIsNotResumed"] = source.playRequests.isEmpty
        }

        // 14. The user started the media again: nothing is sent.
        do {
            let source = FakeMediaSource()
            source.session = session()
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: [])
            controller.waitForPendingWork()
            source.session = session(playing: true)
            controller.endBreak()
            controller.waitForPendingWork()
            checks["manualResumeIsLeftAlone"] = source.playRequests.isEmpty
        }

        // 15. The application closes: nothing is resumed and nothing is
        //     paused any more.
        do {
            let source = FakeMediaSource()
            source.session = session()
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: [])
            controller.waitForPendingWork()
            controller.shutdown()
            controller.endBreak()
            controller.waitForPendingWork()
            let closed = source.playRequests.isEmpty
            controller.beginBreak(allowedBundleIdentifiers: [])
            controller.waitForPendingWork()
            checks["shutdownResumesNothing"] = closed && source.pauseRequests.count == 1
        }

        // 16. The list of the applications that keep playing changes while the
        //     break runs: the new list is the one that counts.
        do {
            let source = FakeMediaSource()
            source.blockNextRead()
            source.session = session()
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: [])
            let reading = source.readStarted.wait(timeout: .now() + 5) == .success
            controller.updateAllowedApplications(["com.example.player"])
            source.releaseNextRead()
            controller.waitForPendingWork()
            checks["allowlistChangeAppliesToTheRunningBreak"] = reading
                && source.pauseRequests.isEmpty
        }

        // 17. The break ends without a break that paused anything: no command
        //     goes out.
        do {
            let source = FakeMediaSource()
            let controller = SystemMediaPlaybackController(source: source)
            controller.endBreak()
            controller.waitForPendingWork()
            checks["endWithoutBeginSendsNothing"] = source.pauseRequests.isEmpty
                && source.playRequests.isEmpty
        }

        // 18. An isolated run never touches the media of the system.
        do {
            let source = MediaSessionTransport.make(isIsolatedRun: true)
            let reads = source.readSession() == nil
            let outcome = source.sendPause(expected: session(), allowedBundleIdentifiers: [])
            checks["isolatedRunTouchesNothing"] = reads
                && outcome == .refused(MediaRemoteSessionSource.isolatedReason)
        }

        // 19. The production controller of an isolated run stays quiet.
        do {
            let controller = SystemMediaPlaybackController()
            controller.beginBreak(allowedBundleIdentifiers: [])
            controller.waitForPendingWork()
            checks["isolatedDefaultControllerIsQuiet"] = !controller.didPause
        }

        // 20. A queued resume is dropped when a break starts in the meantime:
        //     the new break owns the media now.
        do {
            let source = FakeMediaSource()
            source.session = session()
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: [])
            controller.waitForPendingWork()
            let paused = controller.didPause
            // The read of the resume is held, so that the new break starts
            // while the resume waits for its answer.
            source.blockNextRead()
            controller.endBreak()
            let reading = source.readStarted.wait(timeout: .now() + 5) == .success
            controller.beginBreak(allowedBundleIdentifiers: [])
            source.releaseNextRead()
            controller.waitForPendingWork()
            checks["queuedResumeIsDroppedByTheNextBreak"] = paused && reading
                && source.playRequests.isEmpty
        }

        // 21. A pause that lands after its break ended belongs to the break
        //     that runs now: the media is not played in between.
        do {
            let source = FakeMediaSource()
            source.blockNextPause()
            source.session = session()
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: [])
            let pausing = source.pauseStarted.wait(timeout: .now() + 5) == .success
            controller.endBreak()
            controller.beginBreak(allowedBundleIdentifiers: [])
            source.releaseNextPause()
            controller.waitForPendingWork()
            let handedOver = source.playRequests.isEmpty && controller.didPause
            // The break that owns the pause resumes it when it ends.
            controller.endBreak()
            controller.waitForPendingWork()
            checks["latePauseBelongsToTheRunningBreak"] = pausing && handedOver
                && source.playRequests.count == 1
        }

        // 22. The application closes while the session is read: no command
        //     goes out at all.
        do {
            let source = FakeMediaSource()
            source.blockNextRead()
            source.session = session()
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: [])
            let reading = source.readStarted.wait(timeout: .now() + 5) == .success
            controller.shutdown()
            source.releaseNextRead()
            controller.waitForPendingWork()
            checks["shutdownDuringTheReadSendsNothing"] = reading
                && source.pauseRequests.isEmpty && source.playRequests.isEmpty
        }

        // 23. The media of an earlier break comes back in a later break: it
        //     is not resumed, because the backend gave the pause up when the
        //     break ended and the target had changed.
        do {
            let source = FakeMediaSource()
            source.session = session(item: "item-1")
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: [])
            controller.waitForPendingWork()
            let paused = controller.didPause
            // The user switches to another item while the break runs.
            source.session = session(item: "item-2", playing: false)
            controller.endBreak()
            controller.waitForPendingWork()
            let released = !controller.didPause
            // The old item shows up again in the next break, paused by the
            // user: the backend does not own that pause any more.
            source.session = session(item: "item-1", playing: false)
            controller.beginBreak(allowedBundleIdentifiers: [])
            controller.waitForPendingWork()
            controller.endBreak()
            controller.waitForPendingWork()
            checks["givenUpPauseIsNeverResumed"] = paused && released
                && source.pauseRequests.count == 1 && source.playRequests.isEmpty
        }

        // 25. An application that is added to the list of the applications
        //     that keep playing while its media is paused: the pause the
        //     backend owns is released, and the resume is sent without the
        //     list, so that the media of the application plays again.
        do {
            let source = FakeMediaSource()
            source.session = session()
            let controller = SystemMediaPlaybackController(source: source)
            controller.beginBreak(allowedBundleIdentifiers: [])
            controller.waitForPendingWork()
            let paused = controller.didPause
            controller.updateAllowedApplications(["com.example.player"])
            controller.waitForPendingWork()
            let released = !controller.didPause
            let withoutList = source.allowedLists.last?.isEmpty ?? false
            checks["allowedApplicationReleasesTheOwnedPause"] = paused && released
                && source.playRequests.count == 1 && withoutList
        }

        // 26. The answer of the helper: a session without a known state is no
        //     session at all.
        do {
            let valid = """
            {"result":"ok","action":"read","bundleIdentifier":"com.example.player",\
            "parentApplicationBundleIdentifier":"com.example.host","processIdentifier":42,\
            "mediaItemIdentifier":"item-1","playing":true}
            """
            let parsed = GuardedResult(json: valid)
            checks["helperAnswerCarriesTheSession"] = parsed?.session?.bundleIdentifier
                == "com.example.player" && parsed?.session?.isPlaying == true
                && parsed?.session?.mediaItemIdentifier == "item-1"
            let unknown = """
            {"result":"ok","action":"read","bundleIdentifier":"com.example.player","playing":null}
            """
            let unknownResult = GuardedResult(json: unknown)
            checks["helperAnswerWithoutStateHasNoSession"] = unknownResult != nil
                && unknownResult?.session == nil
            let wrong = """
            {"result":"ok","action":"read","bundleIdentifier":"com.example.player","playing":"yes"}
            """
            let wrongResult = GuardedResult(json: wrong)
            checks["helperAnswerWithWrongStateHasNoSession"] = wrongResult != nil
                && wrongResult?.session == nil
        }

        let numericState = GuardedResult(json:
            "{\"action\":\"read\",\"result\":\"ok\",\"bundleIdentifier\":\"com.example.player\",\"playing\":0}")
        checks["numericStateIsNotABoolean"] = numericState != nil && numericState?.session == nil
        let numericConfirmation = GuardedResult(json:
            "{\"action\":\"play\",\"result\":\"sent\",\"playingAfter\":1}")
        checks["numericConfirmationIsNotABoolean"] = numericConfirmation != nil
            && numericConfirmation?.playingAfter == nil

        return checks
    }
}

var failures = 0
var count = 0
for (name, passed) in SystemMediaPlaybackTests.run().sorted(by: { $0.key < $1.key }) {
    count += 1
    if !passed {
        failures += 1
        print("FAIL \(name)")
    }
}
print("system media checks=\(count) failures=\(failures)")
exit(failures == 0 ? 0 : 1)
