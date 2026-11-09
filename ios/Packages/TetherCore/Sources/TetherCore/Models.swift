// Models.swift — canonical data model. JSON shape is defined by
// contracts/policy-bundle.schema.json and contracts/engine-input.schema.json.
// Do not rename fields without changing the contract (and the server) first.

import Foundation

public typealias GroupID = String
public typealias RuleID = String

public enum Source: String, Codable, Sendable, Hashable {
    case server, local
}

// MARK: - Groups

/// A named set of things to block. App / category / web *tokens* are NOT stored here —
/// they are device-local (`TetherKit.SelectionStore`, keyed by `id`). `webDomains` are
/// plain domain strings that the server may push directly.
public struct BlockGroup: Codable, Sendable, Hashable, Identifiable {
    public var id: GroupID
    public var name: String
    public var colorHex: String?
    public var webDomains: [String]
    public var source: Source

    public init(id: GroupID, name: String, colorHex: String? = nil, webDomains: [String] = [], source: Source = .local) {
        self.id = id; self.name = name; self.colorHex = colorHex; self.webDomains = webDomains; self.source = source
    }

    enum CodingKeys: String, CodingKey { case id, name, colorHex, webDomains, source }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(GroupID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        webDomains = try c.decodeIfPresent([String].self, forKey: .webDomains) ?? []
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .server
    }
}

// MARK: - Rules & triggers

/// ISO weekday: 1 = Monday … 7 = Sunday.
public typealias ISOWeekday = Int

/// A weekly time window. `days` = days on which the window STARTS. `start`/`end` are
/// "HH:mm" wall-clock; `end` may be "24:00"; `end < start` = overnight; `end == start` = never.
public struct Window: Codable, Sendable, Hashable {
    public var days: [ISOWeekday]
    public var start: String
    public var end: String
    public init(days: [ISOWeekday], start: String, end: String) {
        self.days = days; self.start = start; self.end = end
    }
}

public enum Trigger: Codable, Sendable, Hashable {
    case schedule(windows: [Window])
    case usageLimit(dailyMinutes: Int, days: [ISOWeekday])
    case manual(active: Bool)

    enum CodingKeys: String, CodingKey { case type, windows, dailyMinutes, days, active }
    enum Kind: String, Codable { case schedule, usageLimit, manual }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .schedule: self = .schedule(windows: try c.decode([Window].self, forKey: .windows))
        case .usageLimit: self = .usageLimit(dailyMinutes: try c.decode(Int.self, forKey: .dailyMinutes),
                                             days: try c.decode([ISOWeekday].self, forKey: .days))
        case .manual: self = .manual(active: try c.decode(Bool.self, forKey: .active))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .schedule(let windows):
            try c.encode(Kind.schedule, forKey: .type); try c.encode(windows, forKey: .windows)
        case .usageLimit(let minutes, let days):
            try c.encode(Kind.usageLimit, forKey: .type); try c.encode(minutes, forKey: .dailyMinutes); try c.encode(days, forKey: .days)
        case .manual(let active):
            try c.encode(Kind.manual, forKey: .type); try c.encode(active, forKey: .active)
        }
    }
}

public enum RuleAction: String, Codable, Sendable, Hashable { case block, allow }
public enum Strictness: String, Codable, Sendable, Hashable { case flexible, strict }

public struct Rule: Codable, Sendable, Hashable, Identifiable {
    public var id: RuleID
    public var name: String
    public var groupIds: [GroupID]
    public var enabled: Bool
    public var action: RuleAction
    public var trigger: Trigger
    public var strictness: Strictness
    public var priority: Int
    public var maxPausesPerDay: Int?
    public var source: Source

    public init(id: RuleID, name: String, groupIds: [GroupID], enabled: Bool = true, action: RuleAction = .block,
                trigger: Trigger, strictness: Strictness = .flexible, priority: Int = 0,
                maxPausesPerDay: Int? = nil, source: Source = .local) {
        self.id = id; self.name = name; self.groupIds = groupIds; self.enabled = enabled; self.action = action
        self.trigger = trigger; self.strictness = strictness; self.priority = priority
        self.maxPausesPerDay = maxPausesPerDay; self.source = source
    }

    enum CodingKeys: String, CodingKey { case id, name, groupIds, enabled, action, trigger, strictness, priority, maxPausesPerDay, source }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(RuleID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        groupIds = try c.decode([GroupID].self, forKey: .groupIds)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        action = try c.decode(RuleAction.self, forKey: .action)
        trigger = try c.decode(Trigger.self, forKey: .trigger)
        strictness = try c.decode(Strictness.self, forKey: .strictness)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        maxPausesPerDay = try c.decodeIfPresent(Int.self, forKey: .maxPausesPerDay)
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .server
    }
}

