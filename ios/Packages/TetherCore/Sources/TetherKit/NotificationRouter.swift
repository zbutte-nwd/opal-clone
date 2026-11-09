#if os(iOS) && canImport(ManagedSettings)
import Foundation
import UserNotifications
import TetherCore

/// Local notifications posted from extensions. ShieldAction cannot open the app, so the
/// "Unlock for 5 min" button posts a notification whose tap opens `tether://pause?group=<id>`.
/// The app (W6) must register the same category and, in its
/// `UNUserNotificationCenterDelegate`, open `userInfo["url"]` on tap.
public enum NotificationRouter {
    public static let pauseCategory = "tether.pause"
    public static let urlKey = "url"

    public static func pauseURL(groupId: GroupID) -> URL {
        var c = URLComponents()
        c.scheme = "tether"; c.host = "pause"
        c.queryItems = [URLQueryItem(name: "group", value: groupId)]
        return c.url ?? URL(string: "tether://pause")!
    }

    /// Call at app launch (the app) so the category exists. Safe to call repeatedly.
    public static func registerCategories(center: UNUserNotificationCenter = .current()) {
        let category = UNNotificationCategory(identifier: pauseCategory, actions: [],
                                              intentIdentifiers: [], options: [])
        center.getNotificationCategories { existing in
            var all = existing.filter { $0.identifier != pauseCategory }
            all.insert(category)
            center.setNotificationCategories(all)
        }
    }

    /// Posts the "Tap to pause" notification. `completion` runs after the system has
    /// accepted (or rejected) the request — a ShieldAction extension must wait for it
    /// before calling its own completion handler, or the process may be suspended first.
    /// VERIFY: spike S3 (extension may post only if the app was granted notification
    /// authorization; extensions cannot request it).
    public static func postPauseNotification(groupId: GroupID, groupName: String?,
                                             completion: @escaping @Sendable () -> Void) {
        let content = UNMutableNotificationContent()
        content.title = "Unlock \(groupName ?? "this app") for 5 min?"
        content.body = "Tap to open Tether and start a short pause."
        content.categoryIdentifier = pauseCategory
        content.userInfo = [urlKey: pauseURL(groupId: groupId).absoluteString]
        content.sound = nil
        content.threadIdentifier = "tether.pause"
        content.interruptionLevel = .active

        // Same identifier per group: repeated taps replace instead of piling up.
        let request = UNNotificationRequest(identifier: "tether.pause.\(groupId)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { TLog.shield.error("pause notification failed: \(String(describing: error))") }
            completion()
        }
    }
}
#endif
