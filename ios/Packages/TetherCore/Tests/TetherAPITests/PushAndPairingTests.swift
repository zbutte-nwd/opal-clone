import XCTest
import TetherCore
@testable import TetherAPI

final class PushAndPairingTests: XCTestCase {
    func testParsePolicyUpdatedFixture() throws {
        let p = try XCTUnwrap(PushPayload.parse(Fixtures.object("push-policy-updated.json")))
        XCTAssertEqual(p.type, .policyUpdated); XCTAssertEqual(p.version, 42)
        XCTAssertNil(p.bundle); XCTAssertNil(p.requestId)
    }

    func testParseInlineBundleFixture() throws {
        let p = try XCTUnwrap(PushPayload.parse(Fixtures.object("push-silent-inline-bundle.json")))
        XCTAssertEqual(p.type, .policyUpdated)
        XCTAssertEqual(p.bundle?.version, 42)
        XCTAssertEqual(p.bundle?.groups.count, 3)
        XCTAssertEqual(p.bundle?.overrides.first?.id, "ovr_1")
    }

    func testParseUnlockDecidedAndUnknown() {
        let u = PushPayload.parse(["tether": ["type": "unlockDecided", "requestId": "unl_9"]])
        XCTAssertEqual(u?.type, .unlockDecided); XCTAssertEqual(u?.requestId, "unl_9")
        XCTAssertEqual(PushPayload.parse(["tether": ["type": "somethingNew"]])?.type, .unknown("somethingNew"))
        XCTAssertNil(PushPayload.parse(["aps": ["alert": "x"]]))
        XCTAssertNil(PushPayload.parse(["tether": "nope"]))
    }

    func testPairingLink() {
        let l = PairingLink.parse("tether://pair?code=K7Q2-M9XD&server=https%3A%2F%2Ftether.example.com")
        XCTAssertEqual(l?.code, "K7Q2-M9XD")
        XCTAssertEqual(l?.serverURL.absoluteString, "https://tether.example.com")
        XCTAssertEqual(PairingLink.parse("tether://pair?code=k7q2m9xd&server=http://localhost:8080")?.code, "K7Q2-M9XD")
        XCTAssertEqual(PairingLink.parse("tether://pair?code=k7q2%20m9xd&server=http://localhost:8080")?.code, "K7Q2-M9XD")
        XCTAssertNil(PairingLink.parse("https://pair?code=K7Q2-M9XD&server=https://x.com"))
        XCTAssertNil(PairingLink.parse("tether://pair?code=K7Q2&server=https://x.com"))
        XCTAssertNil(PairingLink.parse("tether://pair?code=K7Q2-M9XD"))
        XCTAssertNil(PairingLink.parse("tether://pair?code=K7Q2-M9XD&server=ftp://x.com"))
        XCTAssertNil(PairingLink.parse("tether://other?code=K7Q2-M9XD&server=https://x.com"))
    }

    func testNormalizeCode() {
        XCTAssertEqual(PairingLink.normalizeCode(" k7q2 - m9xd "), "K7Q2-M9XD")
        XCTAssertEqual(PairingLink.normalizeCode("K7Q2M9XD"), "K7Q2-M9XD")
        XCTAssertNil(PairingLink.normalizeCode("K7Q2"))
    }
}
