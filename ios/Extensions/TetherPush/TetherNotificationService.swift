// TetherPush — UNNotificationServiceExtension (mutable-content alert push).
// Primary server->device path: apply the new policy while the app is not running, then
// rewrite the visible text. ~30 s budget. VERIFY: spike S2 — ManagedSettingsStore writes
// from an NSE (needs the family-controls entitlement on this extension).

import Foundation
import UserNotifications
import TetherCore
import TetherAPI
import TetherKit

class TetherNotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?
    private var delivered = false
    private let lock = NSLock()

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.bestAttempt = content
        let userInfo = request.content.userInfo

        Task { [weak self] in
            let before = Reconciler.shared.snapshot()
            _ = await PlatformSync.shared.handlePush(userInfo)
            // Reconcile again even if the sync reported no change: cheap, idempotent, and
            // guarantees the stores match the latest state before we return.
            let after = Reconciler.shared.reconcile()
            if let summary = PushSummary.make(before: before, after: after) {
                content.body = summary
            }
            self?.deliver(content)
        }
    }

    /// Time budget nearly exhausted: deliver whatever we have (the Monitor/app will reconcile later).
    override func serviceExtensionTimeWillExpire() {
        if let content = bestAttempt { deliver(content) }
    }

    private func deliver(_ content: UNNotificationContent) {
        lock.lock(); defer { lock.unlock() }
        guard !delivered, let handler = contentHandler else { return }
        delivered = true
        handler(content)
    }
}
