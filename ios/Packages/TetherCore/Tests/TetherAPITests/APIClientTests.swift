import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TetherCore
@testable import TetherAPI

final class APIClientTests: XCTestCase {
    let base = URL(string: "https://tether.example.com")!

    override func setUp() { StubURLProtocol.reset() }

    func client(token: String? = "td_abc") -> APIClient {
        APIClient(baseURL: base, tokenProvider: { token }, session: StubURLProtocol.makeSession(), appVersion: "1.2.3")
    }
    func json(_ s: String) -> Data { Data(s.utf8) }

    func testEnrollNoAuth() async throws {
        StubURLProtocol.handler = { _ in (201, [:], try Fixtures.data("enroll-response.json")) }
        let r = try await client(token: nil).enroll(EnrollRequest(pairingCode: "K7Q2-M9XD", name: "Phone", model: "iPhone15,2", osVersion: "17.4", appVersion: "1.0"))
        XCTAssertEqual(r.deviceId, "dev_8f3k2j"); XCTAssertEqual(r.deviceToken, "td_Zm9vYmFyYmF6cXV4")
        let req = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(req.method, "POST"); XCTAssertEqual(req.path, "/v1/devices/enroll")
        XCTAssertNil(req.header("Authorization"))
        XCTAssertEqual(req.header("User-Agent"), "Tether-iOS/1.2.3")
        XCTAssertEqual(req.header("Content-Type"), "application/json")
        XCTAssertEqual(req.request.timeoutInterval, 15)
        let b = try XCTUnwrap(req.json())
        XCTAssertEqual(b["pairingCode"] as? String, "K7Q2-M9XD"); XCTAssertEqual(b["name"] as? String, "Phone")
        XCTAssertEqual(b["model"] as? String, "iPhone15,2"); XCTAssertEqual(b["osVersion"] as? String, "17.4")
        XCTAssertEqual(b["appVersion"] as? String, "1.0")
    }

    func testBaseURLWithV1Suffix() async throws {
        StubURLProtocol.handler = { _ in (204, [:], Data()) }
        let c = APIClient(baseURL: URL(string: "https://h.example/v1/")!, tokenProvider: { "t" }, session: StubURLProtocol.makeSession())
        try await c.unpair()
        XCTAssertEqual(StubURLProtocol.recorded.first?.path, "/v1/devices/me")
    }

    func testFetchPolicyUpdatedAndHeaders() async throws {
        StubURLProtocol.handler = { _ in (200, ["ETag": "\"42\""], try Fixtures.data("policy-bundle.example.json")) }
        let r = try await client().fetchPolicy(ifNoneMatch: 41)
        guard case .updated(let b) = r else { return XCTFail() }
        XCTAssertEqual(b.version, 42)
        let req = StubURLProtocol.recorded[0]
        XCTAssertEqual(req.method, "GET"); XCTAssertEqual(req.path, "/v1/devices/me/policy")
        XCTAssertEqual(req.header("If-None-Match"), "\"41\"")
        XCTAssertEqual(req.header("Authorization"), "Bearer td_abc")
    }

    func testFetchPolicyNotModifiedAndNoHeaderWhenNil() async throws {
        StubURLProtocol.handler = { _ in (304, [:], Data()) }
        let r = try await client().fetchPolicy(ifNoneMatch: nil)
        XCTAssertEqual(r, .notModified)
        XCTAssertNil(StubURLProtocol.recorded[0].header("If-None-Match"))
    }

