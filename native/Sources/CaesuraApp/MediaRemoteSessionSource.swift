import Foundation
import CaesuraCore

/// The media session of the system, read through the vendored MediaRemote
/// adapter.
///
/// macOS offers no public way to read the media session: the daemon
/// `mediaremoted` grants the private framework only to the applications of
/// Apple. The vendored adapter therefore runs inside `/usr/bin/perl`, which is
/// entitled, and this source asks it for one guarded command per action: the
/// verification and command happen back to back in one process. The private
/// global command cannot make that check atomic; the remaining race is
/// documented in the vendored source provenance.
///
/// The helper prints the identity and the state of the session only — never a
/// title, never an address — and the source reads nothing else.
final class MediaRemoteSessionSource: SystemMediaSessionSource {
    /// The script of the adapter inside the bundle:
    /// `Contents/Resources/MediaRemoteAdapter/mediaremote-adapter.pl`.
    static let scriptResource = "MediaRemoteAdapter/mediaremote-adapter.pl"
    /// The framework of the adapter inside the bundle:
    /// `Contents/Frameworks/MediaRemoteAdapter.framework`.
    static let frameworkResource = "MediaRemoteAdapter.framework"
    /// The directory of the adapter in a development build. It holds the
    /// script and the framework.
    static let developmentDirectoryKey = "CAESURA_MEDIAREMOTE_ADAPTER_DIR"
    /// The reason an isolated run gives for every command.
    static let isolatedReason = "an isolated run never controls the media of the system"

    /// The script of the adapter.
    private let scriptURL: URL?
    /// The framework of the adapter.
    private let frameworkURL: URL?
    /// The entitled interpreter of the system.
    private let interpreterPath = "/usr/bin/perl"
    /// The time a single command may take.
    private let timeout: TimeInterval
    /// True when the source must not touch the media of the system: it reads
    /// no session and sends no command.
    private let isDryRun: Bool
    private let processLock = NSLock()
    private var pendingProcess: Process?
    private var cancelled = false

