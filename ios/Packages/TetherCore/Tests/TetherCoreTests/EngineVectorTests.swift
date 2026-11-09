import XCTest
@testable import TetherCore

/// Runs every golden vector in contracts/engine-vectors.json through PolicyEngine.evaluate.
final class EngineVectorTests: XCTestCase {
    struct Vector: Decodable {
        struct Expect: Decodable {
            struct R: Decodable { var kind: String; var id: String? }
            var blocked: Bool; var strict: Bool; var reason: R
        }
        var name: String
        var now: Date
        var deviceTimeZone: String
        var input: EngineInput
        var expect: [String: Expect]
    }
    struct File: Decodable { var vectors: [Vector] }

    func testAllGoldenVectors() throws {
        let url = ModelsDecodeTests.contracts.appendingPathComponent("engine-vectors.json")
        let file = try TetherJSON.makeDecoder().decode(File.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(file.vectors.count, 61)
        var failures = 0
        for v in file.vectors {
            let device = try XCTUnwrap(TimeZone(identifier: v.deviceTimeZone), v.name)
            let tz = PolicyEngine.effectiveTimeZone(v.input, deviceTimeZone: device)
            let got = PolicyEngine.evaluate(v.input, at: v.now, timeZone: tz)
            if Set(got.keys) != Set(v.expect.keys) {
                failures += 1
                XCTFail("[\(v.name)] group ids differ: got \(got.keys.sorted()) want \(v.expect.keys.sorted())")
                continue
            }
            for (gid, e) in v.expect {
                let g = got[gid]!
                if g.blocked != e.blocked || g.strict != e.strict || g.reason.kind.rawValue != e.reason.kind || g.reason.id != e.reason.id {
                    failures += 1
                    XCTFail("[\(v.name)] \(gid): got blocked=\(g.blocked) strict=\(g.strict) reason=\(g.reason.kind.rawValue)/\(g.reason.id ?? "nil"); want blocked=\(e.blocked) strict=\(e.strict) reason=\(e.reason.kind)/\(e.reason.id ?? "nil")")
                }
            }
        }
        XCTAssertEqual(failures, 0)
    }
}
