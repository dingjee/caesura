import CoreGraphics
import Foundation
import CaesuraCore

/// Idle time via CoreGraphics (legacy used powerMonitor.getSystemIdleTime /
/// node-desktop-idle). Polls on the legacy `naturalBreaksCheckInterval`.
final class IdleMonitor {
    private var timer: DispatchSourceTimer?
    private let settings: SettingsStore
    var onUpdate: ((Int64) -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    static func systemIdleMillis() -> Int64 {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return Int64(max(0, seconds) * 1000)
    }

    func start() {
        guard timer == nil else { return }
        Log.info("Caesura: starting Idle time monitoring")
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        source.schedule(deadline: .now(),
                        repeating: DispatchTimeInterval.milliseconds(Int(settings.getMillis("naturalBreaksCheckInterval"))))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let idle = Self.systemIdleMillis()
            DispatchQueue.main.async { self.onUpdate?(idle) }
        }
        source.resume()
        timer = source
    }

    func stop() {
        guard timer != nil else { return }
        Log.info("Caesura: stopping Idle time monitoring")
        timer?.cancel()
        timer = nil
    }
}
