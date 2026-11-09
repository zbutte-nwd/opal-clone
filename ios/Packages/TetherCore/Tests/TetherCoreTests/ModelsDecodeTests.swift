import XCTest
@testable import TetherCore

final class ModelsDecodeTests: XCTestCase {
    static let contracts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("contracts")

    func testDecodeExampleBundleRoundTrip() throws {
        let data = try Data(contentsOf: Self.contracts.appendingPathComponent("fixtures/policy-bundle.example.json"))
        let bundle = try TetherJSON.makeDecoder().decode(PolicyBundle.self, from: data)
        XCTAssertEqual(bundle.version, 42)
        XCTAssertEqual(bundle.groups.count, 3)
        XCTAssertTrue(bundle.rules.contains { if case .usageLimit(30, _) = $0.trigger { return true } else { return false } })
        let re = try TetherJSON.makeDecoder().decode(PolicyBundle.self, from: TetherJSON.makeEncoder().encode(bundle))
        XCTAssertEqual(re, bundle)
    }
}

final class GuardedModelsTests: XCTestCase {
    private func bundleJSON(strictness: String, groupExtra: String = "") -> Data {
        Data("""
        {"version":1,"generatedAt":"2026-11-09T00:00:00Z","timeZone":null,
         "groups":[{"id":"grp_a","name":"A","webDomains":[]\(groupExtra)}],
         "rules":[{"id":"rule_a","name":"A","groupIds":["grp_a"],"enabled":true,"action":"block",
                   "trigger":{"type":"manual","active":true},"strictness":"\(strictness)"}],
         "overrides":[],"settings":{"protectionLock":"partnerPIN","allowLocalRules":true,"denyAppRemoval":true}}
        """.utf8)
    }

    func testUnknownStrictnessDecodesAsFlexible() throws {
        let b = try TetherJSON.makeDecoder().decode(PolicyBundle.self, from: bundleJSON(strictness: "ultra"))
        XCTAssertEqual(b.rules.first?.strictness, .flexible)
        XCTAssertEqual(b.groups.count, 1, "the whole bundle still decodes")
    }

    func testGuardedRoundTrips() throws {
        let b = try TetherJSON.makeDecoder().decode(PolicyBundle.self, from: bundleJSON(strictness: "guarded"))
        XCTAssertEqual(b.rules.first?.strictness, .guarded)
        let re = try TetherJSON.makeDecoder().decode(PolicyBundle.self, from: TetherJSON.makeEncoder().encode(b))
        XCTAssertEqual(re, b)
        XCTAssertTrue(Strictness.guarded.isLocking && Strictness.strict.isLocking && !Strictness.flexible.isLocking)
    }

    func testCopiedFromOptional() throws {
        let none = try TetherJSON.makeDecoder().decode(PolicyBundle.self, from: bundleJSON(strictness: "flexible"))
        XCTAssertNil(none.groups.first?.copiedFrom)
        let some = try TetherJSON.makeDecoder().decode(PolicyBundle.self,
                                                       from: bundleJSON(strictness: "flexible", groupExtra: #","copiedFrom":"lgrp_abc""#))
        XCTAssertEqual(some.groups.first?.copiedFrom, "lgrp_abc")
        let enc = String(decoding: try TetherJSON.makeEncoder().encode(some), as: UTF8.self)
        XCTAssertTrue(enc.contains(#""copiedFrom":"lgrp_abc""#))
    }
}

final class IsRuleActiveTests: XCTestCase {
    // 2026-11-09 is a Monday.
    func testIsRuleActiveScheduleWindow() {
        let r = T.rule("rule_w", groups: ["grp_social"], windows: [Window(days: T.weekdays, start: "09:00", end: "17:00")])
        let input = T.input(rules: [r])
        XCTAssertTrue(PolicyEngine.isRuleActive(r, input, at: T.d("2026-11-09T18:00:00Z"), timeZone: T.la))   // 10:00 PST
        XCTAssertFalse(PolicyEngine.isRuleActive(r, input, at: T.d("2026-11-10T02:00:00Z"), timeZone: T.la))  // 18:00 PST
    }

    func testIsRuleActiveOvernightWindow() {
        let r = T.rule("rule_n", groups: ["grp_social"], windows: [Window(days: [1], start: "22:00", end: "02:00")])
        let input = T.input(rules: [r])
        XCTAssertTrue(PolicyEngine.isRuleActive(r, input, at: T.d("2026-11-10T09:00:00Z"), timeZone: T.la))   // Tue 01:00 PST
        XCTAssertFalse(PolicyEngine.isRuleActive(r, input, at: T.d("2026-11-10T11:00:00Z"), timeZone: T.la))  // Tue 03:00 PST
    }

    func testIsRuleActiveDisabledRule() {
        let r = T.rule("rule_d", groups: ["grp_social"], windows: [Window(days: [1, 2, 3, 4, 5, 6, 7], start: "00:00", end: "24:00")], enabled: false)
        XCTAssertFalse(PolicyEngine.isRuleActive(r, T.input(rules: [r]), at: T.d("2026-11-09T18:00:00Z"), timeZone: T.la))
    }

    func testIsRuleActiveManualMode() {
        let r = Rule(id: "rule_m", name: "M", groupIds: ["grp_social"], trigger: .manual(active: true), source: .server)
        XCTAssertTrue(PolicyEngine.isRuleActive(r, T.input(rules: [r]), at: T.d("2026-11-09T18:00:00Z"), timeZone: T.la))
    }

    func testLocalRuleInactiveWhenLocalRulesDisallowed() {
        var r = T.rule("lrule_x", groups: ["grp_social"], windows: [Window(days: [1, 2, 3, 4, 5, 6, 7], start: "00:00", end: "24:00")])
        r.source = .local
        XCTAssertTrue(PolicyEngine.isRuleActive(r, T.input(localRules: [r]), at: T.d("2026-11-09T18:00:00Z"), timeZone: T.la))
        XCTAssertFalse(PolicyEngine.isRuleActive(r, T.input(allowLocal: false, localRules: [r]), at: T.d("2026-11-09T18:00:00Z"), timeZone: T.la))
    }
}
