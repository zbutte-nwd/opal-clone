// FocusStats.swift — history numbers for the app's Focus tab, derived from sessions (+ pauses).
//
// - A session's focused time is [startsAt, min(endsAt, endedAt, now)) minus any time covered by
//   pauses on one of the session's groups.
// - A session is "completed" if it ran to its scheduled end (not ended early).
// - Streak = consecutive local days (ending today, or yesterday if today has none yet) that have
//   at least one completed session (day = local day the session started).
// - "This week" runs Monday 00:00 local to the following Monday.

import Foundation

public struct FocusStats: Sendable, Equatable {
    public var focusedMinutesToday: Int
    public var focusedMinutesThisWeek: Int
    public var sessionsCompletedToday: Int
    public var sessionsCompletedThisWeek: Int
    public var sessionsCompletedTotal: Int
    public var currentStreakDays: Int

    public static func compute(sessions: [FocusSession], pauses: [Pause] = [], now: Date, timeZone: TimeZone) -> FocusStats {
        let cal = ScheduleMath.calendar(timeZone)
        let todayStart = cal.startOfDay(for: now)
        let tomorrowStart = ScheduleMath.nextMidnight(after: now, in: timeZone)
        let iso = ScheduleMath.isoWeekday(of: now, in: timeZone)
        let weekStart = cal.startOfDay(for: cal.date(byAdding: .day, value: -(iso - 1), to: todayStart) ?? todayStart)
        let weekEnd = cal.startOfDay(for: cal.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart.addingTimeInterval(7 * 86400))

        var todaySecs = 0.0, weekSecs = 0.0
        var doneToday = 0, doneWeek = 0, doneTotal = 0
        var completedDays = Set<String>()

        for s in sessions {
            let end = min(s.endsAt, s.endedAt ?? s.endsAt, now)
            if end > s.startsAt {
                let paused = pauses.filter { p in p.groupIds.contains { s.groupIds.contains($0) } }
                    .map { (max($0.startsAt, s.startsAt), min($0.endsAt, end)) }
                    .filter { $0.0 < $0.1 }
                for piece in subtract(from: (s.startsAt, end), removing: paused) {
                    todaySecs += overlap(piece, todayStart, tomorrowStart)
                    weekSecs += overlap(piece, weekStart, weekEnd)
                }
            }
            let completed = (s.endedAt.map { $0 >= s.endsAt } ?? true) && s.endsAt <= now
            if completed {
                doneTotal += 1
                if s.startsAt >= todayStart && s.startsAt < tomorrowStart { doneToday += 1 }
                if s.startsAt >= weekStart && s.startsAt < weekEnd { doneWeek += 1 }
                completedDays.insert(ScheduleMath.dayString(s.startsAt, in: timeZone))
            }
        }

        // Streak: walk backwards day by day.
        var streak = 0
        var cursor = todayStart
        if !completedDays.contains(ScheduleMath.dayString(cursor, in: timeZone)) {
            cursor = cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: cursor) ?? cursor.addingTimeInterval(-86400))
        }
        while completedDays.contains(ScheduleMath.dayString(cursor, in: timeZone)) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = cal.startOfDay(for: prev)
        }

        return FocusStats(focusedMinutesToday: Int(todaySecs / 60), focusedMinutesThisWeek: Int(weekSecs / 60),
                          sessionsCompletedToday: doneToday, sessionsCompletedThisWeek: doneWeek,
                          sessionsCompletedTotal: doneTotal, currentStreakDays: streak)
    }

    public static func compute(state: PersistedState, now: Date, timeZone: TimeZone) -> FocusStats {
        compute(sessions: state.sessions, pauses: state.pauses, now: now, timeZone: timeZone)
    }

    // MARK: Interval helpers

    private static func overlap(_ a: (Date, Date), _ lo: Date, _ hi: Date) -> Double {
        let s = max(a.0, lo), e = min(a.1, hi)
        return e > s ? e.timeIntervalSince(s) : 0
    }

    /// `base` minus the union of `cuts`, as disjoint intervals.
    private static func subtract(from base: (Date, Date), removing cuts: [(Date, Date)]) -> [(Date, Date)] {
        var out: [(Date, Date)] = []
        var cursor = base.0
        for c in cuts.sorted(by: { $0.0 < $1.0 }) {
            if c.0 > cursor { out.append((cursor, min(c.0, base.1))) }
            cursor = max(cursor, c.1)
            if cursor >= base.1 { break }
        }
        if cursor < base.1 { out.append((cursor, base.1)) }
        return out
    }
}
