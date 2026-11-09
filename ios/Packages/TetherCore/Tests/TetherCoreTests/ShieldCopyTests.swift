import XCTest
@testable import TetherCore

final class ShieldCopyTests: XCTestCase {
    // Deterministic formatting (en_US, fixed zone).
    let fmt = ShieldCopy.Formatter.standard(locale: Locale(identifier: "en_US_POSIX"), timeZone: T.la)
    let simple = ShieldCopy.Formatter(
        time: { d in
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = T.la; f.dateFormat = "h:mm a"; return f.string(from: d) },
        weekdayTime: { d in
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = T.la; f.dateFormat = "EEE h:mm a"; return f.string(from: d) })
    let now = T.d("2026-11-09T17:00:00Z")         // Mon 9:00 AM PST

    func copy(_ input: EngineInput, until: Date? = nil) -> ShieldCopy {
        var st = PolicyEngine.evaluate(input, at: now, timeZone: T.la)["grp_social"]!
        st.until = until
        return ShieldCopy.make(groupId: "grp_social", state: st, input: input, now: now, timeZone: T.la, formatter: simple)
    }

    func testRuleBlockWithUntil() {
        let rule = T.rule("rule_school", groups: ["grp_social"], windows: [Window(days: T.weekdays, start: "08:00", end: "15:00")], name: "School hours")
        let c = copy(T.input(rules: [rule]), until: T.d("2026-11-09T23:00:00Z"))
        XCTAssertEqual(c.title, "Social is blocked")
        XCTAssertEqual(c.subtitle, "School hours · until 3:00 PM")
        XCTAssertTrue(c.showsUnlockButton)
        XCTAssertEqual(c.unlockButtonTitle, "Unlock for 5 min")
    }

    func testRuleBlockUntilTomorrowShowsWeekday() {
        let rule = T.rule("rule_school", groups: ["grp_social"], windows: [Window(days: T.weekdays, start: "08:00", end: "15:00")], name: "School hours")
        XCTAssertEqual(copy(T.input(rules: [rule]), until: T.d("2026-11-10T16:00:00Z")).subtitle, "School hours · until Tue 8:00 AM")
    }

    func testRuleWithoutUntil() {
        let rule = T.rule("rule_school", groups: ["grp_social"], windows: [Window(days: T.weekdays, start: "08:00", end: "15:00")], name: "School hours")
        XCTAssertEqual(copy(T.input(rules: [rule])).subtitle, "School hours")
    }

    func testStrictRuleHidesUnlock() {
        let rule = T.rule("rule_school", groups: ["grp_social"], windows: [Window(days: T.weekdays, start: "08:00", end: "15:00")], strict: true)
        XCTAssertFalse(copy(T.input(rules: [rule])).showsUnlockButton)
    }

    func testFocusSessionMinutesLeft() {
        let s = FocusSession(id: "ses_1", name: "Deep work", groupIds: ["grp_social"], startsAt: now.addingTimeInterval(-60), endsAt: now.addingTimeInterval(12 * 60 - 20), strict: false)
        let c = copy(T.input(sessions: [s]))
        XCTAssertEqual(c.subtitle, "Deep work · 12 min left")
        XCTAssertTrue(c.showsUnlockButton)
        let unnamed = FocusSession(id: "ses_2", groupIds: ["grp_social"], startsAt: now.addingTimeInterval(-60), endsAt: now.addingTimeInterval(75 * 60), strict: true)
        let c2 = copy(T.input(sessions: [unnamed]))
        XCTAssertEqual(c2.subtitle, "Focus session · 1 hr 15 min left")
        XCTAssertFalse(c2.showsUnlockButton)
    }

    func testOverrideBlockedByAdmin() {
        let ov = Override(id: "ovr_1", groupIds: ["grp_social"], action: .block, startsAt: now.addingTimeInterval(-60), issuedAt: now)
        let c = copy(T.input(overrides: [ov]))
        XCTAssertEqual(c.subtitle, "Blocked by your admin")
        XCTAssertFalse(c.showsUnlockButton)
        XCTAssertEqual(copy(T.input(overrides: [ov]), until: T.d("2026-11-09T23:00:00Z")).subtitle, "Blocked by your admin · until 3:00 PM")
    }

    func testUnknownGroupFallsBackAndUnblockedState() {
        let st = GroupState(groupId: "x", blocked: false)
        let c = ShieldCopy.make(groupId: "x", state: st, input: EngineInput(), now: now, timeZone: T.la, formatter: simple)
        XCTAssertEqual(c.title, "This app is unblocked")
        XCTAssertFalse(c.showsUnlockButton)
        XCTAssertEqual(c.subtitle, "")
    }

    func testStandardFormatterProducesTime() {
        let s = fmt.time(T.d("2026-11-09T23:00:00Z"))
        XCTAssertTrue(s.contains("3:00"), s)
    }

    func testMinutesLabel() {
        XCTAssertEqual(ShieldCopy.minutesLabel(1), "1 min")
        XCTAssertEqual(ShieldCopy.minutesLabel(60), "1 hr")
        XCTAssertEqual(ShieldCopy.minutesLabel(135), "2 hr 15 min")
    }
}
