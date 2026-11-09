#if os(iOS) && canImport(ManagedSettings)
import Foundation
import FamilyControls
import TetherCore
import TetherAPI

/// Builds the read-only phone-made snapshot (TetherAPI.LocalSnapshot). Only token COUNTS leave a
/// selection; the tokens themselves never do.
public enum SnapshotBuilder {
    public static func build(state: PersistedState, selections: [GroupID: FamilyActivitySelection],
                             protectionLock: ProtectionLock, now: Date = Date()) -> LocalSnapshot {
        let counts = selections.mapValues {
            LocalSnapshot.Counts(apps: $0.applicationTokens.count, categories: $0.categoryTokens.count,
                                 webTokens: $0.webDomainTokens.count)
        }
        return LocalSnapshot.make(state: state, counts: counts, protectionLock: protectionLock, now: now)
    }

    /// The current snapshot from the App Group; nil in extensions (only the app uploads it).
    public static func current(now: Date = Date()) -> LocalSnapshot? {
        guard Bundle.main.bundleURL.pathExtension != "appex",
              let s = try? StateStore(directory: AppGroup.containerURL).load() else { return nil }
        return build(state: s, selections: SelectionStore.shared.all(), protectionLock: ProtectionController.effectiveLock(s), now: now)
    }
}
#endif
