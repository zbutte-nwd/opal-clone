// PolicyEngine.swift — pure function: (EngineInput, time, tz) -> per-group block state.
// Implements docs/ARCHITECTURE.md §3 exactly (mirrored by contracts/engine-vectors.json).
//
// Cost: O(groups × (rules + sessions + overrides + pauses)); the set of *active* rules,
// sessions, overrides and pauses is computed once per call, so the per-group work only
// scans short filtered lists. Safe to run in the 6 MB Monitor extension.

import Foundation

public enum PolicyEngine {

    // MARK: Public API

    /// Evaluates every known group (`input.allGroups`, and only those) at `now`.
    public static func evaluate(_ input: EngineInput, at now: Date, timeZone: TimeZone) -> [GroupID: GroupState] {
        let ctx = Context(input, now: now, timeZone: timeZone)
        var out: [GroupID: GroupState] = [:]
        for g in input.allGroups { out[g.id] = ctx.resolve(g.id).state }
        return out
    }

    /// The bundle's IANA zone if it parses, otherwise the device zone.
    public static func effectiveTimeZone(_ input: EngineInput, deviceTimeZone: TimeZone) -> TimeZone {
        if let id = input.bundle?.timeZone, let tz = TimeZone(identifier: id) { return tz }
        return deviceTimeZone
    }

    /// Can the user pause (temporarily unblock) `groupId` right now?
    /// - `.notBlocked`: nothing to pause.
    /// - `.strict`: strict rule/session or a server block override — never pausable.
    /// - `.budgetExhausted(limit:)`: the blocking rule's `maxPausesPerDay` is used up today.
    public static func canPause(groupId: GroupID, _ input: EngineInput, at now: Date, timeZone: TimeZone) -> PauseEligibility {
        let ctx = Context(input, now: now, timeZone: timeZone)
        let r = ctx.resolve(groupId)
        guard r.state.blocked else { return .notBlocked }
        if r.state.strict { return .strict }
        if r.state.reason.kind == .rule, let rid = r.state.reason.id,
           let rule = ctx.rulesById[rid], let limit = rule.maxPausesPerDay {
            let used = input.pauses.reduce(0) { n, p in
                guard p.ruleId == rid,
                      ScheduleMath.dayString(p.startsAt, in: timeZone) == ctx.moment.day else { return n }
                return n + 1
            }
            if used >= limit { return .budgetExhausted(limit: limit) }
        }
        return .allowed
    }

    /// §3 step 3: is `rule` in force at `now`? True iff it is enabled, counts for this input (local rules
    /// are ignored when `allowLocalRules == false`) and its trigger is active (schedule window, manual mode
    /// on, usage limit hit today). The single source of truth for both `evaluate` and the app's ScheduleGuard.
    public static func isRuleActive(_ rule: Rule, _ input: EngineInput, at now: Date, timeZone: TimeZone) -> Bool {
        guard effectiveRules(input).contains(where: { $0.id == rule.id }) else { return false }
        return isTriggerActive(rule, input.usageLimitHits, at: ScheduleMath.localMoment(now, in: timeZone))
    }

    static func isTriggerActive(_ r: Rule, _ hits: [UsageLimitHit], at m: ScheduleMath.LocalMoment) -> Bool {
        guard r.enabled else { return false }
        switch r.trigger {
        case .schedule(let windows): return ScheduleMath.isAnyActive(windows, at: m)
        case .manual(let on): return on
        case .usageLimit(_, let days):
            return days.contains(m.isoWeekday) && hits.contains(where: { $0.ruleId == r.id && $0.day == m.day })
        }
    }

    // MARK: Shared helpers (also used by TransitionPlanner)

    /// Bundle rules followed by local rules (local ignored when `allowLocalRules == false`).
    static func effectiveRules(_ input: EngineInput) -> [Rule] {
        let bundleRules = input.bundle?.rules ?? []
        let allowLocal = input.bundle?.settings.allowLocalRules ?? true
        return allowLocal ? bundleRules + input.localRules : bundleRules
    }

    /// Equality of the parts of a state that matter for transitions (ignores `until`).
    static func sameState(_ a: GroupState?, _ b: GroupState?) -> Bool {
        guard let a = a, let b = b else { return a == nil && b == nil }
        return a.blocked == b.blocked && a.strict == b.strict && a.reason == b.reason
    }

    static func sameStates(_ a: [GroupID: GroupState], _ b: [GroupID: GroupState]) -> Bool {
        if a.count != b.count { return false }
        for (k, v) in a where !sameState(v, b[k]) { return false }
        return true
    }

