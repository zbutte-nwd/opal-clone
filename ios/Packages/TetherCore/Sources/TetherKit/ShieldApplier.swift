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
    /// Per-store cap on `shield.applications` / `shield.webDomains` tokens. VERIFY: spike S5 —
    /// believed to be 50 per ManagedSettingsStore (more = the store's app shield is ignored), so
    /// tokens are sharded over `tether.block`, `tether.block.1`, … (stores combine: the union
    /// of all stores' shields applies). Harmless if the real limit is higher.
    public static let maxTokensPerStore = 50
    public static let shardCount = 4

    /// `stores[0]` is `tether.block` (also holds categories + web filter); the rest only hold
    /// overflow app / web-domain tokens.
    private let stores: [ManagedSettingsStore]
    private var store: ManagedSettingsStore { stores[0] }

    public static func shardName(_ index: Int) -> String { index == 0 ? storeName : "\(storeName).\(index)" }

    public init() {
        // `ManagedSettingsStore.Name` is RawRepresentable with `init(_ rawValue:)` (Apple's docs
        // use `extension ManagedSettingsStore.Name { static let x = Self("x") }`).
        self.stores = (0..<Self.shardCount).map {
            ManagedSettingsStore(named: ManagedSettingsStore.Name(Self.shardName($0)))
        }
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
        let appShards = Self.shards(apps)
        for (i, s) in stores.enumerated() {
            let newApps: Set<ApplicationToken>? = i < appShards.count ? appShards[i] : nil
            if s.shield.applications != newApps { s.shield.applications = newApps }
        }

        // W8-audited: `.specific(_ categories: Set<ActivityCategoryToken>, except: Set<…Token> = [])`.
        if cats.isEmpty {
            store.shield.applicationCategories = nil
            store.shield.webDomainCategories = nil
        } else {
            store.shield.applicationCategories = .specific(cats)
            store.shield.webDomainCategories = .specific(cats)
        }

        let webShards = Self.shards(webTokens)
        for (i, s) in stores.enumerated() {
            let newWeb: Set<WebDomainToken>? = i < webShards.count ? webShards[i] : nil
            if s.shield.webDomains != newWeb { s.shield.webDomains = newWeb }
        }

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
        for s in stores { s.clearAllSettings() }
        ShieldContextStore.write(ShieldContextFile(generatedAt: Date()))
    }

    // MARK: Helpers

    /// Splits `tokens` into deterministic chunks of `maxTokensPerStore` (ordered by token key so
    /// a token stays in the same store across reconciles). Tokens beyond all shards are dropped.
    static func shards<T: Encodable & Hashable>(_ tokens: Set<T>) -> [Set<T>] {
        guard !tokens.isEmpty else { return [] }
        let encoder = JSONEncoder()
        let ordered = tokens
            .map { (key: (try? encoder.encode($0).base64EncodedString()) ?? "", token: $0) }
            .sorted { $0.key < $1.key }
            .map(\.token)
        let capacity = maxTokensPerStore * shardCount
        if ordered.count > capacity {
            TLog.shield.error("\(ordered.count) tokens exceed shard capacity \(capacity); extra tokens are not shielded")
        }
        return stride(from: 0, to: min(ordered.count, capacity), by: maxTokensPerStore).map {
            Set(ordered[$0..<min($0 + maxTokensPerStore, ordered.count, capacity)])
        }
    }

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