    func testAck() async throws {
        StubURLProtocol.handler = { _ in (204, [:], Data()) }
        let fixture = try JSONSerialization.jsonObject(with: Fixtures.data("ack-request.json")) as! [String: Any]
        let ack = try TetherJSON.makeDecoder().decode(AckRequest.self, from: Fixtures.data("ack-request.json"))
        XCTAssertEqual(ack.version, 42)
        try await client().ack(ack)
        let req = StubURLProtocol.recorded[0]
        XCTAssertEqual(req.method, "POST"); XCTAssertEqual(req.path, "/v1/devices/me/ack")
        let b = try XCTUnwrap(req.json())
        XCTAssertEqual(b["version"] as? Int, 42)
        XCTAssertEqual(b["appliedAt"] as? String, fixture["appliedAt"] as? String)
        XCTAssertEqual(b["blockedGroupIds"] as? [String], ["grp_social"])
        XCTAssertEqual(b["authorizationStatus"] as? String, "approved")
    }

    func testPostEvents() async throws {
        StubURLProtocol.handler = { _ in (202, [:], Data()) }
        let req = try TetherJSON.makeDecoder().decode(EventsRequest.self, from: Fixtures.data("events-request.json"))
        XCTAssertEqual(req.events.count, 2)
        try await client().postEvents(req.events)
        let r = StubURLProtocol.recorded[0]
        XCTAssertEqual(r.method, "POST"); XCTAssertEqual(r.path, "/v1/devices/me/events")
        let evs = try XCTUnwrap(r.json()?["events"] as? [[String: Any]])
        XCTAssertEqual(evs.count, 2)
        XCTAssertEqual(evs[0]["id"] as? String, "evt_01"); XCTAssertEqual(evs[0]["type"] as? String, "authorizationChanged")
        XCTAssertEqual((evs[0]["data"] as? [String: String])?["status"], "denied")
        XCTAssertNil(evs[1]["data"])
    }

    func testPushToken() async throws {
        StubURLProtocol.handler = { _ in (204, [:], Data()) }
        try await client().updatePushToken(PushTokenRequest(tokenData: Data([0xde, 0xad, 0x0b]), environment: .sandbox))
        let r = StubURLProtocol.recorded[0]
        XCTAssertEqual(r.method, "PUT"); XCTAssertEqual(r.path, "/v1/devices/me/push-token")
        XCTAssertEqual(r.json()?["token"] as? String, "dead0b")
        XCTAssertEqual(r.json()?["environment"] as? String, "sandbox")
    }

    let unlockJSON = """
    {"id":"unl_1","deviceId":"dev_1","kind":"groups","groupIds":["grp_social"],"minutes":15,"reason":"hw",
     "status":"pending","createdAt":"2026-11-09T17:00:00Z"}
    """

    func testCreateAndGetUnlockRequest() async throws {
        StubURLProtocol.handler = { [unlockJSON] r in (r.method == "POST" ? 201 : 200, [:], Data(unlockJSON.utf8)) }
        let u = try await client().createUnlockRequest(CreateUnlockRequest(kind: .groups, groupIds: ["grp_social"], minutes: 15, reason: "hw"))
        XCTAssertEqual(u.id, "unl_1"); XCTAssertEqual(u.status, .pending); XCTAssertEqual(u.minutes, 15)
        var r = StubURLProtocol.recorded[0]
        XCTAssertEqual(r.method, "POST"); XCTAssertEqual(r.path, "/v1/devices/me/unlock-requests")
        XCTAssertEqual(r.json()?["kind"] as? String, "groups"); XCTAssertEqual(r.json()?["minutes"] as? Int, 15)
        let g = try await client().getUnlockRequest(id: "unl_1")
        XCTAssertEqual(g, u)
        r = StubURLProtocol.recorded[1]
        XCTAssertEqual(r.method, "GET"); XCTAssertEqual(r.path, "/v1/devices/me/unlock-requests/unl_1")
    }

    func testDisableProtectionRequestOmitsGroups() async throws {
        StubURLProtocol.handler = { [unlockJSON] _ in (201, [:], Data(unlockJSON.utf8)) }
        _ = try await client().createUnlockRequest(CreateUnlockRequest(kind: .disableProtection, reason: "need off"))
        let b = try XCTUnwrap(StubURLProtocol.recorded[0].json())
        XCTAssertEqual(b["kind"] as? String, "disableProtection")
        XCTAssertNil(b["groupIds"]); XCTAssertNil(b["minutes"])
    }

