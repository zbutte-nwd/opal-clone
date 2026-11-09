import XCTest
@testable import TetherCore

final class FocusStatsTests: XCTestCase {
    // Wed 2026-11-11 12:00 PST = 20:00Z. Week starts Mon 2026-11-09 00:00 PST = 08:00Z.
    let now = T.d("2026-11-11T20:00:00Z")

    func ses(_ id: String, start: String, minutes: Double, endedAfter: Double? = nil, groups: [String] = ["g"]) -> FocusSession {
        let s = T.d(start)
        return FocusSession(id: id, groupIds: groups, startsAt: s, endsAt: s.addingTimeInterval(minutes * 60), strict: false,
                            endedAt: endedAfter.map { s.addingTimeInterval($0 * 60) })
    }

    func testEmpty() {
        XCTAssertEqual(FocusStats.compute(sessions: [], now: now, timeZone: T.la),
                       FocusStats(focusedMinutesToday: 0, focusedMinutesThisWeek: 0, sessionsCompletedToday: 0,
                                  sessionsCompletedThisWeek: 0, sessionsCompletedTotal: 0, currentStreakDays: 0))
    }

    func testTodayAndWeekMinutes() {
        let sessions = [
            ses("a", start: "2026-11-11T17:00:00Z", minutes: 30),                 // today 09:00 PST
            ses("b", start: "2026-11-09T18:00:00Z", minutes: 60),                 // Monday
            ses("c", start: "2026-11-08T18:00:00Z", minutes: 45),                 // previous Sunday: not this week
        ]
        let s = FocusStats.compute(sessions: sessions, now: now, timeZone: T.la)
        XCTAssertEqual(s.focusedMinutesToday, 30)
        XCTAssertEqual(s.focusedMinutesThisWeek, 90)
        XCTAssertEqual(s.sessionsCompletedToday, 1)
        XCTAssertEqual(s.sessionsCompletedThisWeek, 2)
        XCTAssertEqual(s.sessionsCompletedTotal, 3)
    }

    func testEarlyEndCountsMinutesButNotCompletion() {
        let s = FocusStats.compute(sessions: [ses("a", start: "2026-11-11T17:00:00Z", minutes: 60, endedAfter: 20)], now: now, timeZone: T.la)
        XCTAssertEqual(s.focusedMinutesToday, 20)
        XCTAssertEqual(s.sessionsCompletedTotal, 0)
        XCTAssertEqual(s.currentStreakDays, 0)
    }

    func testRunningSessionCountsElapsedOnly() {
        let running = ses("a", start: "2026-11-11T19:30:00Z", minutes: 60)          // 30 of 60 minutes elapsed
        let s = FocusStats.compute(sessions: [running], now: now, timeZone: T.la)
        XCTAssertEqual(s.focusedMinutesToday, 30)
        XCTAssertEqual(s.sessionsCompletedTotal, 0)
    }

    func testPausesSubtractedOnlyForSharedGroups() {
        let a = ses("a", start: "2026-11-11T17:00:00Z", minutes: 60, groups: ["g1"])
        let p1 = Pause(id: "p1", groupIds: ["g1"], startsAt: T.d("2026-11-11T17:10:00Z"), endsAt: T.d("2026-11-11T17:20:00Z"))
        let p1b = Pause(id: "p1b", groupIds: ["g1"], startsAt: T.d("2026-11-11T17:15:00Z"), endsAt: T.d("2026-11-11T17:25:00Z"))  // overlaps p1
        let p2 = Pause(id: "p2", groupIds: ["other"], startsAt: T.d("2026-11-11T17:30:00Z"), endsAt: T.d("2026-11-11T17:40:00Z"))
        let s = FocusStats.compute(sessions: [a], pauses: [p1, p1b, p2], now: now, timeZone: T.la)
        XCTAssertEqual(s.focusedMinutesToday, 45)      // 60 - 15 (union of p1 ∪ p1b)
    }

    func testSessionSpanningMidnightSplitsAcrossDays() {
        // Tue 23:30 PST -> Wed 00:30 PST
        let a = ses("a", start: "2026-11-11T07:30:00Z", minutes: 60)
        let s = FocusStats.compute(sessions: [a], now: now, timeZone: T.la)
        XCTAssertEqual(s.focusedMinutesToday, 30)
        XCTAssertEqual(s.focusedMinutesThisWeek, 60)
    }

    func testStreak() {
        // Completed sessions on Mon, Tue, Wed(today).
        let ss = [ses("m", start: "2026-11-09T18:00:00Z", minutes: 10), ses("t", start: "2026-11-10T18:00:00Z", minutes: 10),
                  ses("w", start: "2026-11-11T17:00:00Z", minutes: 10)]
        XCTAssertEqual(FocusStats.compute(sessions: ss, now: now, timeZone: T.la).currentStreakDays, 3)
        // Gap on Monday: streak is 2.
        XCTAssertEqual(FocusStats.compute(sessions: Array(ss.dropFirst()), now: now, timeZone: T.la).currentStreakDays, 2)
        // Today empty but yesterday done: streak not broken yet.
        XCTAssertEqual(FocusStats.compute(sessions: Array(ss.prefix(2)), now: now, timeZone: T.la).currentStreakDays, 2)
        // Last session two days ago: streak is 0.
        XCTAssertEqual(FocusStats.compute(sessions: [ss[0]], now: now, timeZone: T.la).currentStreakDays, 0)
    }

    func testStreakUsesLocalDays() {
        // 03:00Z Wed is Tuesday evening in LA; streak days follow the local calendar.
        let late = ses("late", start: "2026-11-11T03:00:00Z", minutes: 10)           // Tue 19:00 PST
        let mon = ses("mon", start: "2026-11-10T03:00:00Z", minutes: 10)             // Mon 19:00 PST
        XCTAssertEqual(FocusStats.compute(sessions: [late, mon], now: now, timeZone: T.la).currentStreakDays, 2)
        XCTAssertEqual(FocusStats.compute(sessions: [late, mon], now: now, timeZone: T.utc).currentStreakDays, 2)
    }

    func testWeekStartsMondayOnSunday() {
        // Sunday 2026-11-15 12:00 PST: the week still began Mon 11-09.
        let sunday = T.d("2026-11-15T20:00:00Z")
        let a = ses("a", start: "2026-11-09T18:00:00Z", minutes: 30)
        XCTAssertEqual(FocusStats.compute(sessions: [a], now: sunday, timeZone: T.la).focusedMinutesThisWeek, 30)
        let monday = T.d("2026-11-16T20:00:00Z")
        XCTAssertEqual(FocusStats.compute(sessions: [a], now: monday, timeZone: T.la).focusedMinutesThisWeek, 0)
    }

    func testFromPersistedState() {
        var st = PersistedState()
        st.sessions = [ses("a", start: "2026-11-11T17:00:00Z", minutes: 30)]
        XCTAssertEqual(FocusStats.compute(state: st, now: now, timeZone: T.la).focusedMinutesToday, 30)
    }
}
