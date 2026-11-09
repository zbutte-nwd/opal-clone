// TetherMonitor — DeviceActivityMonitor extension.
// The OS launches this process at DeviceActivity schedule boundaries and usage thresholds,
// even when the app is not running. Hard rules: NO networking, tiny memory (~6 MB cap,
// VERIFY spike S6), and every callback just runs the same idempotent reconcile.

import DeviceActivity
import Foundation
import TetherCore
import TetherKit

class TetherMonitorExtension: DeviceActivityMonitor {

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        Reconciler.shared.reconcile(now: Date())
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        Reconciler.shared.reconcile(now: Date())
    }

    /// Fired when a `tether.usage.<ruleId>` activity's `limit` event reaches its threshold.
    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        let now = Date()
        if event.rawValue == ActivityScheduler.usageEventName,
           let ruleId = ActivityScheduler.ruleId(fromActivity: activity.rawValue) {
            Reconciler.shared.recordUsageLimitHit(ruleId: ruleId, now: now)
        }
        Reconciler.shared.reconcile(now: now)
    }
}
