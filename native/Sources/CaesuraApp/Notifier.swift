import Foundation
import AppKit
import UserNotifications
import CaesuraCore

/// Native notifications via UNUserNotificationCenter (legacy used the HTML
/// Notification API in the process window). Authorization is requested on first use;
/// outcomes are logged and never faked.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Pending auto-dismiss work items, keyed by the notification identifier.
    private var dismissals: [String: DispatchWorkItem] = [:]
    private let dismissalLock = NSLock()

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
    }

    /// Requests authorization (alert + sound). Returns granted state via completion.
    func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.error("Caesura: notification authorization error: \(error)")
            } else {
                Log.info("Caesura: notification authorization granted: \(granted)")
            }
            DispatchQueue.main.async { completion?(granted) }
        }
    }

    /// Asks for notification permission once, but only when the user has not decided
    /// yet. The user is never asked when notifications are switched off.
    func requestAuthorizationIfNeeded(silentNotifications: Bool) {
        guard !silentNotifications else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else {
                Log.info("Caesura: notification authorization status: \(settings.authorizationStatus.rawValue)")
                return
            }
            Log.info("Caesura: asking for notification authorization")
            self.requestAuthorization()
        }
    }

    /// The name of the notification that opens the preferences of the app.
    static let openPreferencesNotification = Notification.Name("CaesuraOpenPreferences")

    /// Shows a notification.
    ///
    /// `openURL` opens a link when the notification is clicked, `openPreferences`
    /// opens the preferences of the app.
    func show(text: String, silent: Bool, identifier: String = UUID().uuidString,
              openURL: String? = nil, openPreferences: Bool = false,
              autoDismissAfter seconds: TimeInterval? = 7) {
        let content = UNMutableNotificationContent()
        content.body = text
        if !silent {
            content.sound = .default
        }
        if let openURL {
            content.userInfo = ["openURL": openURL]
        }
        if openPreferences {
            content.userInfo = (content.userInfo ?? [:]).merging(["openPreferences": true]) { _, new in new }
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.error("Caesura: notification failed: \(error)")
            } else {
                Log.info("Caesura: showing notification \"\(text)\" (silent: \(silent))")
            }
        }
        if let seconds {
            scheduleRemoval(of: identifier, after: seconds)
        }
    }

    /// Removes the delivered notification again after `seconds`. The original request is
    /// removed from the notification centre — no second notification is created.
    private func scheduleRemoval(of identifier: String, after seconds: TimeInterval) {
        dismissalLock.lock()
        dismissals[identifier]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
            self?.dismissalLock.lock()
            self?.dismissals[identifier] = nil
            self?.dismissalLock.unlock()
            Log.info("Caesura: dismissed notification \(identifier)")
        }
        dismissals[identifier] = item
        dismissalLock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Cancels every pending auto-dismissal (application shutdown).
    func cancelPendingDismissals() {
        dismissalLock.lock()
        let pending = dismissals
        dismissals.removeAll()
        dismissalLock.unlock()
        for (_, item) in pending {
            item.cancel()
        }
    }

    func show(localizedKey: String, localization: Localization, silent: Bool,
              options: [String: Any] = [:], openURL: String? = nil) {
        show(text: localization.t(localizedKey, options: options), silent: silent, openURL: openURL)
    }

    // Show in foreground too (menu bar app has no other surface).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if info["openPreferences"] as? Bool == true {
            NotificationCenter.default.post(name: Self.openPreferencesNotification, object: nil)
        }
        if let url = info["openURL"] as? String, url.hasPrefix("https://") {
            NSWorkspace.shared.open(URL(string: url)!)
        }
        completionHandler()
    }
}