// MARK: - Server overrides, sessions, pauses

public enum OverrideAction: String, Codable, Sendable, Hashable { case block, unblock }

/// Server-issued "block/unblock these groups now (until endsAt)". Supreme precedence.
public struct Override: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var groupIds: [GroupID]
    public var action: OverrideAction
    public var startsAt: Date
    public var endsAt: Date?
    public var issuedAt: Date
    public var reason: String?
    public init(id: String, groupIds: [GroupID], action: OverrideAction, startsAt: Date, endsAt: Date? = nil, issuedAt: Date, reason: String? = nil) {
        self.id = id; self.groupIds = groupIds; self.action = action; self.startsAt = startsAt
        self.endsAt = endsAt; self.issuedAt = issuedAt; self.reason = reason
    }
}

/// Device-local focus session ("block Social for 25 min"). `strict` = cannot pause or end early.
public struct FocusSession: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String?
    public var groupIds: [GroupID]
    public var startsAt: Date
    public var endsAt: Date
    public var strict: Bool
    public var endedAt: Date?
    public init(id: String, name: String? = nil, groupIds: [GroupID], startsAt: Date, endsAt: Date, strict: Bool, endedAt: Date? = nil) {
        self.id = id; self.name = name; self.groupIds = groupIds; self.startsAt = startsAt
        self.endsAt = endsAt; self.strict = strict; self.endedAt = endedAt
    }
}

/// Device-local temporary unblock of non-strict blocks.
public struct Pause: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var groupIds: [GroupID]
    public var startsAt: Date
    public var endsAt: Date
    public var ruleId: RuleID?
    public init(id: String, groupIds: [GroupID], startsAt: Date, endsAt: Date, ruleId: RuleID? = nil) {
        self.id = id; self.groupIds = groupIds; self.startsAt = startsAt; self.endsAt = endsAt; self.ruleId = ruleId
    }
}

/// Recorded by the Monitor extension when a usage-limit rule's threshold is reached.
/// `day` is the local calendar day "YYYY-MM-DD" in the effective time zone.
public struct UsageLimitHit: Codable, Sendable, Hashable {
    public var ruleId: RuleID
    public var day: String
    public init(ruleId: RuleID, day: String) { self.ruleId = ruleId; self.day = day }
}

// MARK: - Policy bundle

public enum ProtectionLock: String, Codable, Sendable, Hashable, CaseIterable {
    /// In-app disable requires the partner-set Tether PIN (no biometrics).
    case partnerPIN
    /// In-app disable requires server/admin approval.
    case remoteApproval
    /// No in-app disable; revoke in iOS Settings (Screen Time passcode).
    case osOnly
}

public struct PolicySettings: Codable, Sendable, Hashable {
    public var protectionLock: ProtectionLock
    public var allowLocalRules: Bool
    public var denyAppRemoval: Bool
    public init(protectionLock: ProtectionLock = .partnerPIN, allowLocalRules: Bool = true, denyAppRemoval: Bool = true) {
        self.protectionLock = protectionLock; self.allowLocalRules = allowLocalRules; self.denyAppRemoval = denyAppRemoval
    }
}

/// Server → device policy. Versioned; device acks the version it applied.
public struct PolicyBundle: Codable, Sendable, Hashable {
    public var version: Int
    public var generatedAt: Date
    /// IANA identifier. nil = use the device's local time zone.
    public var timeZone: String?
    public var groups: [BlockGroup]
    public var rules: [Rule]
    public var overrides: [Override]
    public var settings: PolicySettings
    public init(version: Int, generatedAt: Date, timeZone: String? = nil, groups: [BlockGroup] = [], rules: [Rule] = [],
                overrides: [Override] = [], settings: PolicySettings = PolicySettings()) {
        self.version = version; self.generatedAt = generatedAt; self.timeZone = timeZone; self.groups = groups
        self.rules = rules; self.overrides = overrides; self.settings = settings
    }
}

// MARK: - Engine I/O

public struct EngineInput: Codable, Sendable, Hashable {
    public var bundle: PolicyBundle?
    public var localGroups: [BlockGroup]
    public var localRules: [Rule]
    public var sessions: [FocusSession]
    public var pauses: [Pause]
    public var usageLimitHits: [UsageLimitHit]
    public init(bundle: PolicyBundle? = nil, localGroups: [BlockGroup] = [], localRules: [Rule] = [],
                sessions: [FocusSession] = [], pauses: [Pause] = [], usageLimitHits: [UsageLimitHit] = []) {
        self.bundle = bundle; self.localGroups = localGroups; self.localRules = localRules
        self.sessions = sessions; self.pauses = pauses; self.usageLimitHits = usageLimitHits
    }

