import XCTest
@testable import TetherCore

final class PolicyEngineTests: XCTestCase {
    let school = T.rule("rule_school", groups: ["grp_social"], windows: [Window(days: T.weekdays, start: "08:00", end: "15:00")], name: "School hours", maxPauses: 2)
    let inSchool = T.d("2026-11-09T17:00:00Z")      // Mon 09:00 PST

    func testEffectiveTimeZone() {
        let ny = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(PolicyEngine.effectiveTimeZone(T.input(tz: "Asia/Tokyo"), deviceTimeZone: ny).identifier, "Asia/Tokyo")
        XCTAssertEqual(PolicyEngine.effectiveTimeZone(T.input(tz: "Not/AZone"), deviceTimeZone: ny).identifier, "America/New_York")
        XCTAssertEqual(PolicyEngine.effectiveTimeZone(T.input(), deviceTimeZone: ny).identifier, "America/New_York")
        XCTAssertEqual(PolicyEngine.effectiveTimeZone(EngineInput(), deviceTimeZone: ny).identifier, "America/New_York")
    }

    func testOutputsExactlyKnownGroups() {
        let input = T.input(groups: [T.group("grp_a"), T.group("grp_b")],
                            rules: [T.rule("r", groups: ["grp_a", "grp_unknown"], windows: [Window(days: [1], start: "00:00", end: "24:00")])])
        let out = PolicyEngine.evaluate(input, at: inSchool, timeZone: T.la)
        XCTAssertEqual(Set(out.keys), ["grp_a", "grp_b"])
        XCTAssertTrue(out["grp_a"]!.blocked)
        XCTAssertFalse(out["grp_b"]!.blocked)
    }

    func testEmptyInput() {
        XCTAssertTrue(PolicyEngine.evaluate(EngineInput(), at: inSchool, timeZone: T.la).isEmpty)
    }

    func testCanPauseNotBlocked() {
        let input = T.input(rules: [school])
        XCTAssertEqual(PolicyEngine.canPause(groupId: "grp_social", input, at: T.d("2026-11-09T23:30:00Z"), timeZone: T.la), .notBlocked)
        XCTAssertEqual(PolicyEngine.canPause(groupId: "grp_nope", input, at: inSchool, timeZone: T.la), .notBlocked)
    }

    func testCanPauseAllowedAndStrict() {
        XCTAssertEqual(PolicyEngine.canPause(groupId: "grp_social", T.input(rules: [school]), at: inSchool, timeZone: T.la), .allowed)
        let strict = T.rule("rule_strict", groups: ["grp_social"], windows: [Window(days: T.weekdays, start: "08:00", end: "15:00")], strict: true)
        XCTAssertEqual(PolicyEngine.canPause(groupId: "grp_social", T.input(rules: [strict]), at: inSchool, timeZone: T.la), .strict)
    }

    func testOverrideBlockIsStrictNotPausable() {
        let ov = Override(id: "ovr_1", groupIds: ["grp_social"], action: .block, startsAt: inSchool.addingTimeInterval(-60), issuedAt: inSchool.addingTimeInterval(-60))
        XCTAssertEqual(PolicyEngine.canPause(groupId: "grp_social", T.input(overrides: [ov]), at: inSchool, timeZone: T.la), .strict)
    }

    func testStrictSessionNotPausable() {
        let s = FocusSession(id: "ses_1", groupIds: ["grp_social"], startsAt: inSchool.addingTimeInterval(-60), endsAt: inSchool.addingTimeInterval(600), strict: true)
        XCTAssertEqual(PolicyEngine.canPause(groupId: "grp_social", T.input(sessions: [s]), at: inSchool, timeZone: T.la), .strict)
        let f = FocusSession(id: "ses_1", groupIds: ["grp_social"], startsAt: inSchool.addingTimeInterval(-60), endsAt: inSchool.addingTimeInterval(600), strict: false)
        XCTAssertEqual(PolicyEngine.canPause(groupId: "grp_social", T.input(sessions: [f]), at: inSchool, timeZone: T.la), .allowed)
    }

