import Foundation

/// A server group that is a copy of a phone-made group (`BlockGroup.copiedFrom`) gets that group's app
/// selection once. `applied` remembers done copies so a user who later clears the copy's apps doesn't get
/// them back on the next bundle; a missing source is ignored (the group asks "Choose apps for …").
public struct CopyPlan: Equatable, Sendable {
    public let from: GroupID
    public let to: GroupID
    public init(from: GroupID, to: GroupID) { self.from = from; self.to = to }
}

public enum CopyPlanner {
    public static func copies(bundleGroups: [BlockGroup], localGroupIds: Set<GroupID>, applied: Set<GroupID>) -> [CopyPlan] {
        bundleGroups.compactMap { g in
            guard let src = g.copiedFrom, !applied.contains(g.id), localGroupIds.contains(src) else { return nil }
            return CopyPlan(from: src, to: g.id)
        }
    }
}
