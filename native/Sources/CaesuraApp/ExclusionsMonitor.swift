import Foundation
import CaesuraCore

/// Process list snapshot for app-exclusion matching (legacy used ps-list).
/// Uses libproc's proc_listallpids + proc_pidpath and reads the full command line
/// (legacy `ps-list` returned the `cmd` of every process); returns an empty snapshot
/// when the kernel refuses — exclusions then never match, which is logged.
enum ProcessList {
    static func snapshot() -> [ProcessSnapshotEntry] {
        let size = proc_listallpids(nil, 0 as Int32)
        guard size > 0 else {
            Log.warn("Caesura: proc_listallpids returned \(size); exclusion matching unavailable")
            return []
        }
        var pids = [pid_t](repeating: 0, count: Int(size) + 24) // headroom for races
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        var entries: [ProcessSnapshotEntry] = []
        entries.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            var path: String?
            if proc_pidpath(pid, &pathBuffer, UInt32(MAXPATHLEN)) > 0 {
                path = String(cString: pathBuffer)
            }
            if path == nil {
                var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 2)
                if proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 {
                    path = String(cString: nameBuffer)
                }
            }
            guard let processPath = path else { continue }
            let executable = URL(fileURLWithPath: processPath).lastPathComponent
            // The full command line (legacy `cmd`); the executable path is the
            // fallback when the arguments cannot be read.
            let commandLine = commandLine(for: pid) ?? processPath
            entries.append(ProcessSnapshotEntry(name: executable, command: commandLine))
        }
        return entries
    }

    /// Reads the argument vector of a process via `KERN_PROCARGS2`.
    /// Returns nil when the process belongs to another user or is gone.
    static func commandLine(for pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        // The buffer starts with the executable path (NUL terminated), followed by the
        // argument count and the NUL terminated arguments.
        var offset = 0
        while offset < buffer.count, buffer[offset] != 0 { offset += 1 }
        guard offset < buffer.count else { return nil }
        offset += 1
        offset = (offset + 3) & ~3 // align to 4 bytes
        guard offset + 4 <= buffer.count else { return nil }
        let argumentCount = Int(buffer.withUnsafeBytes { raw -> Int32 in
            raw.loadUnaligned(fromByteOffset: offset, as: Int32.self)
        })
        offset += 4
        var arguments: [String] = []
        for _ in 0..<max(0, argumentCount) {
            var bytes: [UInt8] = []
            while offset < buffer.count {
                let byte = buffer[offset]
                offset += 1
                if byte == 0 { break }
                bytes.append(UInt8(bitPattern: byte))
            }
            arguments.append(String(decoding: bytes, as: UTF8.self))
        }
        guard !arguments.isEmpty else { return nil }
        return arguments.joined(separator: " ")
    }
}

/// Polls the process list; the coordinator performs matching via the planner's
/// exclusion state machine and feeds `applyExclusion`.
final class ExclusionsMonitor {
    private var timer: DispatchSourceTimer?
    private let settings: SettingsStore
    var onSnapshot: (([ProcessSnapshotEntry]) -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// Legacy only monitors the process list when an exclusion rule is active.
    private var hasActiveRule: Bool {
        for entry in settings.getArray("appExclusions") {
            guard let object = entry.objectValue,
                  object["active"]?.boolValue == true,
                  object["rule"]?.stringValue != nil else { continue }
            return true
        }
        return false
    }

    func start() {
        guard timer == nil else { return }
        guard hasActiveRule else {
            Log.info("Caesura: no active app exclusion rule, not monitoring processes")
            return
        }
        Log.info("Caesura: starting App exclusions monitoring")
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        source.schedule(deadline: .now(),
                        repeating: DispatchTimeInterval.milliseconds(Int(max(500, settings.getMillis("appExclusionsCheckInterval")))))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let processes = ProcessList.snapshot()
            DispatchQueue.main.async { self.onSnapshot?(processes) }
        }
        source.resume()
        timer = source
    }

    func stop() {
        guard timer != nil else { return }
        Log.info("Caesura: stopping App exclusions monitoring")
        timer?.cancel()
        timer = nil
    }
}
