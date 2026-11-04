import Foundation
import CaesuraCore

enum MediaCommandOutcome: Equatable {
    case sent(playingAfter: Bool?)
    case refused(String)
}

protocol SystemMediaSessionSource: AnyObject {
    func readSession() -> SystemMediaSession?
    func sendPause(expected: SystemMediaSession, allowedBundleIdentifiers: Set<String>) -> MediaCommandOutcome
    func sendPlay(expected: SystemMediaSession, allowedBundleIdentifiers: Set<String>) -> MediaCommandOutcome
    func cancelPendingWork()
}

extension SystemMediaSessionSource {
    func cancelPendingWork() {}
}

/// UI calls only update a small locked state and enqueue work. Reads and media
/// commands are serialized away from the main thread. Ending a break always
/// enqueues its finish, so a pause still in flight can be compensated when it
/// returns. A new break invalidates the old finish and inherits any owned pause.
final class SystemMediaPlaybackController {
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "caesura.system-media-playback", qos: .utility)
    private let source: SystemMediaSessionSource
    private var generation = 0
    private var active = false
    private var stopped = false
    private var allowed: Set<String> = []
    private var owned: SystemMediaSession?

    init(source: SystemMediaSessionSource = MediaSessionTransport.make()) { self.source = source }

    var didPause: Bool {
        lock.lock(); defer { lock.unlock() }
        return owned != nil
    }

    func beginBreak(allowedBundleIdentifiers: Set<String>) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        generation &+= 1
        let token = generation
        active = true
        allowed = allowedBundleIdentifiers
        lock.unlock()
        worker.async { [weak self] in self?.pause(token: token) }
    }

    func endBreak() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        generation &+= 1
        let token = generation
        active = false
        lock.unlock()
        worker.async { [weak self] in self?.finish(token: token) }
    }

    func updateAllowedApplications(_ identifiers: Set<String>) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        allowed = identifiers
        let token = generation
        let shouldRelease = active
        lock.unlock()
        if shouldRelease {
            // This also runs after an in-flight pause, so adding that app to
            // the allowlist releases a pause whose confirmation arrived later.
            worker.async { [weak self] in self?.finish(token: token, allowedOnly: true) }
        }
    }

    func shutdown() {
        lock.lock()
        stopped = true
        active = false
        generation &+= 1
        owned = nil
        lock.unlock()
        source.cancelPendingWork()
    }

    func waitForPendingWork() { worker.sync {} }

    private func pause(token: Int) {
        guard pauseContext(token) != nil, let current = source.readSession(),
              let exemptions = pauseContext(token) else { return }
        lock.lock()
        if let previous = owned {
            let same = SystemMediaPlaybackPolicy.isSameSession(previous, current)
                && SystemMediaPlaybackPolicy.isSameMediaItem(previous, current)
            if !same || current.isPlaying { owned = nil }
        }
        lock.unlock()
        guard SystemMediaPlaybackPolicy.mayPause(current, allowedBundleIdentifiers: exemptions),
              pauseContext(token) != nil else { return }
        switch source.sendPause(expected: current, allowedBundleIdentifiers: exemptions) {
        case .refused(let reason):
            Log.info("Caesura: system media pause refused — \(reason)")
        case .sent(let playingAfter):
            guard playingAfter == false else {
                Log.warn("Caesura: system media pause was not confirmed")
                return
            }
            // Record even a late confirmation: endBreak's queued finish then
            // restores it, or the new active break inherits it. Shutdown is
            // the sole exception and never starts media on the way out.
            lock.lock()
            if !stopped { owned = current }
            lock.unlock()
            Log.info("Caesura: confirmed system media pause for '\(current.bundleIdentifier)'")
        }
    }

    private func finish(token: Int, allowedOnly: Bool = false) {
        guard let remembered = finishContext(token, allowedOnly: allowedOnly) else { return }
        let current = source.readSession()
        guard finishContext(token, allowedOnly: allowedOnly) == remembered else { return }
        guard SystemMediaPlaybackPolicy.mayResume(remembered: remembered, current: current) else {
            release(remembered, token: token)
            Log.info("Caesura: system media target or playback changed; resume skipped")
            return
        }
        // A pause we already own may be released after its app was added to
        // the allowlist. Target/item guards still apply to the explicit Play.
        let outcome = source.sendPlay(expected: remembered, allowedBundleIdentifiers: [])
        release(remembered, token: token)
        switch outcome {
        case .sent(let playingAfter):
            if playingAfter == true { Log.info("Caesura: confirmed system media resume") }
            else { Log.warn("Caesura: system media resume was not confirmed") }
        case .refused(let reason):
            Log.info("Caesura: system media resume refused — \(reason)")
        }
    }

    private func pauseContext(_ token: Int) -> Set<String>? {
        lock.lock(); defer { lock.unlock() }
        return !stopped && active && generation == token ? allowed : nil
    }

    private func finishContext(_ token: Int, allowedOnly: Bool) -> SystemMediaSession? {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, generation == token, let session = owned else { return nil }
        if allowedOnly {
            guard active, SystemMediaPlaybackPolicy.keepsPlaying(session,
                allowedBundleIdentifiers: allowed) else { return nil }
        } else if active { return nil }
        return session
    }

    private func release(_ session: SystemMediaSession, token: Int) {
        lock.lock(); defer { lock.unlock() }
        if generation == token && owned == session { owned = nil }
    }
}
