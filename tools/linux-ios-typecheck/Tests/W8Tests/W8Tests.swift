import XCTest
import Foundation
import TetherCore
@testable import TetherKitCheck
@testable import AppCore

final class W8Tests: XCTestCase {
    func testOneShotNameRoundTrip() {
        let d = Date(timeIntervalSince1970: 1_800_000_123)
        let n = ActivityScheduler.oneShotActivityName(for: d)
        XCTAssertEqual(n, "tether.t.1800000123")
        XCTAssertEqual(ActivityScheduler.transitionDate(fromActivity: n), d)
        XCTAssertNil(ActivityScheduler.transitionDate(fromActivity: "tether.daily"))
        XCTAssertNil(ActivityScheduler.transitionDate(fromActivity: "tether.usage.r1"))
        XCTAssertEqual(ActivityScheduler.ruleId(fromActivity: "tether.usage.lrule_x"), "lrule_x")
    }
    func testPauseURLParses() async { await MainActor.run {
        for g in ["lgrp_social", ""] {
            let url = NotificationRouter.pauseURL(groupId: g)
            let link = DeepLinkRouter.parse(URL(string: url.absoluteString)!)
            XCTAssertEqual(link, .pause(groupId: g), url.absoluteString)
        }
        XCTAssertEqual(DeepLinkRouter.parse(URL(string: "tether://session/new")!), .newSession)
    } }
    func testShards() {
        XCTAssertEqual(ShieldApplier.shards(Set<Int>()).count, 0)
        let s = ShieldApplier.shards(Set(0..<120))
        XCTAssertEqual(s.map(\.count), [50, 50, 20])
        XCTAssertEqual(s.reduce(Set<Int>()) { $0.union($1) }, Set(0..<120))
        XCTAssertEqual(ShieldApplier.shards(Set(0..<500)).map(\.count), [50, 50, 50, 50])
        XCTAssertEqual(ShieldApplier.shards(Set(0..<120)), s)   // deterministic
    }
    func testNormalizeDomain() {
        XCTAssertEqual(ShieldApplier.normalizeDomain(" https://WWW.Example.com/path "), "example.com")
    }
    func testCategoryFallback() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func e(_ g: String, strict: Bool) -> ShieldContextEntry {
            ShieldContextEntry(groupId: g, groupName: g, title: "t", subtitle: "s", strict: strict, until: nil)
        }
        // read() uses AppGroup.containerURL (fallback dir on Linux); write there.
        ShieldContextStore.write(ShieldContextFile(generatedAt: Date(), categories: ["a": e("g1", strict: false), "b": e("g1", strict: false)]))
        XCTAssertEqual(ShieldContextStore.categoryFallbackEntry()?.groupId, "g1")
        ShieldContextStore.write(ShieldContextFile(generatedAt: Date(), categories: ["a": e("g1", strict: false), "b": e("g2", strict: false)]))
        XCTAssertEqual(ShieldContextStore.categoryFallbackEntry()?.groupId, "")
        ShieldContextStore.write(ShieldContextFile(generatedAt: Date(), categories: ["a": e("g1", strict: true)]))
        XCTAssertEqual(ShieldContextStore.categoryFallbackEntry()?.strict, true)
        ShieldContextStore.write(ShieldContextFile(generatedAt: Date()))
        XCTAssertNil(ShieldContextStore.categoryFallbackEntry())
    }
}
