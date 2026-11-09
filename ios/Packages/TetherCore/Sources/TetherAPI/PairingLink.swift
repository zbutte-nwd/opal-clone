import Foundation

/// Parsed `tether://pair?code=K7Q2-M9XD&server=https%3A%2F%2Fhost` link / QR payload.
public struct PairingLink: Sendable, Hashable {
    public let code: String
    public let serverURL: URL

    public init(code: String, serverURL: URL) { self.code = code; self.serverURL = serverURL }

    public static func parse(_ string: String) -> PairingLink? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return parse(url)
    }

    public static func parse(_ url: URL) -> PairingLink? {
        guard url.scheme?.lowercased() == "tether",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              (comps.host ?? "").lowercased() == "pair" || comps.path == "/pair" else { return nil }
        let items = comps.queryItems ?? []
        guard let rawCode = items.first(where: { $0.name == "code" })?.value,
              let code = normalizeCode(rawCode),
              let rawServer = items.first(where: { $0.name == "server" })?.value,
              let server = URL(string: rawServer),
              let scheme = server.scheme?.lowercased(), scheme == "https" || scheme == "http",
              server.host != nil else { return nil }
        return PairingLink(code: code, serverURL: server)
    }

    /// Uppercases, strips spaces/dashes/other separators and re-inserts the dash: `k7q2 m9xd` -> `K7Q2-M9XD`.
    /// Returns nil unless the result is exactly 8 alphanumerics.
    public static func normalizeCode(_ raw: String) -> String? {
        let chars = raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard chars.count == 8 else { return nil }
        return String(chars.prefix(4)) + "-" + String(chars.suffix(4))
    }
}
