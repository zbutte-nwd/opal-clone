import Foundation
@testable import TetherCore

enum T {
    static let la = TimeZone(identifier: "America/Los_Angeles")!
    static let utc = TimeZone(identifier: "UTC")!

    static func d(_ s: String) -> Date { TetherJSON.parseDate(s)! }

    static func group(_ id: String, _ name: String = "") -> BlockGroup {
        BlockGroup(id: id, name: name.isEmpty ? id : name, source: .server)
    }

    static func rule(_ id: String, groups: [String], windows: [Window], name: String? = nil,
                     strict: Bool = false, priority: Int = 0, action: RuleAction = .block,
                     maxPauses: Int? = nil, enabled: Bool = true) -> Rule {
        Rule(id: id, name: name ?? id, groupIds: groups, enabled: enabled, action: action,
             trigger: .schedule(windows: windows), strictness: strict ? .strict : .flexible,
             priority: priority, maxPausesPerDay: maxPauses, source: .server)
    }

    static let weekdays = [1, 2, 3, 4, 5]

    static func input(groups: [BlockGroup] = [group("grp_social", "Social")], rules: [Rule] = [],
                      overrides: [Override] = [], sessions: [FocusSession] = [], pauses: [Pause] = [],
                      hits: [UsageLimitHit] = [], tz: String? = nil, allowLocal: Bool = true,
                      localRules: [Rule] = []) -> EngineInput {
        var settings = PolicySettings(); settings.allowLocalRules = allowLocal
        let b = PolicyBundle(version: 1, generatedAt: d("2026-11-01T00:00:00Z"), timeZone: tz,
                             groups: groups, rules: rules, overrides: overrides, settings: settings)
        return EngineInput(bundle: b, localRules: localRules, sessions: sessions, pauses: pauses, usageLimitHits: hits)
    }

    static func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("tether-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined() }
}
