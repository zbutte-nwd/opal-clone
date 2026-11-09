import XCTest
@testable import TetherCore

final class StateStoreTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = T.tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testFileName() { XCTAssertEqual(StateStore.fileName, "state.json") }

    func testMissingFileYieldsFreshState() throws {
        let store = StateStore(directory: dir)
        XCTAssertEqual(try store.load(), PersistedState())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "load must not create the file")
    }

    func testMissingDirectoryIsCreatedOnUpdate() throws {
        let nested = dir.appendingPathComponent("a/b")
        let store = StateStore(directory: nested)
        try store.update { $0.appliedBundleVersion = 3 }
        XCTAssertEqual(try store.load().appliedBundleVersion, 3)
    }

    func testRoundTrip() throws {
        let store = StateStore(directory: dir, pruneOnUpdate: false)
        let now = T.d("2026-11-09T17:00:00Z")
        let written = try store.update { s in
            s.bundle = PolicyBundle(version: 7, generatedAt: now, timeZone: "America/Los_Angeles", groups: [T.group("grp_social")])
            s.localGroups = [BlockGroup(id: "lgrp_1", name: "Mine", webDomains: ["x.com"], source: .local)]
            s.sessions = [FocusSession(id: "ses_1", name: "Deep work", groupIds: ["lgrp_1"], startsAt: now, endsAt: now.addingTimeInterval(1500), strict: true)]
            s.pauses = [Pause(id: "pau_1", groupIds: ["lgrp_1"], startsAt: now, endsAt: now.addingTimeInterval(300), ruleId: "r")]
            s.usageLimitHits = [UsageLimitHit(ruleId: "r", day: "2026-11-09")]
            s.appliedBundleVersion = 7; s.lastReconciledAt = now; s.lastSyncAt = now
            s.pendingEvents = [DeviceEvent(id: "evt_1", type: .heartbeat, occurredAt: now, data: ["k": "v"])]
            s.protection = ProtectionState(enabled: true, lock: .remoteApproval, authMode: .child, enabledAt: now)
            s.server = ServerConfig(baseURL: URL(string: "https://example.com")!, deviceId: "dev_1")
        }
        let loaded = try StateStore(directory: dir).load()
        XCTAssertEqual(loaded, written)
        XCTAssertEqual(loaded.bundle?.version, 7)
        XCTAssertEqual(loaded.engineInput.sessions.count, 1)
    }

    func testUpdateThatThrowsWritesNothing() throws {
        struct Boom: Error {}
        let store = StateStore(directory: dir)
        try store.update { $0.appliedBundleVersion = 1 }
        XCTAssertThrowsError(try store.update { s in s.appliedBundleVersion = 99; throw Boom() })
        XCTAssertEqual(try store.load().appliedBundleVersion, 1)
    }

    func testTolerantDecodeOfEmptyObject() throws {
        try Data("{}".utf8).write(to: dir.appendingPathComponent("state.json"))
        let s = try StateStore(directory: dir).load()
        XCTAssertEqual(s, PersistedState())
        XCTAssertEqual(s.schemaVersion, PersistedState.currentSchemaVersion)
    }

    func testTolerantDecodeMissingNewerKeys() throws {
        let json = """
        {"schemaVersion":1,"localGroups":[{"id":"lgrp_1","name":"G","webDomains":[],"source":"local"}],
         "appliedBundleVersion":5}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("state.json"))
        let s = try StateStore(directory: dir).load()
        XCTAssertEqual(s.localGroups.count, 1)
        XCTAssertEqual(s.appliedBundleVersion, 5)
        XCTAssertTrue(s.pendingEvents.isEmpty)
        XCTAssertNil(s.lastSyncAt)
        XCTAssertFalse(s.protection.enabled)
    }

    func testUnknownKeysIgnored() throws {
        try Data(#"{"schemaVersion":2,"futureThing":{"a":1}}"#.utf8).write(to: dir.appendingPathComponent("state.json"))
        XCTAssertEqual(try StateStore(directory: dir).load().schemaVersion, 2)
    }

    func testCorruptFileIsMovedAsideOnUpdate() throws {
        try Data("not json".utf8).write(to: dir.appendingPathComponent("state.json"))
        let store = StateStore(directory: dir)
        XCTAssertThrowsError(try store.load())
        let s = try store.update { $0.appliedBundleVersion = 2 }
        XCTAssertEqual(s.appliedBundleVersion, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("state.corrupt.json").path))
        XCTAssertEqual(try store.load().appliedBundleVersion, 2)
    }

    func testNoTempFilesLeftBehind() throws {
        let store = StateStore(directory: dir)
        for i in 0..<5 { try store.update { $0.appliedBundleVersion = i } }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["state.json"])
    }

    func testConcurrentUpdatesAreNotLost() throws {
        let store = StateStore(directory: dir, pruneOnUpdate: false)
        let other = StateStore(directory: dir, pruneOnUpdate: false)   // second instance, same file
        let n = 60
        var errors = [Error?](repeating: nil, count: n)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: n) { i in
            do {
                try (i % 2 == 0 ? store : other).update { $0.pendingEvents.append(DeviceEvent(id: "evt_\(i)", type: .heartbeat)) }
            } catch { lock.lock(); errors[i] = error; lock.unlock() }
        }
        XCTAssertTrue(errors.allSatisfy { $0 == nil })
        let s = try store.load()
        XCTAssertEqual(s.pendingEvents.count, n)
        XCTAssertEqual(Set(s.pendingEvents.map(\.id)).count, n)
    }

    // MARK: pruning

    func testPruneRules() {
        let now = T.d("2026-11-09T12:00:00Z")
        var s = PersistedState()
        let day: TimeInterval = 86400
        s.sessions = [
            FocusSession(id: "old", groupIds: [], startsAt: now.addingTimeInterval(-9 * day), endsAt: now.addingTimeInterval(-8 * day), strict: false),
            FocusSession(id: "oldEndedEarlier", groupIds: [], startsAt: now.addingTimeInterval(-9 * day), endsAt: now.addingTimeInterval(-1 * day), strict: false, endedAt: now.addingTimeInterval(-8.5 * day)),
            FocusSession(id: "recent", groupIds: [], startsAt: now.addingTimeInterval(-3 * day), endsAt: now.addingTimeInterval(-3 * day + 600), strict: false),
            FocusSession(id: "active", groupIds: [], startsAt: now, endsAt: now.addingTimeInterval(600), strict: false),
        ]
        s.pauses = [Pause(id: "oldp", groupIds: [], startsAt: now.addingTimeInterval(-8 * day), endsAt: now.addingTimeInterval(-8 * day + 300)),
                    Pause(id: "newp", groupIds: [], startsAt: now.addingTimeInterval(-1 * day), endsAt: now.addingTimeInterval(-1 * day + 300))]
        s.usageLimitHits = [UsageLimitHit(ruleId: "r", day: "2026-11-05"), UsageLimitHit(ruleId: "r", day: "2026-11-07"),
                            UsageLimitHit(ruleId: "r", day: "2026-11-09")]
        s.pendingEvents = (0..<510).map { DeviceEvent(id: "e\($0)", type: .heartbeat, occurredAt: now) }
        let p = s.pruned(now: now, timeZone: T.utc)
        XCTAssertEqual(p.sessions.map(\.id), ["recent", "active"])
        XCTAssertEqual(p.pauses.map(\.id), ["newp"])
        XCTAssertEqual(p.usageLimitHits.map(\.day), ["2026-11-07", "2026-11-09"])
        XCTAssertEqual(p.pendingEvents.count, 500)
        XCTAssertEqual(p.pendingEvents.first?.id, "e10", "oldest dropped")
        XCTAssertEqual(p.pendingEvents.last?.id, "e509")
    }

    func testUpdatePrunesWithInjectedClock() throws {
        let now = T.d("2026-11-09T12:00:00Z")
        let store = StateStore(directory: dir, clock: { now })
        let s = try store.update { s in
            s.sessions = [FocusSession(id: "old", groupIds: [], startsAt: now.addingTimeInterval(-20 * 86400), endsAt: now.addingTimeInterval(-19 * 86400), strict: false)]
        }
        XCTAssertTrue(s.sessions.isEmpty)
    }
}
