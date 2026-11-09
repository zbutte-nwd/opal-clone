import Foundation
import TetherCore

public struct EnrollRequest: Codable, Sendable, Hashable {
    public var pairingCode: String
    public var name: String
    public var model: String
    public var osVersion: String
    public var appVersion: String
    public init(pairingCode: String, name: String, model: String, osVersion: String, appVersion: String) {
        self.pairingCode = pairingCode; self.name = name; self.model = model
        self.osVersion = osVersion; self.appVersion = appVersion
    }
    public init(pairingCode: String, deviceInfo: DeviceInfo) {
        self.init(pairingCode: pairingCode, name: deviceInfo.name, model: deviceInfo.model,
                  osVersion: deviceInfo.osVersion, appVersion: deviceInfo.appVersion)
    }
}

public struct EnrollResponse: Codable, Sendable, Hashable {
    public var deviceId: String
    public var deviceToken: String
    /// ARCHITECTURE §7 mentions `baseURL`; api.md does not. Optional.
    public var baseURL: URL?
    public init(deviceId: String, deviceToken: String, baseURL: URL? = nil) {
        self.deviceId = deviceId; self.deviceToken = deviceToken; self.baseURL = baseURL
    }
}

public enum PolicyFetchResult: Sendable, Hashable {
    case notModified
    case updated(PolicyBundle)
}

public enum AuthorizationStatusValue: String, Codable, Sendable, Hashable {
    case approved, denied, notDetermined
}

public struct AckRequest: Codable, Sendable, Hashable {
    public var version: Int
    public var appliedAt: Date
    public var blockedGroupIds: [String]
    public var authorizationStatus: AuthorizationStatusValue
    public init(version: Int, appliedAt: Date, blockedGroupIds: [String], authorizationStatus: AuthorizationStatusValue) {
        self.version = version; self.appliedAt = appliedAt
        self.blockedGroupIds = blockedGroupIds; self.authorizationStatus = authorizationStatus
    }
}

public struct EventsRequest: Codable, Sendable, Hashable {
    public var events: [DeviceEvent]
    public init(events: [DeviceEvent]) { self.events = events }
}

public enum PushEnvironment: String, Codable, Sendable, Hashable { case sandbox, production }

public struct PushTokenRequest: Codable, Sendable, Hashable {
    /// Hex-encoded APNs device token.
    public var token: String
    public var environment: PushEnvironment
    public init(token: String, environment: PushEnvironment) { self.token = token; self.environment = environment }
    public init(tokenData: Data, environment: PushEnvironment) {
        self.init(token: tokenData.map { String(format: "%02x", $0) }.joined(), environment: environment)
    }
}

public enum UnlockKind: String, Codable, Sendable, Hashable { case groups, disableProtection }
public enum UnlockStatus: String, Codable, Sendable, Hashable { case pending, approved, denied, expired }

public struct CreateUnlockRequest: Codable, Sendable, Hashable {
    public var kind: UnlockKind
    public var groupIds: [String]?
    public var minutes: Int?
    public var reason: String?
    public init(kind: UnlockKind, groupIds: [String]? = nil, minutes: Int? = nil, reason: String? = nil) {
        self.kind = kind; self.groupIds = groupIds; self.minutes = minutes; self.reason = reason
    }
}

public struct UnlockRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var deviceId: String
    public var kind: UnlockKind
    public var groupIds: [String]
    public var minutes: Int?
    public var reason: String?
    public var status: UnlockStatus
    public var createdAt: Date
    public var decidedAt: Date?
    public var overrideId: String?

    enum CodingKeys: String, CodingKey { case id, deviceId, kind, groupIds, minutes, reason, status, createdAt, decidedAt, overrideId }

    public init(id: String, deviceId: String, kind: UnlockKind, groupIds: [String] = [], minutes: Int? = nil,
                reason: String? = nil, status: UnlockStatus, createdAt: Date, decidedAt: Date? = nil, overrideId: String? = nil) {
        self.id = id; self.deviceId = deviceId; self.kind = kind; self.groupIds = groupIds; self.minutes = minutes
        self.reason = reason; self.status = status; self.createdAt = createdAt; self.decidedAt = decidedAt
        self.overrideId = overrideId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        kind = try c.decode(UnlockKind.self, forKey: .kind)
        groupIds = try c.decodeIfPresent([String].self, forKey: .groupIds) ?? []
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        status = try c.decode(UnlockStatus.self, forKey: .status)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        decidedAt = try c.decodeIfPresent(Date.self, forKey: .decidedAt)
        overrideId = try c.decodeIfPresent(String.self, forKey: .overrideId)
    }
}
