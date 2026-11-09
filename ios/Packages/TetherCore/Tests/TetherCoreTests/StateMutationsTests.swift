import XCTest
@testable import TetherCore

final class StateMutationsTests: XCTestCase {
    let now = T.d("2026-11-09T17:00:00Z")      // Mon 09:00 PST

    func schoolState(maxPauses: Int? = nil, strict: Bool = false) -> PersistedState {
        var s = PersistedState()
        s.bundle = PolicyBundle(version: 1, generatedAt: now, timeZone: "America/Los_Angeles",
                                groups: [T.group("grp_social", "Social")],
                                rules: [T.rule("rule_school", groups: ["grp_social"], windows: [Window(days: T.weekdays, start: "08:00", end: "15:00")], name: "School hours", strict: strict, maxPauses: maxPauses)])
        return s
    }

    func testStartSession() {
        var s = PersistedState()
        let ses = s.startSession(groupIds: ["lgrp_1"], duration: 25 * 60, strict: false, name: "Deep work", now: now)
        XCTAssertTrue(ses.id.hasPrefix("ses_"))
        XCTAssertEqual(ses.startsAt, now); XCTAssertEqual(ses.endsAt, now.addingTimeInterval(1500))
        XCTAssertEqual(ses.name, "Deep work")
        XCTAssertEqual(s.sessions, [ses])
        XCTAssertEqual(s.pendingEvents.last?.type, .sessionStarted)
        XCTAssertEqual(s.pendingEvents.last?.data?["sessionId"], ses.id)
        // Evaluated by the engine immediately.
        s.localGroups = [BlockGroup(id: "lgrp_1", name: "Mine", source: .local)]
        XCTAssertTrue(PolicyEngine.evaluate(s.engineInput, at: now.addingTimeInterval(1), timeZone: T.utc)["lgrp_1"]!.blocked)
    }

    func testDurationClamped() {
        var s = PersistedState()
        XCTAssertEqual(s.startSession(groupIds: [], duration: -5, strict: false, now: now).endsAt, now.addingTimeInterval(60))
    }

    func testStrictSessionCannotEndEarly() throws {
        var s = PersistedState()
        let ses = s.startSession(groupIds: ["g"], duration: 1800, strict: true, now: now)
        XCTAssertThrowsError(try s.endSession(id: ses.id, now: now.addingTimeInterval(600))) { e in
            XCTAssertEqual(e as? StateMutationError, .strictSessionActive(endsAt: ses.endsAt))
        }
        XCTAssertNil(s.sessions[0].endedAt)
        // Once over it is a no-op (no throw, nothing changed).
        try s.endSession(id: ses.id, now: ses.endsAt.addingTimeInterval(1))
        XCTAssertNil(s.sessions[0].endedAt)
    }

    func testFlexibleSessionEndsEarly() throws {
        var s = PersistedState()
        let ses = s.startSession(groupIds: ["g"], duration: 1800, strict: false, now: now)
        let t = now.addingTimeInterval(600)
        try s.endSession(id: ses.id, now: t)
        XCTAssertEqual(s.sessions[0].endedAt, t)
        XCTAssertEqual(s.pendingEvents.last?.type, .sessionEnded)
        let count = s.pendingEvents.count
        try s.endSession(id: ses.id, now: t.addingTimeInterval(5))      // idempotent
        XCTAssertEqual(s.pendingEvents.count, count)
        XCTAssertEqual(s.sessions[0].endedAt, t)
    }

    func testEndUnknownSessionThrows() {
        var s = PersistedState()
        XCTAssertThrowsError(try s.endSession(id: "nope", now: now)) { XCTAssertEqual($0 as? StateMutationError, .sessionNotFound("nope")) }
    }

    func testStartPauseSetsRuleId() throws {
        var s = schoolState(maxPauses: 3)
        let p = try s.startPause(groupId: "grp_social", minutes: 5, now: now, timeZone: T.la)
        XCTAssertEqual(p.ruleId, "rule_school")
        XCTAssertEqual(p.endsAt, now.addingTimeInterval(300))
        XCTAssertEqual(p.groupIds, ["grp_social"])
        XCTAssertEqual(s.pauses, [p])
        XCTAssertEqual(s.pendingEvents.last?.type, .pauseStarted)
        XCTAssertFalse(PolicyEngine.evaluate(s.engineInput, at: now.addingTimeInterval(10), timeZone: T.la)["grp_social"]!.blocked)
    }

