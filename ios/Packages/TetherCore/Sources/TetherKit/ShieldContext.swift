#if os(iOS) && canImport(ManagedSettings)
import Foundation
import FamilyControls
import ManagedSettings
import TetherCore

/// What the shield extensions need to render a blocked token. Written by
/// `ShieldApplier.apply` (`shieldContext.json`), read by ShieldConfig / ShieldAction.
public struct ShieldContextEntry: Codable, Sendable, Hashable {
    public var groupId: GroupID
    public var groupName: String
    public var title: String
    public var subtitle: String
    public var strict: Bool
    public var until: Date?
    public init(groupId: GroupID, groupName: String, title: String, subtitle: String, strict: Bool, until: Date?) {
        self.groupId = groupId; self.groupName = groupName; self.title = title
        self.subtitle = subtitle; self.strict = strict; self.until = until
    }
}

public struct ShieldContextFile: Codable, Sendable {
    public var generatedAt: Date
    /// token key -> entry, one map per token kind (a key is base64 of the JSON-encoded token).
    public var applications: [String: ShieldContextEntry]
    public var categories: [String: ShieldContextEntry]
    public var webDomains: [String: ShieldContextEntry]
    public init(generatedAt: Date, applications: [String: ShieldContextEntry] = [:],
                categories: [String: ShieldContextEntry] = [:], webDomains: [String: ShieldContextEntry] = [:]) {
        self.generatedAt = generatedAt; self.applications = applications
        self.categories = categories; self.webDomains = webDomains
    }
}

/// Token key = base64 of the JSON-encoded token (tokens are Codable + Hashable).
public enum TokenKey {
    public static func key(_ token: ApplicationToken) -> String? { encode(token) }
    public static func key(_ token: ActivityCategoryToken) -> String? { encode(token) }
    public static func key(_ token: WebDomainToken) -> String? { encode(token) }

    private static func encode<T: Encodable>(_ token: T) -> String? {
        // VERIFY: token JSON encoding is stable across processes/launches (it should: it is
        // an opaque Data payload). If not, fall back to hashing `token.hashValue` — but
        // that is per-process-randomized, so it would NOT work across processes.
        guard let data = try? JSONEncoder().encode(token) else { return nil }
        return data.base64EncodedString()
    }
}

public enum ShieldContextStore {
    public static let fileName = "shieldContext.json"

    private static func url(in directory: URL?) -> URL {
        (directory ?? AppGroup.containerURL).appendingPathComponent(fileName)
    }

    public static func write(_ file: ShieldContextFile, directory: URL? = nil) {
        do {
            let data = try TetherJSON.makeEncoder().encode(file)
            try data.write(to: url(in: directory), options: [.atomic])
        } catch {
            TLog.shield.error("shieldContext.json write failed: \(String(describing: error))")
        }
    }

    public static func read(directory: URL? = nil) -> ShieldContextFile? {
        guard let data = try? Data(contentsOf: url(in: directory)) else { return nil }
        return try? TetherJSON.makeDecoder().decode(ShieldContextFile.self, from: data)
    }

    public static func entry(for token: ApplicationToken?) -> ShieldContextEntry? {
        guard let token, let key = TokenKey.key(token) else { return nil }
        return read()?.applications[key]
    }

    public static func entry(for token: ActivityCategoryToken?) -> ShieldContextEntry? {
        guard let token, let key = TokenKey.key(token) else { return nil }
        return read()?.categories[key]
    }

    public static func entry(for token: WebDomainToken?) -> ShieldContextEntry? {
        guard let token, let key = TokenKey.key(token) else { return nil }
        return read()?.webDomains[key]
    }

    /// Best entry for an app that may be shielded directly or through its category.
    public static func entry(application: ApplicationToken?, category: ActivityCategoryToken?) -> ShieldContextEntry? {
        let file = read()
        if let t = application, let k = TokenKey.key(t), let e = file?.applications[k] { return e }
        if let t = category, let k = TokenKey.key(t), let e = file?.categories[k] { return e }
        return nil
    }

    /// For a shield action on an app/site that has no direct entry: it is shielded through a
    /// blocked *category*, but `ShieldActionDelegate` only hands us the app/site token (not the
    /// category). Returns the category entry when that is unambiguous; when several groups block
    /// categories, a non-strict entry with an empty `groupId` (the pause flow then lets the user
    /// choose); a strict entry when every category block is strict; nil when no category is blocked.
    public static func categoryFallbackEntry() -> ShieldContextEntry? {
        let entries = Array((read()?.categories ?? [:]).values)
        guard !entries.isEmpty else { return nil }
        let flexible = entries.filter { !$0.strict }
        guard let first = flexible.min(by: { $0.groupId < $1.groupId }) else { return entries[0] }
        if Set(flexible.map(\.groupId)).count == 1 { return first }
        return ShieldContextEntry(groupId: "", groupName: "this app", title: first.title,
                                  subtitle: first.subtitle, strict: false, until: nil)
    }

    /// Best entry for a web domain that may be shielded directly or through its category.
    public static func entry(webDomain: WebDomainToken?, category: ActivityCategoryToken?) -> ShieldContextEntry? {
        let file = read()
        if let t = webDomain, let k = TokenKey.key(t), let e = file?.webDomains[k] { return e }
        if let t = category, let k = TokenKey.key(t), let e = file?.categories[k] { return e }
        return nil
    }
}
#endif