    // MARK: Evaluation context

    private struct Resolution { var state: GroupState }

    private struct Context {
        let now: Date
        let moment: ScheduleMath.LocalMoment
        let activeRules: [Rule]
        let rulesById: [RuleID: Rule]
        let overrides: [Override]
        let sessions: [FocusSession]
        let pauses: [Pause]

        init(_ input: EngineInput, now: Date, timeZone: TimeZone) {
            self.now = now
            let m = ScheduleMath.localMoment(now, in: timeZone)
            self.moment = m
            let rules = PolicyEngine.effectiveRules(input)
            var byId: [RuleID: Rule] = [:]
            for r in rules where byId[r.id] == nil { byId[r.id] = r }
            self.rulesById = byId

            self.activeRules = rules.filter { PolicyEngine.isTriggerActive($0, input.usageLimitHits, at: m) }
            self.overrides = (input.bundle?.overrides ?? []).filter {
                $0.startsAt <= now && ($0.endsAt == nil || now < $0.endsAt!)
            }
            self.sessions = input.sessions.filter {
                $0.startsAt <= now && now < $0.endsAt && ($0.endedAt == nil || now < $0.endedAt!)
            }
            self.pauses = input.pauses.filter { $0.startsAt <= now && now < $0.endsAt }
        }

        func resolve(_ g: GroupID) -> Resolution {
            // 1. Server overrides: latest issuedAt wins (tie: larger id). Supreme precedence.
            var ov: Override?
            for o in overrides where o.groupIds.contains(g) {
                if let cur = ov {
                    if o.issuedAt > cur.issuedAt || (o.issuedAt == cur.issuedAt && o.id > cur.id) { ov = o }
                } else { ov = o }
            }
            if let o = ov {
                let block = o.action == .block
                return Resolution(state: GroupState(groupId: g, blocked: block, strict: block,
                                                    reason: Reason(kind: .override, id: o.id)))
            }

            // 3 (pre). Winning rule among the active ones: max priority; block beats allow;
            // blocks: strict first then smallest id; allows: smallest id.
            var top: [Rule] = []
            var topPriority = Int.min
            for r in activeRules where r.groupIds.contains(g) {
                if r.priority > topPriority { topPriority = r.priority; top = [r] }
                else if r.priority == topPriority { top.append(r) }
            }
            var winner: Rule?
            if !top.isEmpty {
                let blocks = top.filter { $0.action == .block }
                if !blocks.isEmpty {
                    winner = blocks.min { a, b in
                        let sa = a.strictness == .strict, sb = b.strictness == .strict
                        if sa != sb { return sa }
                        return a.id < b.id
                    }
                } else {
                    winner = top.min { $0.id < $1.id }
                }
            }

            // 2. Focus sessions.
            var candidate: GroupState?
            let ses = sessions.filter { $0.groupIds.contains(g) }
            if !ses.isEmpty {
                let strictOnes = ses.filter { $0.strict }
                let chosen: FocusSession
                if let s = strictOnes.min(by: { $0.id < $1.id }) { chosen = s }
                else { chosen = ses.min { ($0.endsAt, $0.id) < ($1.endsAt, $1.id) }! }
                let ruleStrict = winner.map { $0.action == .block && $0.strictness == .strict } ?? false
                candidate = GroupState(groupId: g, blocked: true, strict: !strictOnes.isEmpty || ruleStrict,
                                       reason: Reason(kind: .session, id: chosen.id))
            } else if let w = winner {
                if w.action == .allow {
                    return Resolution(state: GroupState(groupId: g, blocked: false, strict: false,
                                                        reason: Reason(kind: .rule, id: w.id)))
                }
                candidate = GroupState(groupId: g, blocked: true, strict: w.strictness == .strict,
                                       reason: Reason(kind: .rule, id: w.id))
            }

            // 4. Pauses only soften non-strict blocks.
            if let c = candidate {
                if !c.strict {
                    var best: Pause?
                    for p in pauses where p.groupIds.contains(g) {
                        if let b = best {
                            if p.endsAt > b.endsAt || (p.endsAt == b.endsAt && p.id < b.id) { best = p }
                        } else { best = p }
                    }
                    if let p = best {
                        return Resolution(state: GroupState(groupId: g, blocked: false, strict: false,
                                                            reason: Reason(kind: .pause, id: p.id)))
                    }
                }
                return Resolution(state: c)
            }
            // 5. Nothing applies.
            return Resolution(state: GroupState(groupId: g, blocked: false, strict: false, reason: .none))
        }
    }
}
