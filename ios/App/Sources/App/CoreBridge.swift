// CoreBridge.swift
// Small pure helpers the UI needs that sit between TetherCore's models and SwiftUI:
// reason text for blocked groups (the app-side equivalent of the shield's ShieldCopy) and
// focus statistics. Pure functions of PersistedState, so they're previewable.
//
// VERIFY: W1 may ship `ShieldCopy` and `FocusStats` in TetherCore. If so, replace
// `reasonTitle/reasonSubtitle` and `focusStats` bodies with calls to those so the app and
// the shield extension never disagree.

import Foundation
import TetherCore

struct FocusStatsSummary: Equatable {
    var minutesToday = 0
    var minutesWeek = 0
    var sessionsToday = 0
    var sessionsWeek = 0
    var streakDays = 0
}

enum CoreBridge {
    /// "Work hours", "Focus session: Deep work", "Set by your admin", "Paused".
    static func reasonTitle(_ gs: GroupState, in st: PersistedState) -> String {
        switch gs.reason.kind {
        case .override:
            let o = st.bundle?.overrides.first { $0.id == gs.reason.id }
            if let r = o?.reason, !r.isEmpty { return "Admin: \(r)" }
            return "Set by your admin"
        case .session:
            let s = st.sessions.first { $0.id == gs.reason.id }
            if let n = s?.name, !n.isEmpty { return "Focus session: \(n)" }
            return "Focus session"
        case .rule:
            let all = (st.bundle?.rules ?? []) + st.localRules
            return all.first { $0.id == gs.reason.id }?.name ?? "Scheduled block"
        case .pause: return "Paused"
        case .none: return "Not blocked"
        }
    }

    /// Reason + end time, e.g. "Work hours · until 5:00 PM".
    static func reasonSubtitle(_ gs: GroupState, in st: PersistedState, now: Date) -> String {
        var t = reasonTitle(gs, in: st)
        if let u = gs.until { t += " · until \(Fmt.until(u, now: now))" }
        if gs.strict { t += " · strict" }
        return t
    }

    /// The pausable rule id behind a block, for `Pause.ruleId` (D3 budget accounting).
    static func ruleId(of gs: GroupState) -> RuleID? { gs.reason.kind == .rule ? gs.reason.id : nil }

    static func focusStats(_ sessions: [FocusSession], now: Date, timeZone: TimeZone) -> FocusStatsSummary {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let todayStart = cal.startOfDay(for: now)
        let weekStart = cal.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        var out = FocusStatsSummary()
        var days = Set<Date>()
        for s in sessions {
            let end = min(s.endedAt ?? s.endsAt, now)
            guard end > s.startsAt else { continue }
            let mins = Int(end.timeIntervalSince(s.startsAt) / 60)
            let day = cal.startOfDay(for: s.startsAt)
            if day >= weekStart { out.minutesWeek += mins; out.sessionsWeek += 1 }
            if day >= todayStart { out.minutesToday += mins; out.sessionsToday += 1 }
            days.insert(day)
        }
        var cursor = days.contains(todayStart) ? todayStart : (cal.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart)
        while days.contains(cursor) {
            out.streakDays += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return out
    }
}
