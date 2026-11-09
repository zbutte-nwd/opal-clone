import Foundation

public enum APIError: Error, Sendable {
    case unauthorized
    case notFound
    case validation(String)
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int, code: String?, message: String?)
    case transport(Error)
    case decoding(Error)

    /// Worth retrying later with backoff.
    public var isRetryable: Bool {
        switch self {
        case .transport, .rateLimited: return true
        case .server(let status, _, _): return status >= 500 || status == 408
        case .unauthorized, .notFound, .validation, .decoding: return false
        }
    }
}

extension APIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "The server refused the request (401)."
        case .notFound: return "Not found (404)."
        case .validation(let m): return m
        case .rateLimited: return "Too many attempts. Wait a minute and try again."
        case .server(let status, let code, let message): return "Server error \(status)" + ((message ?? code).map { ": \($0)" } ?? ".")
        case .transport(let e): return "Couldn't reach the server: \(e.localizedDescription)"
        case .decoding: return "The server's reply wasn't understood (is this a Tether server?)."
        }
    }
}