    func testPauseBudgetCountsOnlyTodayAndMatchingRule() {
        func pause(_ id: String, at t: Date, rule: String?) -> Pause {
            Pause(id: id, groupIds: ["grp_other"], startsAt: t, endsAt: t.addingTimeInterval(300), ruleId: rule)
        }
        let yesterday = pause("p0", at: inSchool.addingTimeInterval(-86400), rule: "rule_school")
        let otherRule = pause("p1", at: inSchool.addingTimeInterval(-3600), rule: "rule_other")
        let one = pause("p2", at: inSchool.addingTimeInterval(-3000), rule: "rule_school")
        let input1 = T.input(groups: [T.group("grp_social"), T.group("grp_other")], rules: [school], pauses: [yesterday, otherRule, one])
        XCTAssertEqual(PolicyEngine.canPause(groupId: "grp_social", input1, at: inSchool, timeZone: T.la), .allowed)
        let two = pause("p3", at: inSchool.addingTimeInterval(-1800), rule: "rule_school")
        let input2 = T.input(groups: [T.group("grp_social"), T.group("grp_other")], rules: [school], pauses: [yesterday, otherRule, one, two])
        XCTAssertEqual(PolicyEngine.canPause(groupId: "grp_social", input2, at: inSchool, timeZone: T.la), .budgetExhausted(limit: 2))
    }

    func testPauseBudgetZeroMeansNeverPausable() {
        let r = T.rule("rule_x", groups: ["grp_social"], windows: [Window(days: T.weekdays, start: "08:00", end: "15:00")], maxPauses: 0)
        XCTAssertEqual(PolicyEngine.canPause(groupId: "grp_social", T.input(rules: [r]), at: inSchool, timeZone: T.la), .budgetExhausted(limit: 0))
    }

    func testPauseBudgetDayBoundaryUsesEffectiveTimeZone() {
        // 06:30Z Tue = 22:30 Mon PST. A pause at 07:30Z Tue (23:30 Mon PST) is the same local day.
        let r = T.rule("rule_n", groups: ["grp_social"], windows: [Window(days: [1], start: "20:00", end: "24:00")], maxPauses: 1)
        let now = T.d("2026-11-10T06:30:00Z")
        let p = Pause(id: "p", groupIds: ["grp_social"], startsAt: T.d("2026-11-10T05:00:00Z"), endsAt: T.d("2026-11-10T05:05:00Z"), ruleId: "rule_n")
        XCTAssertEqual(PolicyEngine.canPause(groupId: "grp_social", T.input(rules: [r], pauses: [p]), at: now, timeZone: T.la), .budgetExhausted(limit: 1))
        // In UTC, 05:00Z and 06:30Z are also the same day, but a pause from 23:30Z Mon is a different UTC day.
        let p2 = Pause(id: "p", groupIds: ["grp_social"], startsAt: T.d("2026-11-09T23:30:00Z"), endsAt: T.d("2026-11-09T23:35:00Z"), ruleId: "rule_n")
        XCTAssertEqual(PolicyEngine.canPause(groupId: "grp_social", T.input(rules: [r], pauses: [p2]), at: now, timeZone: T.utc), .notBlocked)
    }

    func testBlockedPausedReportsNotBlocked() {
        let p = Pause(id: "pau_1", groupIds: ["grp_social"], startsAt: inSchool.addingTimeInterval(-60), endsAt: inSchool.addingTimeInterval(240))
        let input = T.input(rules: [school], pauses: [p])
        let s = PolicyEngine.evaluate(input, at: inSchool, timeZone: T.la)["grp_social"]!
        XCTAssertEqual(s.reason, Reason(kind: .pause, id: "pau_1"))
        XCTAssertEqual(PolicyEngine.canPause(groupId: "grp_social", input, at: inSchool, timeZone: T.la), .notBlocked)
    }

    func testPerformanceManyGroupsAndRules() {
        var groups: [BlockGroup] = []; var rules: [Rule] = []
        for i in 0..<50 {
            groups.append(T.group("grp_\(i)"))
            rules.append(T.rule("rule_\(i)", groups: ["grp_\(i)", "grp_\((i + 1) % 50)"], windows: [Window(days: T.weekdays, start: "08:00", end: "15:00")]))
        }
        let input = T.input(groups: groups, rules: rules)
        measure { for _ in 0..<20 { _ = PolicyEngine.evaluate(input, at: inSchool, timeZone: T.la) } }
    }
}
