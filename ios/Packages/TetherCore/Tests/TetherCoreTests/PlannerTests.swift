import XCTest
@testable import TetherCore

final class PlannerTests: XCTestCase {
    let school = T.rule("rule_school", groups: ["grp_social"], windows: [Window(days: T.weekdays, start: "08:00", end: "15:00")], name: "School hours")

    func testSchoolScheduleNextTransitions() {
        let input = T.input(rules: [school])
        let now = T.d("2026-11-09T14:00:00Z")           // Mon 06:00 PST
        let tr = TransitionPlanner.nextTransitions(input, after: now, timeZone: T.la, limit: 4)
        XCTAssertEqual(tr, [T.d("2026-11-09T16:00:00Z"), T.d("2026-11-09T23:00:00Z"),
                            T.d("2026-11-10T16:00:00Z"), T.d("2026-11-10T23:00:00Z")])
    }

    func testStrictlyAfterNow() {
        let input = T.input(rules: [school])
        let tr = TransitionPlanner.nextTransitions(input, after: T.d("2026-11-09T16:00:00Z"), timeZone: T.la, limit: 1)
        XCTAssertEqual(tr, [T.d("2026-11-09T23:00:00Z")])
    }

    func testLimitCapAndHorizon() {
        let input = T.input(rules: [school])
        let now = T.d("2026-11-09T14:00:00Z")
        XCTAssertEqual(TransitionPlanner.nextTransitions(input, after: now, timeZone: T.la, limit: 3).count, 3)
        XCTAssertEqual(TransitionPlanner.nextTransitions(input, after: now, timeZone: T.la, limit: 0), [])
        // 7 days of weekdays: Mon..Fri (5) + next Mon (the horizon ends at next Mon 06:00 PST) => 10 transitions.
        XCTAssertEqual(TransitionPlanner.nextTransitions(input, after: now, timeZone: T.la, limit: 100).count, 10)
        XCTAssertEqual(TransitionPlanner.nextTransitions(input, after: now, timeZone: T.la, horizon: 3600, limit: 100), [])
    }

    func testNoopBoundariesFilteredOut() {
        // Two back-to-back windows in two rules for the same group: the handoff at 12:00 is not a change.
        let a = T.rule("rule_a", groups: ["grp_social"], windows: [Window(days: [1], start: "08:00", end: "12:00")], priority: 0)
        let b = T.rule("rule_b", groups: ["grp_social"], windows: [Window(days: [1], start: "08:00", end: "15:00")], priority: 0)
        // rule_a wins (smallest id) until 12:00, then rule_b => reason changes at 12:00 (real change).
        let tr = TransitionPlanner.nextTransitions(T.input(rules: [a, b]), after: T.d("2026-11-09T00:00:00Z"), timeZone: T.utc, limit: 10)
        XCTAssertEqual(tr, [T.d("2026-11-09T08:00:00Z"), T.d("2026-11-09T12:00:00Z"), T.d("2026-11-09T15:00:00Z")])
        // Same rule with two adjacent windows: no change at the seam.
        let one = T.rule("rule_one", groups: ["grp_social"], windows: [Window(days: [1], start: "08:00", end: "12:00"), Window(days: [1], start: "12:00", end: "15:00")])
        let tr2 = TransitionPlanner.nextTransitions(T.input(rules: [one]), after: T.d("2026-11-09T00:00:00Z"), timeZone: T.utc, limit: 10)
        XCTAssertEqual(tr2, [T.d("2026-11-09T08:00:00Z"), T.d("2026-11-09T15:00:00Z")])
    }

    func testSessionEnd() {
        let now = T.d("2026-11-09T20:00:00Z")
        let s = FocusSession(id: "ses_1", groupIds: ["grp_social"], startsAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(1200), strict: false)
        XCTAssertEqual(TransitionPlanner.nextTransitions(T.input(sessions: [s]), after: now, timeZone: T.utc), [now.addingTimeInterval(1200)])
    }

    func testSessionEndedEarlyAndFutureSession() {
        let now = T.d("2026-11-09T20:00:00Z")
        let early = FocusSession(id: "ses_1", groupIds: ["grp_social"], startsAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(1200), strict: false, endedAt: now.addingTimeInterval(300))
        // endedAt is a candidate and the real end of blocking.
        XCTAssertEqual(TransitionPlanner.nextTransitions(T.input(sessions: [early]), after: now, timeZone: T.utc), [now.addingTimeInterval(300)])
        let future = FocusSession(id: "ses_2", groupIds: ["grp_social"], startsAt: now.addingTimeInterval(100), endsAt: now.addingTimeInterval(700), strict: true)
        XCTAssertEqual(TransitionPlanner.nextTransitions(T.input(sessions: [future]), after: now, timeZone: T.utc),
                       [now.addingTimeInterval(100), now.addingTimeInterval(700)])
    }

