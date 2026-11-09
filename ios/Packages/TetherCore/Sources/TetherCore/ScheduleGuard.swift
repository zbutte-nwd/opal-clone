// ScheduleGuard.swift — pure decisions for the guarded/strict edit lock (spec 2026-11-09, plan Task 3).
// The engine treats guarded like flexible; this is the app-side lock: while a guarded or strict block
// rule is active, changes that touch it or would unblock what it blocks need the ProtectionLock.

import Foundation

public enum GuardDecision: Equatable, Sendable {
    case allowed
    case locked(reason: String)
}

public enum ScheduleGuard {

    /// Gate for a change to rules/groups, given the engine input before and after it.
    /// `.locked` when (a) a guarded/strict block rule that is active in `before` is changed in any field or
    /// removed, or (b) evaluating both sides with temporary unblocks (active pauses, active `unblock`
    /// overrides) stripped shows a group of such a rule blocked before and not after. Stripping matters:
    /// otherwise an allow rule added during a pause would pass and outlive the pause.
    public static func ruleChange(before: EngineInput, after: EngineInput, at now: Date, timeZone: TimeZone) -> GuardDecision {
        let locking = activeLockingRules(before, at: now, timeZone: timeZone)
        guard !locking.isEmpty else { return .allowed }

        var afterRules: [RuleID: Rule] = [:]
        for r in (after.bundle?.rules ?? []) + after.localRules where afterRules[r.id] == nil { afterRules[r.id] = r }
        for r in locking where afterRules[r.id] != r { return .locked(reason: message(r)) }

        let b = PolicyEngine.evaluate(stripTemporaryUnblocks(before, at: now), at: now, timeZone: timeZone)
        let a = PolicyEngine.evaluate(stripTemporaryUnblocks(after, at: now), at: now, timeZone: timeZone)
        for r in locking {
            for g in r.groupIds where b[g]?.blocked == true && a[g]?.blocked != true {
                return .locked(reason: message(r))
            }
        }
        return .allowed
    }

    /// May `groupId` lose apps/categories/sites right now? Locked (true) when it belongs to an active
    /// guarded/strict block rule (local or server; pauses don't unlock it), or is covered now by a strict
    /// focus session or a server block override.
    public static func isShrinkLocked(groupId: GroupID, _ input: EngineInput, at now: Date, timeZone: TimeZone) -> Bool {
        if activeLockingRules(input, at: now, timeZone: timeZone).contains(where: { $0.groupIds.contains(groupId) }) { return true }
        if input.sessions.contains(where: { $0.strict && $0.groupIds.contains(groupId) && $0.isActive(at: now) }) { return true }
        return (input.bundle?.overrides ?? []).contains {
            $0.action == .block && $0.groupIds.contains(groupId) && $0.isActive(at: now)
        }
    }

    /// The first active guarded/strict block rule that references `groupId`, for messages.
    public static func lockingRule(for groupId: GroupID, _ input: EngineInput, at now: Date, timeZone: TimeZone) -> Rule? {
        activeLockingRules(input, at: now, timeZone: timeZone).first { $0.groupIds.contains(groupId) }
    }

    // MARK: Helpers

    static func activeLockingRules(_ input: EngineInput, at now: Date, timeZone: TimeZone) -> [Rule] {
        PolicyEngine.effectiveRules(input).filter {
            $0.action == .block && $0.strictness.isLocking && PolicyEngine.isRuleActive($0, input, at: now, timeZone: timeZone)
        }
    }

    static func stripTemporaryUnblocks(_ input: EngineInput, at now: Date) -> EngineInput {
        var i = input
        i.pauses.removeAll { $0.startsAt <= now && now < $0.endsAt }
        i.bundle?.overrides.removeAll { $0.action == .unblock && $0.isActive(at: now) }
        return i
    }

    static func message(_ r: Rule) -> String {
        "“\(r.name)” is active (\(r.strictness.rawValue)), so it can't be changed until it ends."
    }
}

extension Override {
    func isActive(at now: Date) -> Bool { startsAt <= now && (endsAt == nil || now < endsAt!) }
}

extension FocusSession {
    func isActive(at now: Date) -> Bool { startsAt <= now && now < endsAt && (endedAt == nil || now < endedAt!) }
}
