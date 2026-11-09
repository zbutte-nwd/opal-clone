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
