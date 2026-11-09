import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TetherCore
@testable import TetherAPI

final class SyncEngineTests: XCTestCase {
    let base = URL(string: "https://tether.example.com")!
    override func setUp() { StubURLProtocol.reset() }

    func api() -> APIClient { APIClient(baseURL: base, tokenProvider: { "td_x" }, session: StubURLProtocol.makeSession()) }

    func engine(store: InMemoryStore, changed: Counter = Counter(), blocked: @escaping @Sendable () async -> [String] = { ["grp_social"] }) -> SyncEngine {
        SyncEngine(api: api(), store: store, now: { Date(timeIntervalSince1970: 1_800_000_000) },
                   blockedGroupIdsProvider: blocked, jitter: { 1.0 }, onBundleChanged: { changed.increment() })
    }

    func bundleData(_ v: Int) throws -> Data {
        try TetherJSON.makeEncoder().encode(Fixtures.bundle(version: v))
    }

    func testNotModified() async throws {
        var s = PersistedState(); s.bundle = try Fixtures.bundle(version: 42)
        let store = InMemoryStore(s); let changed = Counter()
        StubURLProtocol.handler = { r in r.path.hasSuffix("/policy") ? (304, [:], Data()) : (204, [:], Data()) }
        let e = engine(store: store, changed: changed)
        let out = await e.syncNow(reason: .manual)
        XCTAssertEqual(out, .noChange)
        XCTAssertEqual(changed.value, 0)
        let policyReq = try XCTUnwrap(StubURLProtocol.recorded.first { $0.path.hasSuffix("/policy") })
        XCTAssertEqual(policyReq.header("If-None-Match"), "\"42\"")
        XCTAssertNotNil(try store.load().lastSyncAt)
    }

    func testNewBundleStoresCallsBackAndAcks() async throws {
        let store = InMemoryStore(); let changed = Counter()
        let body = try bundleData(43)
        StubURLProtocol.handler = { r in r.path.hasSuffix("/policy") ? (200, [:], body) : (204, [:], Data()) }
        let out = await engine(store: store, changed: changed).syncNow(reason: .launch)
        XCTAssertEqual(out, .updated(version: 43))
        XCTAssertEqual(changed.value, 1)
        XCTAssertEqual(try store.load().bundle?.version, 43)
        XCTAssertEqual(try store.load().lastSyncAt, Date(timeIntervalSince1970: 1_800_000_000))
        let policyReq = try XCTUnwrap(StubURLProtocol.recorded.first { $0.path.hasSuffix("/policy") })
        XCTAssertNil(policyReq.header("If-None-Match"))
        let ack = try XCTUnwrap(StubURLProtocol.recorded.first { $0.path.hasSuffix("/ack") })
        XCTAssertEqual(ack.json()?["version"] as? Int, 43)
        XCTAssertEqual(ack.json()?["blockedGroupIds"] as? [String], ["grp_social"])
        XCTAssertEqual(ack.json()?["authorizationStatus"] as? String, "approved")
        // second sync with 304 must not re-ack
        StubURLProtocol.handler = { r in r.path.hasSuffix("/policy") ? (304, [:], Data()) : (204, [:], Data()) }
        let acksBefore = StubURLProtocol.recorded.filter { $0.path.hasSuffix("/ack") }.count
        _ = await engine(store: store, changed: changed).syncNow(reason: .manual)
        XCTAssertEqual(StubURLProtocol.recorded.filter { $0.path.hasSuffix("/ack") }.count, acksBefore + 1) // new engine instance acks once
    }

    func testEventsFlushedAndRemoved() async throws {
        var s = PersistedState()
        s.pendingEvents = [DeviceEvent(id: "evt_1", type: .heartbeat), DeviceEvent(id: "evt_2", type: .sessionStarted)]
        let store = InMemoryStore(s)
        StubURLProtocol.handler = { r in
            r.path.hasSuffix("/policy") ? (304, [:], Data()) : r.path.hasSuffix("/events") ? (202, [:], Data()) : (204, [:], Data())
        }
        let out = await engine(store: store).syncNow(reason: .foreground)
        XCTAssertEqual(out, .noChange)
        XCTAssertTrue(try store.load().pendingEvents.isEmpty)
        let ev = try XCTUnwrap(StubURLProtocol.recorded.first { $0.path.hasSuffix("/events") })
        XCTAssertEqual((ev.json()?["events"] as? [[String: Any]])?.count, 2)
        // events are posted before policy is fetched
        XCTAssertTrue(StubURLProtocol.recorded[0].path.hasSuffix("/events"))
    }

    func testEventsKeptOnFailure() async throws {
        var s = PersistedState(); s.pendingEvents = [DeviceEvent(id: "evt_1", type: .heartbeat)]
        let store = InMemoryStore(s)
        StubURLProtocol.handler = { r in r.path.hasSuffix("/events") ? (503, [:], Data()) : (304, [:], Data()) }
        let out = await engine(store: store).syncNow(reason: .foreground)
        XCTAssertEqual(out, .failed(retryAfter: 1))
        XCTAssertEqual(try store.load().pendingEvents.count, 1)
    }

