import Foundation
import Observation
import TetherAPI

enum DeepLink: Identifiable, Equatable {
    case pair(code: String?, server: URL?)
    case pause(groupId: String?)
    case newSession

    var id: String {
        switch self {
        case .pair: return "pair"
        case .pause(let g): return "pause-\(g ?? "any")"
        case .newSession: return "newSession"
        }
    }
}

/// Parses `tether://pair?code=…&server=…`, `tether://pause?group=…`, `tether://session/new`.
@MainActor @Observable
final class DeepLinkRouter {
    var route: DeepLink?
    /// Link received before onboarding finished; replayed afterwards.
    var pending: DeepLink?

    func handle(_ url: URL) {
        guard let link = Self.parse(url) else { return }
        route = link
    }

    func handle(urlString: String) {
        if let u = URL(string: urlString) { handle(u) }
    }

    func releasePending() {
        if let p = pending { route = p; pending = nil }
    }

    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == "tether",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let host = (comps.host ?? "").lowercased()
        let path = comps.path.lowercased()
        let items = comps.queryItems ?? []
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        switch (host, path) {
        case ("pair", _), ("", "/pair"):
            let code = q("code").flatMap { PairingLink.normalizeCode($0) ?? $0 }
            return .pair(code: code, server: q("server").flatMap(URL.init(string:)))
        case ("pause", _), ("", "/pause"):
            return .pause(groupId: q("group"))
        case ("session", "/new"), ("session", ""), ("", "/session/new"):
            return .newSession
        default:
            return nil
        }
    }
}
