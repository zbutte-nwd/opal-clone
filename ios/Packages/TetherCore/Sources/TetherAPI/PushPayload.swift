import Foundation
import TetherCore

/// The `tether` object of an APNs payload.
public struct PushPayload: Decodable, Sendable {
    public enum Kind: Sendable, Hashable { case policyUpdated, unlockDecided, unknown(String) }

    public let type: Kind
    public let version: Int?
    public let bundle: PolicyBundle?
    public let requestId: String?

    enum CodingKeys: String, CodingKey { case type, version, bundle, requestId }

    public init(type: Kind, version: Int? = nil, bundle: PolicyBundle? = nil, requestId: String? = nil) {
        self.type = type; self.version = version; self.bundle = bundle; self.requestId = requestId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        switch raw {
        case "policyUpdated": type = .policyUpdated
        case "unlockDecided": type = .unlockDecided
        default: type = .unknown(raw)
        }
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        // A malformed inline bundle must not poison the push: fall back to a normal fetch.
        bundle = try? c.decodeIfPresent(PolicyBundle.self, forKey: .bundle)
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
    }

    /// Parses the `tether` key of a notification `userInfo`.
    public static func parse(_ userInfo: [AnyHashable: Any]) -> PushPayload? {
        guard let obj = userInfo["tether"], JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return try? TetherJSON.makeDecoder().decode(PushPayload.self, from: data)
    }
}
