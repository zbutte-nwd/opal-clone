import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TetherCore
@testable import TetherAPI

final class LocalSnapshotTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let base = URL(string: "https://tether.example.com")!
    override func setUp() { StubURLProtocol.reset() }

    func state(groupName: String = "Socials", paired: Bool = true) -> PersistedState {
        var s = PersistedState()
        s.localGroups = [BlockGroup(id: "lgrp_socials1", name: groupName, colorHex: "#FF5A5F", webDomains: ["instagram.com"], source: .local)]
        s.localRules = [Rule(id: "lrule_work1", name: "Work", groupIds: ["lgrp_socials1"],
                             trigger: .schedule(windows: [Window(days: [1, 2, 3, 4, 5], start: "09:00", end: "17:00")]),
                             strictness: .guarded, maxPausesPerDay: 3, source: .local)]
        s.sessions = [
            FocusSession(id: "ses_old", groupIds: ["lgrp_socials1"], startsAt: now.addingTimeInterval(-50 * 3600),
                         endsAt: now.addingTimeInterval(-49 * 3600), strict: false),
            FocusSession(id: "ses_now", name: "Deep work", groupIds: ["lgrp_socials1"], startsAt: now.addingTimeInterval(-600),
                         endsAt: now.addingTimeInterval(1800), strict: false),
        ]
        s.pauses = [Pause(id: "pau_done", groupIds: ["lgrp_socials1"], startsAt: now.addingTimeInterval(-900), endsAt: now.addingTimeInterval(-600)),
                    Pause(id: "pau_now", groupIds: ["lgrp_socials1"], startsAt: now.addingTimeInterval(-60), endsAt: now.addingTimeInterval(240))]
        s.protection.enabled = true
        if paired { s.server = ServerConfig(baseURL: base, deviceId: "dev_1") }
        return s
    }

    func snap(_ s: PersistedState, at t: Date? = nil) -> LocalSnapshot {
        LocalSnapshot.make(state: s, counts: ["lgrp_socials1": .init(apps: 3, categories: 1)], protectionLock: .partnerPIN, now: t ?? now)
    }

    func testHashIgnoresReportedAt() {
        let a = snap(state()), b = snap(state(), at: now.addingTimeInterval(1))
        XCTAssertNotEqual(a.reportedAt, b.reportedAt)
        XCTAssertEqual(a.hash, b.hash)
        XCTAssertEqual(a.hash.count, 64)
    }

    func testHashChangesWhenGroupRenamed() {
        XCTAssertNotEqual(snap(state()).hash, snap(state(groupName: "Social media")).hash)
    }

    func testSessionAndPauseWindows() {
        let s = snap(state())
        XCTAssertEqual(s.sessions.map(\.id), ["ses_now"])      // ended > 24 h ago is dropped
        XCTAssertEqual(s.pauses.map(\.id), ["pau_now"])        // ended pauses are dropped
        XCTAssertEqual(s.groups.first?.counts, .init(apps: 3, categories: 1, webTokens: 0))
    }

    /// Every key in the encoded JSON must exist in contracts/device-local.schema.json (no token fields).
    func testEncodingHasNoTokenFields() throws {
        let data = try TetherJSON.makeEncoder().encode(snap(state()))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["hash", "reportedAt", "groups", "rules", "sessions", "pauses", "settings"])
        let g = try XCTUnwrap((json["groups"] as? [[String: Any]])?.first)
        XCTAssertTrue(Set(g.keys).isSubset(of: ["id", "name", "colorHex", "webDomains", "counts"]), "\(g.keys)")
        XCTAssertEqual(Set((g["counts"] as? [String: Any])?.keys ?? [:].keys), ["apps", "categories", "webTokens"])
        XCTAssertEqual(Set((json["settings"] as? [String: Any])?.keys ?? [:].keys), ["protectionEnabled", "protectionLock"])
        XCTAssertEqual((json["rules"] as? [[String: Any]])?.first?["source"] as? String, "local")
    }

    // MARK: Upload via SyncEngine

    func engine(_ store: InMemoryStore, snapshot: LocalSnapshot?) -> SyncEngine {
        SyncEngine(api: APIClient(baseURL: base, tokenProvider: { "td_x" }, session: StubURLProtocol.makeSession()),
                   store: store, now: { self.now }, snapshotProvider: { snapshot }, jitter: { 1.0 }, onBundleChanged: {})
    }

    var puts: [RecordedRequest] { StubURLProtocol.recorded.filter { $0.method == "PUT" && $0.path.hasSuffix("/devices/me/local") } }

    func testUploadsOnceThenOnlyWhenChanged() async {
        let store = InMemoryStore(state())
        StubURLProtocol.handler = { r in r.path.hasSuffix("/policy") ? (304, [:], Data()) : (204, [:], Data()) }
        let e = engine(store, snapshot: snap(state()))
        _ = await e.syncNow(reason: .manual)
        _ = await e.syncNow(reason: .manual)
        XCTAssertEqual(puts.count, 1, "unchanged hash is not re-uploaded")
        XCTAssertEqual(puts.first?.json()?["hash"] as? String, snap(state()).hash)
    }

    func testServerTooOldKeepsSnapshotForRetry() async {
        let store = InMemoryStore(state())
        StubURLProtocol.handler = { r in
            if r.path.hasSuffix("/policy") { return (304, [:], Data()) }
            if r.path.hasSuffix("/local") { return (404, [:], Data(#"{"error":{"code":"not_found","message":"Not found"}}"#.utf8)) }
            return (204, [:], Data())
        }
        let e = engine(store, snapshot: snap(state()))
        let out = await e.syncNow(reason: .manual)
        XCTAssertEqual(out, .noChange, "a missing endpoint never fails the sync")
        let recorded = await e.lastUploadedSnapshotHash
        XCTAssertNil(recorded)
        _ = await e.syncNow(reason: .manual)
        XCTAssertEqual(puts.count, 2, "retried on the next sync")
    }

    func testNoUploadWhenUnpaired() async {
        let store = InMemoryStore(state(paired: false))
        StubURLProtocol.handler = { r in r.path.hasSuffix("/policy") ? (304, [:], Data()) : (204, [:], Data()) }
        await engine(store, snapshot: snap(state(paired: false))).uploadSnapshotIfChanged()
        XCTAssertEqual(puts.count, 0)
    }
}
