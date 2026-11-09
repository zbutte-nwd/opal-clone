import Foundation
import TetherCore

/// Read-only snapshot of phone-made state uploaded to `PUT /v1/devices/me/local`
/// (`contracts/device-local.schema.json`). Display only on the server. NEVER carries app identities:
/// groups report counts of apps/categories/web tokens, nothing else from a selection.
public struct LocalSnapshot: Codable, Sendable, Equatable {
    public struct Counts: Codable, Sendable, Equatable {
        public var apps: Int, categories: Int, webTokens: Int
        public init(apps: Int = 0, categories: Int = 0, webTokens: Int = 0) {
            self.apps = apps; self.categories = categories; self.webTokens = webTokens
        }
    }

    public struct Group: Codable, Sendable, Equatable {
        public var id: GroupID
        public var name: String
        public var colorHex: String?
        public var webDomains: [String]
        public var counts: Counts
    }

    public struct Settings: Codable, Sendable, Equatable {
        public var protectionEnabled: Bool
        public var protectionLock: ProtectionLock
    }

    public var hash: String
    public var reportedAt: Date
    public var groups: [Group]
    public var rules: [Rule]
    public var sessions: [FocusSession]
    public var pauses: [Pause]
    public var settings: Settings

    /// Builds the snapshot from persisted state. `counts` comes from the platform's selections (TetherKit);
    /// `protectionLock` is the effective lock. Sessions: active, upcoming, or ended within 24 h of `now`.
    /// Pauses: active or upcoming.
    public static func make(state: PersistedState, counts: [GroupID: Counts], protectionLock: ProtectionLock,
                            now: Date) -> LocalSnapshot {
        let dayAgo = now.addingTimeInterval(-24 * 3600)
        var s = LocalSnapshot(
            hash: "",
            reportedAt: now,
            groups: state.localGroups.map {
                Group(id: $0.id, name: $0.name, colorHex: $0.colorHex, webDomains: $0.webDomains, counts: counts[$0.id] ?? Counts())
            },
            rules: state.localRules.map { var r = $0; r.source = .local; return r },
            sessions: state.sessions.filter { ($0.endedAt ?? $0.endsAt) >= dayAgo },
            pauses: state.pauses.filter { $0.endsAt > now },
            settings: Settings(protectionEnabled: state.protection.enabled, protectionLock: protectionLock))
        s.hash = s.contentHash()
        return s
    }

    /// SHA-256 hex over the sorted-keys JSON of everything except `hash` and `reportedAt`, so an unchanged
    /// snapshot re-reported later hashes the same (server answers 204 without a write; the app skips the upload).
    public func contentHash() -> String {
        struct Content: Encodable {
            let groups: [Group], rules: [Rule], sessions: [FocusSession], pauses: [Pause], settings: Settings
        }
        let enc = TetherJSON.makeEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? enc.encode(Content(groups: groups, rules: rules, sessions: sessions, pauses: pauses, settings: settings))) ?? Data()
        return TetherDigest.sha256Hex(data)
    }
}

public enum SnapshotPutResult: Sendable, Equatable {
    case stored
    /// 404/405: the server predates the endpoint. Keep the snapshot and retry on a later sync.
    case serverTooOld
}
