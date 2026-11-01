import Foundation
import ServiceManagement
import CaesuraCore

/// Login item via SMAppService (legacy app.setLoginItemSettings / auto-launch).
final class LoginItemManager {
    enum Status: String {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound
        case unknown
    }

    static func currentStatus() -> Status {
        guard #available(macOS 13.0, *) else { return .unknown }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.info("Caesura: setting autostart to \(enabled) on darwin")
            return true
        } catch {
            Log.error("Caesura: autostart change failed: \(error)")
            return false
        }
    }
}
