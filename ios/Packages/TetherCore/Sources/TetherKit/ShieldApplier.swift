#if os(iOS) && canImport(ManagedSettings)
import Foundation
import FamilyControls
import ManagedSettings
import TetherCore

/// Writes the `tether.block` ManagedSettings store: the union of the tokens of every
/// blocked group (ARCHITECTURE §6), and `shieldContext.json` for the shield extensions.
/// Idempotent: calling it twice with the same inputs leaves the store unchanged.
public final class ShieldApplier: @unchecked Sendable {
    public static let storeName = "tether.block"
    /// `webContent.blockedByFilter = .specific` limit. VERIFY: spike S5 (50 domains).
    public static let maxFilterDomains = 50

    private let store: ManagedSettingsStore

    public init() {
        // VERIFY: `ManagedSettingsStore.Name` is constructible as `Name("…")` (it is
        // RawRepresentable & ExpressibleByStringLiteral in the iOS 16+ SDK).
        self.store = ManagedSettingsStore(named: ManagedSettingsStore.Name(Self.storeName))
    }

    /// Applies the shields for `states` (only `blocked == true` groups contribute).
    /// - Parameters:
    ///   - groups: all known groups (for names and server web domains).
    ///   - selections: group -> picker selection (tokens).
    ///   - input/timeZone/now: used only to produce the shield copy for `shieldContext.json`.
    public func apply(_ states: [GroupID: GroupState],
                      groups: [BlockGroup],
                      selections: [GroupID: FamilyActivitySelection],
                      input: EngineInput? = nil,
                      timeZone: TimeZone = .current,
                      now: Date = Date()) {
        let groupsById = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let blocked = states.values.filter { $0.blocked }.sorted { $0.groupId < $1.groupId }

        var apps = Set<ApplicationToken>()
        var cats = Set<ActivityCategoryToken>()
        var webTokens = Set<WebDomainToken>()
        var domains = Set<String>()
        var ctx = ShieldContextFile(generatedAt: now)

        for state in blocked {
            guard let group = groupsById[state.groupId] else { continue }
            let sel = selections[state.groupId]
            apps.formUnion(sel?.applicationTokens ?? [])
            cats.formUnion(sel?.categoryTokens ?? [])
            webTokens.formUnion(sel?.webDomainTokens ?? [])
            for d in group.webDomains {
                let n = Self.normalizeDomain(d)
                if !n.isEmpty { domains.insert(n) }
            }

            let (title, subtitle) = ShieldTextBuilder.texts(group: group, state: state, input: input,
                                                            timeZone: timeZone, now: now)
            let entry = ShieldContextEntry(groupId: group.id, groupName: group.name, title: title,
                                           subtitle: subtitle, strict: state.strict, until: state.until)
            for t in sel?.applicationTokens ?? [] {
                if let k = TokenKey.key(t) { Self.merge(&ctx.applications, k, entry) }
            }
            for t in sel?.categoryTokens ?? [] {
                if let k = TokenKey.key(t) { Self.merge(&ctx.categories, k, entry) }
            }
            for t in sel?.webDomainTokens ?? [] {
                if let k = TokenKey.key(t) { Self.merge(&ctx.webDomains, k, entry) }
            }
        }

        // Only assign when different (avoids needless store churn / notifications).
        let newApps: Set<ApplicationToken>? = apps.isEmpty ? nil : apps
        if store.shield.applications != newApps { store.shield.applications = newApps }

        // VERIFY: `ShieldSettings.ActivityCategoryPolicy.specific(_:except:)` — `except` defaults to [].
        if cats.isEmpty {
            store.shield.applicationCategories = nil
            store.shield.webDomainCategories = nil
        } else {
            store.shield.applicationCategories = .specific(cats)
            store.shield.webDomainCategories = .specific(cats)
        }

        let newWeb: Set<WebDomainToken>? = webTokens.isEmpty ? nil : webTokens
        if store.shield.webDomains != newWeb { store.shield.webDomains = newWeb }

        // Server/local plain domains. Cap at 50, deterministic order.
        // VERIFY: spike S5 — limit and coexistence with `shield.webDomains`.
        let capped = Array(domains.sorted().prefix(Self.maxFilterDomains))
        if capped.count < domains.count {
            TLog.shield.notice("web domain filter capped to \(Self.maxFilterDomains) of \(domains.count)")
        }
        if capped.isEmpty {
            store.webContent.blockedByFilter = nil
        } else {
            store.webContent.blockedByFilter = .specific(Set(capped.map { WebDomain(domain: $0) }))
        }

        ShieldContextStore.write(ctx)
    }

    /// Removes every setting this store holds, and empties the shield context.
    public func clearAll() {
        store.clearAllSettings()
        ShieldContextStore.write(ShieldContextFile(generatedAt: Date()))
    }

    // MARK: Helpers

    static func normalizeDomain(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        return s
    }

    /// Strict entries win; otherwise the one that ends sooner is shown.
    private static func merge(_ map: inout [String: ShieldContextEntry], _ key: String, _ entry: ShieldContextEntry) {
        guard let existing = map[key] else { map[key] = entry; return }
        if existing.strict != entry.strict { if entry.strict { map[key] = entry }; return }
        switch (existing.until, entry.until) {
        case (nil, .some): map[key] = entry
        case let (a?, b?) where b < a: map[key] = entry
        default: break
        }
    }
}

/// `ManagedSettingsStore` "tether.tamper": denies app removal while protection is on.
public final class TamperLock: @unchecked Sendable {
    public static let storeName = "tether.tamper"
    private let store: ManagedSettingsStore

    public init() {
        self.store = ManagedSettingsStore(named: ManagedSettingsStore.Name(Self.storeName))
    }

    /// `application.denyAppRemoval` — VERIFY: spike S1 (blocks deletion of ALL apps, incl. Tether).
    public func setDenyAppRemoval(_ on: Bool) {
        let target: Bool? = on ? true : nil
        if store.application.denyAppRemoval != target { store.application.denyAppRemoval = target }
    }

    public var isDenyingAppRemoval: Bool { store.application.denyAppRemoval ?? false }

    public func clearAll() { store.clearAllSettings() }
}
#endif
