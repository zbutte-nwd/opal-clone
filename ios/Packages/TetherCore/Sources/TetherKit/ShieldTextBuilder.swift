#if os(iOS) && canImport(ManagedSettings)
import Foundation
import TetherCore

/// Thin adapter over `TetherCore.ShieldCopy` (pure text) used when writing `shieldContext.json`.
enum ShieldTextBuilder {
    static func texts(group: BlockGroup, state: GroupState, input: EngineInput?,
                      timeZone: TimeZone, now: Date) -> (title: String, subtitle: String) {
        let copy = ShieldCopy.make(groupName: group.name, state: state, input: input ?? EngineInput(),
                                   now: now, timeZone: timeZone, formatter: .standard(timeZone: timeZone))
        return (copy.title, copy.subtitle)
    }
}
#endif