    func testPauseBudget() throws {
        var s = schoolState(maxPauses: 2)
        try s.startPause(groupId: "grp_social", minutes: 1, now: now, timeZone: T.la)
        try s.startPause(groupId: "grp_social", minutes: 1, now: now.addingTimeInterval(120), timeZone: T.la)
        XCTAssertThrowsError(try s.startPause(groupId: "grp_social", minutes: 1, now: now.addingTimeInterval(240), timeZone: T.la)) {
            XCTAssertEqual($0 as? StateMutationError, .pauseBudgetExhausted(limit: 2))
        }
        XCTAssertEqual(s.pauses.count, 2)
        // Next day the budget resets.
        XCTAssertNoThrow(try s.startPause(groupId: "grp_social", minutes: 1, now: now.addingTimeInterval(86400), timeZone: T.la))
    }

    func testPauseRejections() {
        var strict = schoolState(strict: true)
        XCTAssertThrowsError(try strict.startPause(groupId: "grp_social", minutes: 5, now: now, timeZone: T.la)) { XCTAssertEqual($0 as? StateMutationError, .strictBlock("grp_social")) }
        var s = schoolState()
        XCTAssertThrowsError(try s.startPause(groupId: "grp_social", minutes: 5, now: T.d("2026-11-09T23:30:00Z"), timeZone: T.la)) { XCTAssertEqual($0 as? StateMutationError, .groupNotBlocked("grp_social")) }
        XCTAssertThrowsError(try s.startPause(groupId: "grp_social", minutes: 0, now: now, timeZone: T.la)) { XCTAssertEqual($0 as? StateMutationError, .invalidDuration) }
        XCTAssertTrue(s.pauses.isEmpty)
    }

    func testPauseDuringSessionHasNoRuleId() throws {
        var s = PersistedState()
        s.localGroups = [BlockGroup(id: "lgrp_1", name: "Mine", source: .local)]
        s.startSession(groupIds: ["lgrp_1"], duration: 1800, strict: false, now: now)
        let p = try s.startPause(groupId: "lgrp_1", minutes: 5, now: now.addingTimeInterval(10), timeZone: T.utc)
        XCTAssertNil(p.ruleId)
    }

    func testRecordUsageLimitHitIdempotentPerDay() {
        var s = PersistedState()
        XCTAssertTrue(s.recordUsageLimitHit(ruleId: "r", now: now, timeZone: T.la))
        XCTAssertFalse(s.recordUsageLimitHit(ruleId: "r", now: now.addingTimeInterval(60), timeZone: T.la))
        XCTAssertEqual(s.usageLimitHits, [UsageLimitHit(ruleId: "r", day: "2026-11-09")])
        XCTAssertEqual(s.pendingEvents.filter { $0.type == .usageLimitReached }.count, 1)
        XCTAssertTrue(s.recordUsageLimitHit(ruleId: "r", now: now.addingTimeInterval(86400), timeZone: T.la))
        XCTAssertTrue(s.recordUsageLimitHit(ruleId: "r2", now: now, timeZone: T.la))
        XCTAssertEqual(s.usageLimitHits.count, 3)
    }

    func testEnqueueCapsAt500DroppingOldest() {
        var s = PersistedState()
        for i in 0..<520 { s.enqueue(event: DeviceEvent(id: "e\(i)", type: .heartbeat, occurredAt: now)) }
        XCTAssertEqual(s.pendingEvents.count, 500)
        XCTAssertEqual(s.pendingEvents.first?.id, "e20")
        XCTAssertEqual(s.pendingEvents.last?.id, "e519")
    }

    func testApplyBundle() {
        var s = PersistedState()
        let b = PolicyBundle(version: 4, generatedAt: now)
        XCTAssertTrue(s.applyBundle(b))
        XCTAssertFalse(s.applyBundle(b))
        XCTAssertEqual(s.bundle, b)
        XCTAssertNil(s.appliedBundleVersion)
        XCTAssertTrue(s.applyBundle(PolicyBundle(version: 5, generatedAt: now)))
        XCTAssertEqual(s.bundle?.version, 5)
    }

    func testMutationsThroughStore() throws {
        let dir = T.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(directory: dir)
        let ses = try store.update { $0.startSession(groupIds: ["g"], duration: 600, strict: true) }.sessions[0]
        XCTAssertThrowsError(try store.update { try $0.endSession(id: ses.id) })
        XCTAssertEqual(try store.load().sessions.count, 1)
    }
}