    func cancelPendingWork() {
        processLock.lock()
        cancelled = true
        let process = pendingProcess
        processLock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    init(scriptURL: URL? = MediaRemoteSessionSource.bundledScript(),
         frameworkURL: URL? = MediaRemoteSessionSource.bundledFramework(),
         timeout: TimeInterval = 12,
         isDryRun: Bool = false) {
        self.scriptURL = scriptURL
        self.frameworkURL = frameworkURL
        self.timeout = timeout
        self.isDryRun = isDryRun
    }

    /// The script of the adapter inside the application bundle.
    static func bundledScript() -> URL? {
        if let directory = developmentDirectory() {
            let url = directory.appendingPathComponent("mediaremote-adapter.pl")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent(scriptResource)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The framework of the adapter inside the application bundle.
    static func bundledFramework() -> URL? {
        if let directory = developmentDirectory() {
            let url = directory.appendingPathComponent(frameworkResource)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // The frameworks of an application bundle live in Contents/Frameworks.
        guard let frameworks = Bundle.main.privateFrameworksURL else { return nil }
        let url = frameworks.appendingPathComponent(frameworkResource)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The directory of a development build, when it is set.
    private static func developmentDirectory() -> URL? {
        guard let path = ProcessInfo.processInfo.environment[developmentDirectoryKey],
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - The commands

    /// Reads the session that reports now playing information.
    func readSession() -> SystemMediaSession? {
        guard !isDryRun else { return nil }
        guard let result = run(arguments: ["guarded", "read", "-", "-", "-", "-", "-", "0"]) else {
            return nil
        }
        guard result.result == "ok" else { return nil }
        return result.session
    }

    /// Pauses the session, guarded by its identity.
    func sendPause(expected: SystemMediaSession,
                   allowedBundleIdentifiers: Set<String>) -> MediaCommandOutcome {
        guard !isDryRun else { return .refused(MediaRemoteSessionSource.isolatedReason) }
        return send(action: "pause", expected: expected, allowedBundleIdentifiers: allowedBundleIdentifiers)
    }

    /// Plays the session, guarded by its identity.
    func sendPlay(expected: SystemMediaSession,
                  allowedBundleIdentifiers: Set<String>) -> MediaCommandOutcome {
        guard !isDryRun else { return .refused(MediaRemoteSessionSource.isolatedReason) }
        return send(action: "play", expected: expected, allowedBundleIdentifiers: allowedBundleIdentifiers)
    }

    /// Sends one guarded command to the helper.
    private func send(action: String, expected: SystemMediaSession,
                      allowedBundleIdentifiers: Set<String>) -> MediaCommandOutcome {
        let arguments = ["guarded", action,
                         expected.bundleIdentifier,
                         expected.parentApplicationBundleIdentifier ?? "-",
                         expected.processIdentifier.map { String($0) } ?? "-",
                         expected.mediaItemIdentifier ?? "-",
                         allowedBundleIdentifiers.sorted().joined(separator: ","),
                         "0"]
        guard let result = run(arguments: arguments) else {
            return .refused("the media session of the system could not be reached")
        }
        switch result.result {
        case "sent":
            return .sent(playingAfter: result.playingAfter)
        case "refused":
            return .refused(result.reason ?? "the system refused the command")
        default:
            return .refused(result.reason ?? "the system did not answer")
        }
    }

    /// Runs the helper and reads its answer.
    ///
    /// The two channels are read in parallel, so that a full pipe never holds
    /// the helper back, and the whole output is read — the last piece is never
    /// lost. The output is bounded, and a helper that hangs is ended: first
    /// with a signal, then with a kill. The wait is never endless.
    private func run(arguments: [String]) -> GuardedResult? {
        guard let scriptURL, let frameworkURL else {
            Log.warn("Caesura: the media session of the system is not available, "
                     + "the adapter is missing from the application bundle")
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreterPath)
        process.arguments = [scriptURL.path, frameworkURL.path] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let collected = OutputCollector()
        let failed = OutputCollector()
        processLock.lock()
        guard !cancelled else { processLock.unlock(); return nil }
        do {
            try process.run()
            pendingProcess = process
            processLock.unlock()
        } catch {
            processLock.unlock()
            Log.warn("Caesura: the media session helper could not be started")
            return nil
        }
        defer {
            processLock.lock()
            if pendingProcess === process { pendingProcess = nil }
            processLock.unlock()
        }
        // Both channels are read to their end in parallel: a helper that
        // writes a lot on the error channel never blocks on a full pipe.
        let readers = DispatchGroup()
        let queue = DispatchQueue(label: "caesura.media-helper.output", attributes: .concurrent)
        queue.async(group: readers) {
            collected.drain(output.fileHandleForReading)
        }
        queue.async(group: readers) {
            failed.drain(errors.fileHandleForReading)
        }
        // The helper answers in milliseconds; a helper that hangs is ended
        // instead of holding the queue of the work.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killDeadline {
                usleep(20_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        // The readers end when the pipes close, which the end of the helper
        // caused. The wait is bounded all the same.
        guard readers.wait(timeout: .now() + 2) == .success else { return nil }
        guard process.terminationStatus == 0 else {
            // The helper never prints the metadata of the media on its error
            // channel, so the first line of it is safe to write down.
            Log.warn("Caesura: the media session helper failed: \(failed.firstLine)")
            return nil
        }
        return GuardedResult(json: collected.text)
    }
}

/// The answer of the helper: what it did and the session it saw.
struct GuardedResult {
    /// The action that was asked for.
    let action: String
    /// What happened: "ok", "none", "sent", "refused" or "dry-run".
    let result: String
    /// Why the command was refused, when it was.
    let reason: String?
    /// The session the helper saw.
    let session: SystemMediaSession?
    /// The state of the session after the command, when the helper reported it.
    let playingAfter: Bool?

    /// Reads the answer of the helper.
    init?(json: String) {
        let text = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        action = object["action"] as? String ?? ""
        result = object["result"] as? String ?? ""
        reason = object["reason"] as? String
        playingAfter = object["playingAfter"].flatMap { SettingsValue.from(json: $0).boolValue }
        guard let bundle = object["bundleIdentifier"] as? String, !bundle.isEmpty else {
            session = nil
            return
        }
        // The state of the session has to be known: an unknown state is never
        // a paused media, so such an answer carries no session at all.
        guard let rawPlaying = object["playing"],
              let playing = SettingsValue.from(json: rawPlaying).boolValue else {
            session = nil
            return
        }
        let rawParent = object["parentApplicationBundleIdentifier"] as? String
        let parent = rawParent.flatMap { $0.isEmpty ? nil : $0 }
        let process: Int?
        if let rawProcess = object["processIdentifier"],
           case .int(let identifier) = SettingsValue.from(json: rawProcess) {
            process = Int(exactly: identifier)
        } else { process = nil }
        let item = object["mediaItemIdentifier"] as? String
        session = SystemMediaSession(bundleIdentifier: bundle,
                                     parentApplicationBundleIdentifier: parent,
                                     processIdentifier: process,
                                     mediaItemIdentifier: item,
                                     isPlaying: playing)
    }
}

/// The transport of the production backend.
///
/// An isolated run — a smoke test, a lifecycle test, a GUI check — never
/// touches the media of the system: it reads no session and sends no
/// command. A break that runs in a test therefore cannot change what plays on
/// the machine of the user, and the tests of the rules use an injected
/// transport instead.
enum MediaSessionTransport {
    /// The source of the media session of the system.
    static func make(isIsolatedRun: Bool = AppPaths.isIsolatedRun) -> SystemMediaSessionSource {
        MediaRemoteSessionSource(isDryRun: isIsolatedRun)
    }
}

/// Collects the output of a process without a race between the reader and the
/// reader of the result. The output is bounded: a helper that writes
/// endlessly never fills the memory of the application.
final class OutputCollector {
    /// The most output that is kept.
    static let limit = 1 << 20

    private let lock = NSLock()
    private var data = Data()

    /// Drain in fixed chunks; truncating after readDataToEndOfFile would still
    /// allocate the helper's whole output before applying the storage bound.
    func drain(_ handle: FileHandle) {
        while let chunk = try? handle.read(upToCount: 4_096), !chunk.isEmpty {
            append(chunk)
        }
    }

    /// Adds a piece of the output.
    func append(_ piece: Data) {
        guard !piece.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let room = OutputCollector.limit - data.count
        guard room > 0 else { return }
        data.append(piece.prefix(room))
    }

    /// The whole output.
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The first line of the output, without the line break.
    var firstLine: String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let line = lines.first else { return "" }
        return String(line.prefix(200))
    }
}
