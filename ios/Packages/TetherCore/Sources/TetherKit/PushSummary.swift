#if os(iOS) && canImport(ManagedSettings)
import Foundation
import TetherCore

/// Builds the rewritten notification body for a policy push by diffing blocked groups
/// before/after (`Reconciler.snapshot()` vs `Reconciler.reconcile()`).
public enum PushSummary {
    public static func make(before: ReconcileResult, after: ReconcileResult, now: Date = Date()) -> String? {
        let names = groupNames()
        let wasBlocked = Set(before.blockedGroupIds)
        let isBlocked = Set(after.blockedGroupIds)
        let newlyBlocked = isBlocked.subtracting(wasBlocked).sorted()
        let newlyUnblocked = wasBlocked.subtracting(isBlocked).sorted()
        var parts: [String] = []

        if !newlyBlocked.isEmpty {
            let list = join(newlyBlocked.map { names[$0] ?? "A group" })
            let verb = newlyBlocked.count == 1 ? "is" : "are"
            var text = "\(list) \(verb) now blocked"
            let untils = newlyBlocked.compactMap { after.states[$0]?.until }
            if let u = untils.min() { text += " until " + timeText(u, now: now, tz: after.timeZone) }
            parts.append(text)
        }
        if !newlyUnblocked.isEmpty {
            let list = join(newlyUnblocked.map { names[$0] ?? "A group" })
            var text = "\(list) unblocked"
            // `until` of an unblocked group = when it is blocked again.
            let untils = newlyUnblocked.compactMap { after.states[$0]?.until }
            if let u = untils.min(), u > now {
                let minutes = max(1, Int((u.timeIntervalSince(now) / 60).rounded()))
                text += " for " + ShieldCopy.minutesLabel(minutes)
            }
            parts.append(text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    private static func groupNames() -> [GroupID: String] {
        guard let s = try? StateStore(directory: AppGroup.containerURL).load() else { return [:] }
        return Dictionary(s.engineInput.allGroups.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    private static func join(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    private static func timeText(_ date: Date, now: Date, tz: TimeZone) -> String {
        ShieldCopy.Formatter.standard(timeZone: tz).time(date)
    }
}
#endif
