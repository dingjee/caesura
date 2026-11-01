import AppKit
import CaesuraCore

/// Suspend/lock monitoring (legacy powerMonitor suspend/lock-screen/resume/unlock-screen).
final class SleepMonitor {
    var onSuspendOrLock: (() -> Void)?
    var onResumeOrUnlock: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        // AppKit has no public lock/unlock notification; loginwindow's long-standing
        // distributed notifications are the de-facto mechanism (same as many menu bar
        // apps). Note this honestly: they are undocumented Apple behavior.
        observers.append(DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Log.info("System: lock")
            self?.onSuspendOrLock?()
        })
        observers.append(DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Log.info("System: unlock")
            self?.onResumeOrUnlock?()
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Log.info("System: suspend")
            self?.onSuspendOrLock?()
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Log.info("System: screens slept")
            self?.onSuspendOrLock?()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Log.info("System: resume")
            self?.onResumeOrUnlock?()
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onResumeOrUnlock?()
        })
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
            DistributedNotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }
}
