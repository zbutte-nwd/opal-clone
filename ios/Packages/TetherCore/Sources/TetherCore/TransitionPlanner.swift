// TransitionPlanner.swift — "when might anything change next?"
//
// Collects candidate boundary instants from all inputs (schedule window edges, session
// start/end, early-end timestamps, pause edges, override edges, local midnights for
// usage-limit rules), then keeps only those where `PolicyEngine.evaluate` output really
// changes (blocked / strict / reason). Used by ActivityScheduler to register DeviceActivity
// wake-ups and by `annotateUntil` to fill `GroupState.until`.

import Foundation

public enum TransitionPlanner {

    /// Sorted, de-duplicated instants strictly after `now` (within `horizon`) at which some
    /// group's state changes, capped at `limit`.
    public static func nextTransitions(_ input: EngineInput, after now: Date, timeZone: TimeZone,
                                       horizon: TimeInterval = 7 * 86400, limit: Int = 16) -> [Date] {
        guard limit > 0 else { return [] }
        var previous = PolicyEngine.evaluate(input, at: now, timeZone: timeZone)
        var out: [Date] = []
        for t in candidates(input, after: now, timeZone: timeZone, horizon: horizon) {
            // State only changes at candidate instants, so the state at the previous
            // candidate equals the state just before `t`.
            let current = PolicyEngine.evaluate(input, at: t, timeZone: timeZone)
            if !PolicyEngine.sameStates(previous, current) {
                out.append(t)
                if out.count >= limit { break }
                previous = current
            }
        }
        return out
    }

    /// Returns `states` with `until` set to the next time that group's state changes
    /// (nil if it does not change within `horizon`). `states` should be the result of
    /// `PolicyEngine.evaluate(input, at: now, …)`.
    public static func annotateUntil(_ states: [GroupID: GroupState], input: EngineInput, now: Date,
                                     timeZone: TimeZone, horizon: TimeInterval = 7 * 86400) -> [GroupID: GroupState] {
        var result = states
        var remaining = Set(states.keys)
        if remaining.isEmpty { return result }
        for t in candidates(input, after: now, timeZone: timeZone, horizon: horizon) {
            let current = PolicyEngine.evaluate(input, at: t, timeZone: timeZone)
            for g in remaining where !PolicyEngine.sameState(states[g], current[g]) {
                result[g]?.until = t
                remaining.remove(g)
            }
            if remaining.isEmpty { break }
        }
        return result
    }

    /// Candidate boundary instants in `(now, now + horizon]`, sorted and de-duplicated.
    /// A superset of the real transitions.
    static func candidates(_ input: EngineInput, after now: Date, timeZone: TimeZone, horizon: TimeInterval) -> [Date] {
        let end = now.addingTimeInterval(horizon)
        var set = Set<Date>()
        func add(_ d: Date?) { if let d = d, d > now, d <= end { set.insert(d) } }

        var needsMidnights = false
        for r in PolicyEngine.effectiveRules(input) where r.enabled {
            switch r.trigger {
            case .schedule(let windows):
                for d in ScheduleMath.boundaries(of: windows, after: now, through: end, in: timeZone) { set.insert(d) }
            case .usageLimit:
                needsMidnights = true
            case .manual:
                break
            }
        }
        if needsMidnights {
            for d in ScheduleMath.midnights(after: now, through: end, in: timeZone) { set.insert(d) }
        }
        for s in input.sessions {
            add(s.startsAt); add(s.endsAt); add(s.endedAt)
        }
        for p in input.pauses { add(p.startsAt); add(p.endsAt) }
        for o in input.bundle?.overrides ?? [] { add(o.startsAt); add(o.endsAt) }
        return set.sorted()
    }
}
