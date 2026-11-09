#if os(iOS) && canImport(ManagedSettings)
import Foundation
import FamilyControls
import TetherCore

public struct ReconcileResult: Sendable {
    public var reconciledAt: Date
    public var states: [GroupID: GroupState]
    /// Sorted ids of groups that are blocked right now.
    public var blockedGroupIds: [GroupID]
    /// Earliest future moment at which any group may change state.
    public var nextTransition: Date?
    public var protectionEnabled: Bool
    public var timeZone: TimeZone

    public static func empty(at now: Date) -> ReconcileResult {
        ReconcileResult(reconciledAt: now, states: [:], blockedGroupIds: [], nextTransition: nil,
                        protectionEnabled: false, timeZone: .current)
    }
}

/// The one function every process calls (ARCHITECTURE §1). Synchronous, cheap, no network,
/// no UIKit: safe from the app, Monitor, ShieldAction and the notification service extension.
/// Shields apply before it returns; DeviceActivity scheduling is queued (see `ActivityScheduler.queue`).
public final class Reconciler: @unchecked Sendable {
    public static let shared = Reconciler()

    private let lock = NSLock()   // serialises reconciles inside one process
    private let directoryOverride: URL?

    public init(directory: URL? = nil) { self.directoryOverride = directory }

    private var directory: URL { directoryOverride ?? AppGroup.containerURL }
    private func makeStore() -> StateStore { StateStore(directory: directory) }

    // MARK: Reconcile

    @discardableResult
    public func reconcile(now: Date = Date()) -> ReconcileResult {
        lock.lock(); defer { lock.unlock() }

        let store = makeStore()
        let state: PersistedState
        do { state = try store.load() }
        catch {
            // Corrupt/unreadable state: leave whatever shields are installed untouched.
            TLog.reconcile.error("state load failed, reconcile skipped: \(String(describing: error))")
            return .empty(at: now)
        }

        let pruned = state.pruned(now: now)
        let input = pruned.engineInput
        let tz = PolicyEngine.effectiveTimeZone(input, deviceTimeZone: .current)
        let selectionStore = SelectionStore(directory: directory)
        if let groups = pruned.bundle?.groups {
            let plans = CopyPlanner.copies(bundleGroups: groups, localGroupIds: Set(pruned.localGroups.map(\.id)),
                                           applied: selectionStore.appliedCopies())
            if !plans.isEmpty { selectionStore.applyCopies(plans) }
        }
        let selections = selectionStore.all()
        let shield = ShieldApplier()
        let tamper = TamperLock()
        let scheduler = ActivityScheduler(directory: directory)

        var states: [GroupID: GroupState] = [:]
        var transitions: [Date] = []

        if pruned.protection.enabled {
            let raw = PolicyEngine.evaluate(input, at: now, timeZone: tz)
            transitions = TransitionPlanner.nextTransitions(input, after: now, timeZone: tz)
            states = TransitionPlanner.annotateUntil(raw, input: input, now: now, timeZone: tz)

            shield.apply(states, groups: input.allGroups, selections: selections,
                         input: input, timeZone: tz, now: now)
            tamper.setDenyAppRemoval(pruned.bundle?.settings.denyAppRemoval ?? true)
            scheduler.schedule(transitions: transitions,
                               usageRules: Self.usageRules(in: input),
                               selections: selections, timeZone: tz, now: now)
        } else {
            // Protection off: nothing blocks, nothing is locked, nothing is scheduled.
            states = PolicyEngine.evaluate(input, at: now, timeZone: tz).mapValues { s in
                var c = s; c.blocked = false; c.until = nil; return c
            }
            shield.clearAll()
            tamper.setDenyAppRemoval(false)
            scheduler.stopAll()
        }

        do {
            _ = try store.update { s in
                s.prune(now: now)
                s.lastReconciledAt = now
            }
        } catch {
            TLog.reconcile.error("persist lastReconciledAt failed: \(String(describing: error))")
        }

        let blocked = states.values.filter { $0.blocked }.map { $0.groupId }.sorted()
        TLog.reconcile.info("reconciled: \(blocked.count) blocked, next=\(transitions.first.map { "\($0)" } ?? "none")")
        return ReconcileResult(reconciledAt: now, states: states, blockedGroupIds: blocked,
                               nextTransition: transitions.first,
                               protectionEnabled: pruned.protection.enabled, timeZone: tz)
    }

    // MARK: Read-only evaluation (no side effects)

    /// Evaluates the current state without touching any ManagedSettings store or schedule.
    /// Used to diff before/after a push for the notification summary.
    public func snapshot(now: Date = Date()) -> ReconcileResult {
        guard let state = try? makeStore().load() else { return .empty(at: now) }
        let input = state.pruned(now: now).engineInput
        let tz = PolicyEngine.effectiveTimeZone(input, deviceTimeZone: .current)
        let transitions = TransitionPlanner.nextTransitions(input, after: now, timeZone: tz)
        var states = TransitionPlanner.annotateUntil(PolicyEngine.evaluate(input, at: now, timeZone: tz),
                                                     input: input, now: now, timeZone: tz)
        if !state.protection.enabled {
            states = states.mapValues { var c = $0; c.blocked = false; c.until = nil; return c }
        }
        return ReconcileResult(reconciledAt: now, states: states,
                               blockedGroupIds: states.values.filter { $0.blocked }.map { $0.groupId }.sorted(),
                               nextTransition: transitions.first, protectionEnabled: state.protection.enabled,
                               timeZone: tz)
    }

    // MARK: Usage limit (called by the Monitor extension)

    /// Records that `ruleId`'s daily threshold was reached today and queues a
    /// `usageLimitReached` event. Idempotent per (rule, day).
    public func recordUsageLimitHit(ruleId: RuleID, now: Date = Date()) {
        let store = makeStore()
        do {
            _ = try store.update { s in
                let tz = PolicyEngine.effectiveTimeZone(s.engineInput, deviceTimeZone: .current)
                s.recordUsageLimitHit(ruleId: ruleId, now: now, timeZone: tz)
            }
        } catch {
            TLog.reconcile.error("recordUsageLimitHit failed: \(String(describing: error))")
        }
    }

    // MARK: Helpers

    /// Enabled block rules with a usage-limit trigger that apply on this device.
    static func usageRules(in input: EngineInput) -> [Rule] {
        let allowLocal = input.bundle?.settings.allowLocalRules ?? true
        let rules = (input.bundle?.rules ?? []) + (allowLocal ? input.localRules : [])
        return rules.filter { r in
            guard r.enabled, r.action == .block else { return false }
            if case .usageLimit = r.trigger { return true }
            return false
        }
    }
}
#endif
