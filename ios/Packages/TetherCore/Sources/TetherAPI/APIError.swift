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
