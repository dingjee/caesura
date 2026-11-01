import Foundation
import CaesuraCore

/// Polls the macOS Focus heuristic (see FocusHeuristic for the honest limitation:
/// menu-bar Focus item visibility, not verified Focus status). Legacy
/// `monitorDndCheckInterval` cadence.
final class FocusMonitor {
    private var timer: DispatchSourceTimer?
    private let heuristic: FocusHeuristic
    var onUpdate: ((Bool) -> Void)?

    init(heuristic: FocusHeuristic = FocusHeuristic()) {
        self.heuristic = heuristic
    }

    func start(checkIntervalMillis: Int64) {
        guard timer == nil else { return }
        Log.info("Caesura: starting Do Not Disturb monitoring")
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        source.schedule(deadline: .now(), repeating: DispatchTimeInterval.milliseconds(Int(max(500, checkIntervalMillis))))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let enabled = self.heuristic.isDoNotDisturbEnabled() // nil = unknown: keep state
            DispatchQueue.main.async {
                if let enabled {
                    self.onUpdate?(enabled)
                }
            }
        }
        source.resume()
        timer = source
    }

    func stop() {
        guard timer != nil else { return }
        Log.info("Caesura: stopping Do Not Disturb monitoring")
        timer?.cancel()
        timer = nil
    }
}
