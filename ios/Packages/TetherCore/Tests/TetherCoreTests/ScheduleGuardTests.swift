import XCTest
@testable import TetherCore

/// 2026-11-09 is a Monday. Times below are PST (UTC-8).
final class ScheduleGuardTests: XCTestCase {
    let tz = T.la
    let at10 = T.d("2026-11-09T18:00:00Z")   // Mon 10:00
    let at18 = T.d("2026-11-10T02:00:00Z")   // Mon 18:00
    let work = [Window(days: T.weekdays, start: "09:00", end: "17:00")]

    func local(_ id: String, strictness: Strictness = .guarded, action: RuleAction = .block, priority: Int = 0,
               windows: [Window]? = nil, maxPauses: Int? = nil, groups: [GroupID] = ["grp_social"]) -> Rule {
        Rule(id: id, name: id, groupIds: groups, action: action, trigger: .schedule(windows: windows ?? work),
             strictness: strictness, priority: priority, maxPausesPerDay: maxPauses, source: .local)
    }

    func input(_ rules: [Rule], server: [Rule] = [], pauses: [Pause] = [], overrides: [Override] = [],
               sessions: [FocusSession] = []) -> EngineInput {
        T.input(rules: server, overrides: overrides, sessions: sessions, pauses: pauses, localRules: rules)
    }

    // MARK: ruleChange

    func testEditingActiveGuardedRuleIsLocked() {
        let r = local("lrule_work")
        var edited = r; edited.trigger = .schedule(windows: [Window(days: T.weekdays, start: "09:00", end: "10:00")])
        guard case .locked = ScheduleGuard.ruleChange(before: input([r]), after: input([edited]), at: at10, timeZone: tz) else {
            return XCTFail("editing an active guarded rule must be locked")
        }
    }

    func testEditingGuardedRuleOutsideWindowIsAllowed() {
        let r = local("lrule_work")
        var edited = r; edited.trigger = .schedule(windows: [Window(days: T.weekdays, start: "09:00", end: "10:00")])
        XCTAssertEqual(ScheduleGuard.ruleChange(before: input([r]), after: input([edited]), at: at18, timeZone: tz), .allowed)
    }

    func testDeletingOrDisablingActiveGuardedRuleIsLocked() {
        let r = local("lrule_work")
        var off = r; off.enabled = false
        XCTAssertNotEqual(ScheduleGuard.ruleChange(before: input([r]), after: input([]), at: at10, timeZone: tz), .allowed)
        XCTAssertNotEqual(ScheduleGuard.ruleChange(before: input([r]), after: input([off]), at: at10, timeZone: tz), .allowed)
    }

    func testNewHigherPriorityAllowRuleIsLocked() {
        let r = local("lrule_work")
        let allow = local("lrule_ok", strictness: .flexible, action: .allow, priority: 10)
        XCTAssertNotEqual(ScheduleGuard.ruleChange(before: input([r]), after: input([r, allow]), at: at10, timeZone: tz), .allowed)
    }

    func testAddingBlockRuleIsAllowed() {
        let r = local("lrule_work")
        let more = local("lrule_more", strictness: .strict, groups: ["grp_social"])
        XCTAssertEqual(ScheduleGuard.ruleChange(before: input([r]), after: input([r, more]), at: at10, timeZone: tz), .allowed)
    }

    func testOutcomeGateIgnoresActivePause() {
        let r = local("lrule_work")
        let pause = Pause(id: "pau_1", groupIds: ["grp_social"], startsAt: T.d("2026-11-09T17:58:00Z"),
                          endsAt: T.d("2026-11-09T18:03:00Z"), ruleId: r.id)
        let allow = local("lrule_ok", strictness: .flexible, action: .allow, priority: 10)
        XCTAssertNotEqual(ScheduleGuard.ruleChange(before: input([r], pauses: [pause]), after: input([r, allow], pauses: [pause]),
                                                   at: at10, timeZone: tz), .allowed)
    }

