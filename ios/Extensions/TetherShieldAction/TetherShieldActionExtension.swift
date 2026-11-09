// TetherShieldAction — ShieldActionDelegate extension.
// A shield action can only answer .close / .defer / .none; it CANNOT open the app.
//   primary   ("Close")              -> .close
//   secondary ("Unlock for 5 min")   -> post a local notification "Tap to pause" whose tap
//                                       opens tether://pause?group=<id>, then .defer
// VERIFY: spike S3 — that an extension may post the notification and that the tap deep-links.

import ManagedSettings
import ManagedSettingsUI
import Foundation
import TetherKit

class TetherShieldActionExtension: ShieldActionDelegate {

    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        // No direct entry -> shielded through a category (the configuration extension showed the
        // category's copy and an "Unlock" button), so resolve it the same way.
        respond(action, entry: ShieldContextStore.entry(for: application) ?? ShieldContextStore.categoryFallbackEntry(),
                completionHandler)
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        // No direct entry -> shielded through a category (the configuration extension showed the
        // category's copy and an "Unlock" button), so resolve it the same way.
        respond(action, entry: ShieldContextStore.entry(for: webDomain) ?? ShieldContextStore.categoryFallbackEntry(),
                completionHandler)
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        respond(action, entry: ShieldContextStore.entry(for: category), completionHandler)
    }

    private func respond(_ action: ShieldAction, entry: ShieldContextEntry?,
                         _ completionHandler: @escaping (ShieldActionResponse) -> Void) {
        switch action {
        case .primaryButtonPressed:
            completionHandler(.close)
        case .secondaryButtonPressed:
            guard let entry, !entry.strict else { completionHandler(.close); return }
            // Empty groupId (ambiguous category fallback) -> tether://pause?group= -> the pause flow
            // offers every blocked group.
            NotificationRouter.postPauseNotification(groupId: entry.groupId,
                                                     groupName: entry.groupId.isEmpty ? nil : entry.groupName) {
                // Wait for the system to accept the request before the process can be suspended.
                completionHandler(.defer)
            }
        @unknown default:
            completionHandler(.none)
        }
    }
}
