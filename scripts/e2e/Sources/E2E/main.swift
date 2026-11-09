import Foundation
import TetherCore
let path = CommandLine.arguments[1]
let bundle = try TetherJSON.makeDecoder().decode(PolicyBundle.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
let input = EngineInput(bundle: bundle)
let tz = TimeZone(identifier: "America/Los_Angeles")!
let now = bundle.overrides.first.map { $0.startsAt.addingTimeInterval(60) } ?? Date()
let states = TransitionPlanner.annotateUntil(PolicyEngine.evaluate(input, at: now, timeZone: tz), input: input, now: now, timeZone: tz)
for g in input.allGroups { let s = states[g.id]!; print(g.name, s.blocked ? "BLOCKED" : "open", s.reason.kind, s.strict ? "strict" : "", s.until.map { TetherJSON.formatDate($0) } ?? "") }
print("next transitions:", TransitionPlanner.nextTransitions(input, after: now, timeZone: tz, limit: 4).map(TetherJSON.formatDate))
