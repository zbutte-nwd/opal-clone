#if os(iOS) && canImport(ManagedSettings)
import Foundation
import FamilyControls
import TetherCore

extension FamilyActivitySelection {
    /// True when the selection holds no app, category or web-domain token.
    public var hasTokens: Bool {
        !(applicationTokens.isEmpty && categoryTokens.isEmpty && webDomainTokens.isEmpty)
    }
}

/// `[GroupID: FamilyActivitySelection]` persisted as `selections.json` in the App Group.
/// Server groups can never carry app identities (PLATFORM_CONSTRAINTS §2); the user maps
/// each group to a local selection with `FamilyActivityPicker`, stored here.
public final class SelectionStore: @unchecked Sendable {
    public static let fileName = "selections.json"
    public static let shared = SelectionStore()

    private let url: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        self.url = (directory ?? AppGroup.containerURL).appendingPathComponent(Self.fileName)
    }

    // MARK: Read

    public func all() -> [GroupID: FamilyActivitySelection] {
        lock.lock(); defer { lock.unlock() }
        return readLocked()
    }

    public func selection(for groupId: GroupID) -> FamilyActivitySelection? {
        all()[groupId]
    }

    // MARK: Write

    public func set(_ selection: FamilyActivitySelection, for groupId: GroupID) {
        lock.lock(); defer { lock.unlock() }
        var map = readLocked()
        map[groupId] = selection
        writeLocked(map)
    }

    public func remove(_ groupId: GroupID) {
        lock.lock(); defer { lock.unlock() }
        var map = readLocked()
        guard map.removeValue(forKey: groupId) != nil else { return }
        writeLocked(map)
    }

    /// Drops selections of groups that no longer exist.
    public func prune(keeping groupIds: Set<GroupID>) {
        lock.lock(); defer { lock.unlock() }
        var map = readLocked()
        let before = map.count
        map = map.filter { groupIds.contains($0.key) }
        if map.count != before { writeLocked(map) }
    }

    // MARK: Copies (BlockGroup.copiedFrom)

    private var appliedURL: URL { url.deletingLastPathComponent().appendingPathComponent("appliedCopies.json") }

    /// Server group ids whose one-time selection copy already happened.
    public func appliedCopies() -> Set<GroupID> {
        lock.lock(); defer { lock.unlock() }
        return readApplied()
    }

    /// Copies each plan's source selection to its server group (never overwriting a selection the user
    /// already picked there) and records it, so it happens at most once per copy.
    public func applyCopies(_ plans: [CopyPlan]) {
        lock.lock(); defer { lock.unlock() }
        var map = readLocked(), applied = readApplied()
        var changed = false
        for p in plans where !applied.contains(p.to) {
            if let sel = map[p.from], sel.hasTokens, !(map[p.to]?.hasTokens ?? false) { map[p.to] = sel; changed = true }
            applied.insert(p.to)
        }
        if changed { writeLocked(map) }
        do { try JSONEncoder().encode(applied.sorted()).write(to: appliedURL, options: [.atomic]) }
        catch { TLog.shield.error("appliedCopies.json write failed: \(String(describing: error))") }
    }

    private func readApplied() -> Set<GroupID> {
        guard let d = try? Data(contentsOf: appliedURL), let ids = try? JSONDecoder().decode([GroupID].self, from: d) else { return [] }
        return Set(ids)
    }

    // MARK: Queries

    /// Server-defined groups that still need the user to pick apps for them: no tokens
    /// stored and no server-provided web domains either.
    public func unmappedServerGroups(in input: EngineInput) -> [BlockGroup] {
        let map = all()
        return input.allGroups.filter { g in
            g.source == .server
                && !(map[g.id]?.hasTokens ?? false)
                && g.webDomains.isEmpty
        }
    }

    // MARK: Private

    private func readLocked() -> [GroupID: FamilyActivitySelection] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        do {
            return try JSONDecoder().decode([GroupID: FamilyActivitySelection].self, from: data)
        } catch {
            TLog.shield.error("selections.json decode failed: \(String(describing: error))")
            return [:]
        }
    }

    private func writeLocked(_ map: [GroupID: FamilyActivitySelection]) {
        do {
            let data = try JSONEncoder().encode(map)
            try data.write(to: url, options: [.atomic])
        } catch {
            TLog.shield.error("selections.json write failed: \(String(describing: error))")
        }
    }
}
#endif
