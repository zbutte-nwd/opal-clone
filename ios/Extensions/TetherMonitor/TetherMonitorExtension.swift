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
        // A one-shot `tether.t.<epoch>` wake exists to apply the state change AT that instant.
        // If the OS delivers it a moment early, evaluate at the transition itself; otherwise the
        // engine would still see the old state, the transition would stay "in the future", and the
        // unchanged activity would not be re-registered -> the change would be missed.
        var now = Date()
        if let t = ActivityScheduler.transitionDate(fromActivity: activity.rawValue), t > now,
           t.timeIntervalSince(now) < 120 {
            now = t
        }
        Reconciler.shared.reconcile(now: now)
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