    /// Bundle groups followed by local groups (bundle wins on duplicate id).
    public var allGroups: [BlockGroup] {
        var seen = Set<GroupID>(); var out: [BlockGroup] = []
        for g in (bundle?.groups ?? []) + localGroups where seen.insert(g.id).inserted { out.append(g) }
        return out
    }
}

public enum ReasonKind: String, Codable, Sendable, Hashable { case override, session, rule, pause, none }

public struct Reason: Codable, Sendable, Hashable {
    public var kind: ReasonKind
    public var id: String?
    public init(kind: ReasonKind, id: String? = nil) { self.kind = kind; self.id = id }
    public static let none = Reason(kind: .none)
}

public struct GroupState: Codable, Sendable, Hashable {
    public var groupId: GroupID
    public var blocked: Bool
    public var strict: Bool
    public var reason: Reason
    /// Next time this group's state may change (best effort; filled by TransitionPlanner, nil from evaluate()).
    public var until: Date?
    public init(groupId: GroupID, blocked: Bool, strict: Bool = false, reason: Reason = .none, until: Date? = nil) {
        self.groupId = groupId; self.blocked = blocked; self.strict = strict; self.reason = reason; self.until = until
    }
}

public enum PauseEligibility: Sendable, Hashable {
    case allowed
    case notBlocked
    case strict
    case budgetExhausted(limit: Int)
}

// MARK: - Persisted device state (App Group state.json)

public enum AuthMode: String, Codable, Sendable, Hashable { case individual, child }

public struct ProtectionState: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var lock: ProtectionLock
    public var authMode: AuthMode
    public var enabledAt: Date?
    public init(enabled: Bool = false, lock: ProtectionLock = .partnerPIN, authMode: AuthMode = .individual, enabledAt: Date? = nil) {
        self.enabled = enabled; self.lock = lock; self.authMode = authMode; self.enabledAt = enabledAt
    }
}

public struct ServerConfig: Codable, Sendable, Hashable {
    public var baseURL: URL
    public var deviceId: String
    public init(baseURL: URL, deviceId: String) { self.baseURL = baseURL; self.deviceId = deviceId }
}

public enum DeviceEventType: String, Codable, Sendable, Hashable {
    case authorizationChanged, protectionDisabled, protectionEnabled, sessionStarted, sessionEnded,
         pauseStarted, usageLimitReached, heartbeat
}

public struct DeviceEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var type: DeviceEventType
    public var occurredAt: Date
    public var data: [String: String]?
    public init(id: String = TetherID.make("evt"), type: DeviceEventType, occurredAt: Date = Date(), data: [String: String]? = nil) {
        self.id = id; self.type = type; self.occurredAt = occurredAt; self.data = data
    }
}

public struct PersistedState: Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int = PersistedState.currentSchemaVersion
    public var bundle: PolicyBundle?
    public var localGroups: [BlockGroup] = []
    public var localRules: [Rule] = []
    public var sessions: [FocusSession] = []
    public var pauses: [Pause] = []
    public var usageLimitHits: [UsageLimitHit] = []
    public var appliedBundleVersion: Int?
    public var lastReconciledAt: Date?
    public var lastSyncAt: Date?
    public var pendingEvents: [DeviceEvent] = []
    public var protection = ProtectionState()
    public var server: ServerConfig?

    public init() {}

    public var engineInput: EngineInput {
        EngineInput(bundle: bundle, localGroups: localGroups, localRules: localRules,
                    sessions: sessions, pauses: pauses, usageLimitHits: usageLimitHits)
    }
}

// MARK: - IDs & JSON coding

public enum TetherID {
    /// e.g. TetherID.make("ses") -> "ses_k3j9x0q2m1"
    public static func make(_ prefix: String) -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        var s = prefix + "_"
        for _ in 0..<12 { s.append(alphabet[Int.random(in: 0..<alphabet.count)]) }
        return s
    }
}

/// Shared encoder/decoder: RFC 3339 dates, with or without fractional seconds.
public enum TetherJSON {
    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = parseDate(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid RFC 3339 date: \(s)")
        }
        return d
    }

    public static func makeEncoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(formatDate(date))
        }
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return e
    }

    public static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    public static func formatDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