    func testOutcomeGateIgnoresUnblockOverride() {
        let r = local("lrule_work")
        let unblock = Override(id: "ovr_1", groupIds: ["grp_social"], action: .unblock, startsAt: T.d("2026-11-09T17:00:00Z"),
                               endsAt: T.d("2026-11-09T20:00:00Z"), issuedAt: T.d("2026-11-09T17:00:00Z"))
        let allow = local("lrule_ok", strictness: .flexible, action: .allow, priority: 10)
        XCTAssertNotEqual(ScheduleGuard.ruleChange(before: input([r], overrides: [unblock]), after: input([r, allow], overrides: [unblock]),
                                                   at: at10, timeZone: tz), .allowed)
    }

    func testRaisingMaxPausesOnActiveGuardedIsLocked() {
        let r = local("lrule_work", maxPauses: 2)
        var more = r; more.maxPausesPerDay = 10
        XCTAssertNotEqual(ScheduleGuard.ruleChange(before: input([r]), after: input([more]), at: at10, timeZone: tz), .allowed)
    }

    func testFlexibleRulesNeverLocked() {
        let r = local("lrule_work", strictness: .flexible)
        XCTAssertEqual(ScheduleGuard.ruleChange(before: input([r]), after: input([]), at: at10, timeZone: tz), .allowed)
    }

    func testActiveStrictRuleLockedEvenWhenNotTheBlockReason() {
        // strict ⊇ guarded: a strict rule is locked while active, whatever wins the reason.
        let s = local("lrule_s", strictness: .strict)
        let o = Override(id: "ovr_b", groupIds: ["grp_social"], action: .block, startsAt: T.d("2026-11-09T17:00:00Z"),
                         endsAt: T.d("2026-11-09T20:00:00Z"), issuedAt: T.d("2026-11-09T17:00:00Z"))
        XCTAssertNotEqual(ScheduleGuard.ruleChange(before: input([s], overrides: [o]), after: input([], overrides: [o]),
                                                   at: at10, timeZone: tz), .allowed)
    }

    // MARK: isShrinkLocked

    func testShrinkLockedForActiveServerGuardedRule() {
        var r = local("rule_srv"); r.source = .server
        XCTAssertTrue(ScheduleGuard.isShrinkLocked(groupId: "grp_social", input([], server: [r]), at: at10, timeZone: tz))
    }

    func testShrinkLockedDuringPause() {
        let r = local("lrule_work")
        let pause = Pause(id: "pau_1", groupIds: ["grp_social"], startsAt: T.d("2026-11-09T17:58:00Z"), endsAt: T.d("2026-11-09T18:03:00Z"))
        XCTAssertTrue(ScheduleGuard.isShrinkLocked(groupId: "grp_social", input([r], pauses: [pause]), at: at10, timeZone: tz))
    }

    func testShrinkNotLockedAfterHours() {
        XCTAssertFalse(ScheduleGuard.isShrinkLocked(groupId: "grp_social", input([local("lrule_work")]), at: at18, timeZone: tz))
    }

    func testShrinkNotLockedForFlexible() {
        XCTAssertFalse(ScheduleGuard.isShrinkLocked(groupId: "grp_social", input([local("lrule_work", strictness: .flexible)]),
                                                    at: at10, timeZone: tz))
    }

    func testShrinkLockedForBlockOverride() {
        let o = Override(id: "ovr_b", groupIds: ["grp_social"], action: .block, startsAt: T.d("2026-11-09T17:00:00Z"),
                         endsAt: T.d("2026-11-09T20:00:00Z"), issuedAt: T.d("2026-11-09T17:00:00Z"))
        XCTAssertTrue(ScheduleGuard.isShrinkLocked(groupId: "grp_social", input([], overrides: [o]), at: at10, timeZone: tz))
        XCTAssertFalse(ScheduleGuard.isShrinkLocked(groupId: "grp_social", input([], overrides: [o]), at: at18, timeZone: tz))
    }

    func testShrinkLockedForStrictSession() {
        let s = FocusSession(id: "ses_1", groupIds: ["grp_social"], startsAt: T.d("2026-11-09T17:30:00Z"),
                             endsAt: T.d("2026-11-09T19:00:00Z"), strict: true)
        XCTAssertTrue(ScheduleGuard.isShrinkLocked(groupId: "grp_social", input([], sessions: [s]), at: at10, timeZone: tz))
    }
}
