import Foundation
import TetherCore

struct WindowDraft: Identifiable, Hashable {
    var id = UUID()
    var days: Set<ISOWeekday> = [1, 2, 3, 4, 5]
    var startMin: Int = 9 * 60
    var endMin: Int = 17 * 60

    /// End is earlier than start: the window runs past midnight (ARCHITECTURE §2).
    var endsNextDay: Bool { endMin < startMin }
    var isValid: Bool { startMin != endMin && !days.isEmpty }
}

/// Editable form state for a local Rule (C1/C4/C5/D3/D5). Mirrors ARCHITECTURE §2 window semantics.
struct RuleDraft {
    enum Kind: String, CaseIterable, Identifiable { case schedule = "Schedule", limit = "Daily limit"; var id: String { rawValue } }

    var id: RuleID = TetherID.make("lrule")
    var name = ""
    var groupIds: Set<GroupID> = []
    var enabled = true
    var kind: Kind = .schedule
    var windows: [WindowDraft] = [WindowDraft()]
    var limitMinutes = 30
    var limitDays: Set<ISOWeekday> = [1, 2, 3, 4, 5, 6, 7]
    var strict = false
    var limitPauses = true
    var maxPauses = 3
    var priority = 0

    init() {}

    init?(rule: Rule) {
        id = rule.id; name = rule.name; groupIds = Set(rule.groupIds); enabled = rule.enabled
        strict = rule.strictness == .strict; priority = rule.priority
        if let m = rule.maxPausesPerDay { limitPauses = true; maxPauses = m } else { limitPauses = false }
        switch rule.trigger {
        case .schedule(let ws):
            kind = .schedule
            windows = ws.map { w in
                WindowDraft(days: Set(w.days), startMin: Fmt.minutes(fromHHMM: w.start) ?? 0, endMin: Fmt.minutes(fromHHMM: w.end) ?? 0)
            }
        case .usageLimit(let m, let d):
            kind = .limit; limitMinutes = m; limitDays = Set(d)
        case .manual:
            return nil    // server-driven toggle; not editable on device
        }
    }

    var errors: [String] {
        var e: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { e.append("Give the schedule a name.") }
        if groupIds.isEmpty { e.append("Choose at least one group.") }
        switch kind {
        case .schedule:
            if windows.isEmpty { e.append("Add at least one time window.") }
            for (i, w) in windows.enumerated() {
                if w.days.isEmpty { e.append("Window \(i + 1): choose at least one day.") }
                if w.startMin == w.endMin { e.append("Window \(i + 1): start and end can't be the same time.") }
            }
        case .limit:
            if limitMinutes < 1 { e.append("Limit must be at least 1 minute.") }
            if limitDays.isEmpty { e.append("Choose at least one day.") }
        }
        return e
    }

    func makeRule(source: Source = .local) -> Rule {
        let trigger: Trigger
        switch kind {
        case .schedule:
            trigger = .schedule(windows: windows.map {
                Window(days: $0.days.sorted(), start: Fmt.hhmm(fromMinutes: $0.startMin), end: Fmt.hhmm(fromMinutes: $0.endMin))
            })
        case .limit:
            trigger = .usageLimit(dailyMinutes: limitMinutes, days: limitDays.sorted())
        }
        return Rule(id: id, name: name.trimmingCharacters(in: .whitespaces), groupIds: groupIds.sorted(), enabled: enabled,
                    action: .block, trigger: trigger, strictness: strict ? .strict : .flexible, priority: priority,
                    maxPausesPerDay: (!strict && limitPauses) ? maxPauses : nil, source: source)
    }
}

enum RuleSummary {
    static func describe(_ rule: Rule) -> String {
        switch rule.trigger {
        case .schedule(let ws): return ws.map(Fmt.window).joined(separator: "; ")
        case .usageLimit(let m, let d): return "\(Fmt.duration(minutes: m)) a day · \(Fmt.days(d))"
        case .manual(let active): return active ? "Turned on by your admin" : "Off (admin toggle)"
        }
    }
}