    func testUnauthorized() async throws {
        StubURLProtocol.handler = { _ in (401, [:], Data(#"{"error":{"code":"unauthorized","message":"revoked"}}"#.utf8)) }
        let out = await engine(store: InMemoryStore()).syncNow(reason: .manual)
        XCTAssertEqual(out, .unauthorized)
    }

    func testBackoffGrowsAndCapsAndResets() async throws {
        StubURLProtocol.handler = { _ in (503, [:], Data()) }
        let e = engine(store: InMemoryStore())
        var delays: [TimeInterval] = []
        for _ in 0..<12 {
            if case .failed(let d?) = await e.syncNow(reason: .manual) { delays.append(d) }
        }
        XCTAssertEqual(Array(delays.prefix(5)), [1, 2, 4, 8, 16])
        XCTAssertEqual(delays.last, 300)
        XCTAssertEqual(delays.max(), 300)
        let nrd = await e.nextRetryDelay
        XCTAssertEqual(nrd, 300)
        StubURLProtocol.handler = { _ in (304, [:], Data()) }
        let out = await e.syncNow(reason: .manual)
        XCTAssertEqual(out, .noChange)
        let after = await e.nextRetryDelay
        XCTAssertNil(after)
        XCTAssertEqual(SyncEngine.backoffDelay(failures: 1), 1)
        XCTAssertEqual(SyncEngine.backoffDelay(failures: 30), 300)
    }

    func testNonRetryableErrorHasNoDelay() async {
        StubURLProtocol.handler = { _ in (404, [:], Data()) }
        let out = await engine(store: InMemoryStore()).syncNow(reason: .manual)
        XCTAssertEqual(out, .failed(retryAfter: nil))
    }

    func testConcurrentSyncCoalesces() async throws {
        let policyHits = Counter()
        StubURLProtocol.handler = { r in
            if r.path.hasSuffix("/policy") { policyHits.increment(); Thread.sleep(forTimeInterval: 0.3) }
            return (304, [:], Data())
        }
        let e = engine(store: InMemoryStore())
        async let a = e.syncNow(reason: .manual)
        async let b = e.syncNow(reason: .foreground)
        async let c = e.syncNow(reason: .push)
        let results = await [a, b, c]
        XCTAssertEqual(results, [.noChange, .noChange, .noChange])
        XCTAssertEqual(policyHits.value, 1)
    }

    func testInlineBundlePushSkipsFetchAndAcks() async throws {
        let store = InMemoryStore(); let changed = Counter()
        StubURLProtocol.handler = { _ in (204, [:], Data()) }
        let out = await engine(store: store, changed: changed).handlePush(try Fixtures.object("push-silent-inline-bundle.json"))
        XCTAssertEqual(out, .updated(version: 42))
        XCTAssertEqual(changed.value, 1)
        XCTAssertEqual(try store.load().bundle?.version, 42)
        XCTAssertFalse(StubURLProtocol.recorded.contains { $0.path.hasSuffix("/policy") })
        XCTAssertEqual(StubURLProtocol.recorded.filter { $0.path.hasSuffix("/ack") }.count, 1)
    }

    func testOlderInlineBundleIgnored() async throws {
        var s = PersistedState(); s.bundle = try Fixtures.bundle(version: 50)
        let store = InMemoryStore(s); let changed = Counter()
        StubURLProtocol.handler = { _ in (204, [:], Data()) }
        let out = await engine(store: store, changed: changed).handlePush(try Fixtures.object("push-silent-inline-bundle.json"))
        XCTAssertEqual(out, .noChange)
        XCTAssertEqual(changed.value, 0)
        XCTAssertEqual(try store.load().bundle?.version, 50)
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    func testPushWithoutBundleFetches() async throws {
        let store = InMemoryStore(); let changed = Counter()
        let body = try bundleData(42)
        StubURLProtocol.handler = { r in r.path.hasSuffix("/policy") ? (200, [:], body) : (204, [:], Data()) }
        let out = await engine(store: store, changed: changed).handlePush(try Fixtures.object("push-policy-updated.json"))
        XCTAssertEqual(out, .updated(version: 42))
        XCTAssertEqual(changed.value, 1)
    }

    func testUnlockDecidedPush() async {
        StubURLProtocol.handler = { _ in (204, [:], Data()) }
        let out = await engine(store: InMemoryStore()).handlePush(["tether": ["type": "unlockDecided", "requestId": "unl_7"]])
        XCTAssertEqual(out, .unlockDecided(requestId: "unl_7"))
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    func testEnrollStoresServerConfig() async throws {
        let store = InMemoryStore()
        StubURLProtocol.handler = { _ in (201, [:], try Fixtures.data("enroll-response.json")) }
        let server = URL(string: "https://other.example.com")!
        let token = try await engine(store: store).enroll(pairingCode: "k7q2 m9xd", server: server,
                                                          deviceInfo: DeviceInfo(name: "P", model: "iPhone", osVersion: "17", appVersion: "1"))
        XCTAssertEqual(token, "td_Zm9vYmFyYmF6cXV4")
        XCTAssertEqual(try store.load().server, ServerConfig(baseURL: server, deviceId: "dev_8f3k2j"))
        let r = StubURLProtocol.recorded[0]
        XCTAssertEqual(r.request.url?.host, "other.example.com")
        XCTAssertEqual(r.json()?["pairingCode"] as? String, "K7Q2-M9XD")
        XCTAssertNil(r.header("Authorization"))
    }
}