    func testUnpair() async throws {
        StubURLProtocol.handler = { _ in (204, [:], Data()) }
        try await client().unpair()
        XCTAssertEqual(StubURLProtocol.recorded[0].method, "DELETE")
        XCTAssertEqual(StubURLProtocol.recorded[0].path, "/v1/devices/me")
    }

    // MARK: errors

    func assertError(status: Int, headers: [String: String] = [:], body: String = "", _ check: (APIError) -> Void,
                     file: StaticString = #filePath, line: UInt = #line) async {
        StubURLProtocol.handler = { _ in (status, headers, Data(body.utf8)) }
        do { try await client().unpair(); XCTFail("expected error", file: file, line: line) }
        catch let e as APIError { check(e) }
        catch { XCTFail("wrong error \(error)", file: file, line: line) }
    }

    func testErrorMapping() async {
        await assertError(status: 401, body: #"{"error":{"code":"unauthorized","message":"x"}}"#) {
            if case .unauthorized = $0 {} else { XCTFail() }; XCTAssertFalse($0.isRetryable) }
        await assertError(status: 404) { if case .notFound = $0 {} else { XCTFail() } }
        await assertError(status: 422, body: #"{"error":{"code":"validation_failed","message":"minutes too big"}}"#) {
            if case .validation(let m) = $0 { XCTAssertEqual(m, "minutes too big") } else { XCTFail() }
            XCTAssertFalse($0.isRetryable) }
        await assertError(status: 429, headers: ["Retry-After": "30"]) {
            if case .rateLimited(let r) = $0 { XCTAssertEqual(r, 30) } else { XCTFail() }; XCTAssertTrue($0.isRetryable) }
        await assertError(status: 429) { if case .rateLimited(let r) = $0 { XCTAssertNil(r) } else { XCTFail() } }
        await assertError(status: 500, body: #"{"error":{"code":"internal","message":"boom"}}"#) {
            if case .server(let s, let c, let m) = $0 { XCTAssertEqual(s, 500); XCTAssertEqual(c, "internal"); XCTAssertEqual(m, "boom") } else { XCTFail() }
            XCTAssertTrue($0.isRetryable) }
        await assertError(status: 409, body: "not json") {
            if case .server(let s, let c, _) = $0 { XCTAssertEqual(s, 409); XCTAssertNil(c) } else { XCTFail() }
            XCTAssertFalse($0.isRetryable) }
    }

    func testTransportAndDecodingErrors() async {
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { try await client().unpair(); XCTFail() }
        catch let e as APIError { if case .transport = e {} else { XCTFail() }; XCTAssertTrue(e.isRetryable) }
        catch { XCTFail() }

        StubURLProtocol.handler = { _ in (200, [:], Data("{}".utf8)) }
        do { _ = try await client().fetchPolicy(ifNoneMatch: nil); XCTFail() }
        catch let e as APIError { if case .decoding = e {} else { XCTFail() }; XCTAssertFalse(e.isRetryable) }
        catch { XCTFail() }
    }

    func testMissingTokenIsUnauthorizedWithoutNetwork() async {
        StubURLProtocol.handler = { _ in (204, [:], Data()) }
        do { try await client(token: nil).unpair(); XCTFail() }
        catch let e as APIError { if case .unauthorized = e {} else { XCTFail() } }
        catch { XCTFail() }
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }
}

final class APIErrorDescriptionTests: XCTestCase {
    func testReadableDescriptions() {
        XCTAssertEqual(APIError.unauthorized.localizedDescription, "The server refused the request (401).")
        XCTAssertEqual(APIError.server(status: 503, code: nil, message: "down").localizedDescription, "Server error 503: down")
        XCTAssertEqual(APIError.validation("Bad code").localizedDescription, "Bad code")
    }
}