    func testTimedOverrideEnd() {
        let now = T.d("2026-11-09T17:00:00Z")           // Mon 09:00 PST, school is active
        let ov = Override(id: "ovr_1", groupIds: ["grp_social"], action: .unblock, startsAt: now.addingTimeInterval(-60),
                          endsAt: now.addingTimeInterval(1800), issuedAt: now.addingTimeInterval(-60))
        let input = T.input(rules: [school], overrides: [ov])
        // Override ends 17:30Z -> school block resumes. School end at 23:00Z is then a real change too.
        let tr = TransitionPlanner.nextTransitions(input, after: now, timeZone: T.la, limit: 2)
        XCTAssertEqual(tr, [now.addingTimeInterval(1800), T.d("2026-11-09T23:00:00Z")])
    }

    func testPauseEnd() {
        let now = T.d("2026-11-09T17:00:00Z")
        let p = Pause(id: "pau_1", groupIds: ["grp_social"], startsAt: now.addingTimeInterval(-60), endsAt: now.addingTimeInterval(240), ruleId: "rule_school")
        XCTAssertEqual(TransitionPlanner.nextTransitions(T.input(rules: [school], pauses: [p]), after: now, timeZone: T.la, limit: 1),
                       [now.addingTimeInterval(240)])
    }

    func testUsageLimitMidnight() {
        let r = Rule(id: "rule_use", name: "Daily limit", groupIds: ["grp_social"], trigger: .usageLimit(dailyMinutes: 30, days: [1, 2, 3, 4, 5, 6, 7]), source: .server)
        let hit = UsageLimitHit(ruleId: "rule_use", day: "2026-11-09")
        let now = T.d("2026-11-09T20:00:00Z")           // Mon 12:00 PST
        let tr = TransitionPlanner.nextTransitions(T.input(rules: [r], hits: [hit]), after: now, timeZone: T.la, limit: 5)
        XCTAssertEqual(tr, [T.d("2026-11-10T08:00:00Z")], "blocked until local midnight, then the hit expires")
    }

    func testManualRuleNoTransitions() {
        let r = Rule(id: "rule_m", name: "m", groupIds: ["grp_social"], trigger: .manual(active: true), source: .server)
        XCTAssertEqual(TransitionPlanner.nextTransitions(T.input(rules: [r]), after: T.d("2026-11-09T00:00:00Z"), timeZone: T.utc), [])
    }

    func testLocalRulesIgnoredWhenDisallowed() {
        let local = T.rule("lrule_1", groups: ["grp_social"], windows: [Window(days: [1], start: "08:00", end: "09:00")])
        let allowed = T.input(allowLocal: true, localRules: [local])
        let denied = T.input(allowLocal: false, localRules: [local])
        XCTAssertEqual(TransitionPlanner.nextTransitions(allowed, after: T.d("2026-11-09T00:00:00Z"), timeZone: T.utc).count, 2)
        XCTAssertEqual(TransitionPlanner.nextTransitions(denied, after: T.d("2026-11-09T00:00:00Z"), timeZone: T.utc), [])
    }

    func testAnnotateUntil() {
        let games = T.group("grp_games", "Games")
        let r = T.rule("rule_school", groups: ["grp_social"], windows: [Window(days: T.weekdays, start: "08:00", end: "15:00")])
        let input = T.input(groups: [T.group("grp_social"), games], rules: [r])
        let now = T.d("2026-11-09T17:00:00Z")           // school active
        let states = PolicyEngine.evaluate(input, at: now, timeZone: T.la)
        let out = TransitionPlanner.annotateUntil(states, input: input, now: now, timeZone: T.la)
        XCTAssertEqual(out["grp_social"]?.until, T.d("2026-11-09T23:00:00Z"))
        XCTAssertNil(out["grp_games"]?.until, "never changes")
        XCTAssertTrue(out["grp_social"]!.blocked)
    }

    func testAnnotateUntilWhileUnblockedPointsToNextBlock() {
        let r = T.rule("rule_school", groups: ["grp_social"], windows: [Window(days: T.weekdays, start: "08:00", end: "15:00")])
        let input = T.input(rules: [r])
        let now = T.d("2026-11-09T23:30:00Z")           // after school
        let out = TransitionPlanner.annotateUntil(PolicyEngine.evaluate(input, at: now, timeZone: T.la), input: input, now: now, timeZone: T.la)
        XCTAssertEqual(out["grp_social"]?.until, T.d("2026-11-10T16:00:00Z"))
    }
}
