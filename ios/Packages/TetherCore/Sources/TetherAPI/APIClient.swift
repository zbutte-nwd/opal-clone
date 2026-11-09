import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TetherCore

/// REST client for the `/v1/devices/*` endpoints (contracts/api.md).
///
/// `baseURL` is the server origin (`https://host`); `/v1` is appended automatically unless
/// the base URL's path already ends in `/v1`.
public struct APIClient: Sendable {
    public let baseURL: URL
    public let session: URLSession
    public let appVersion: String
    private let tokenProvider: @Sendable () -> String?

    public static let requestTimeout: TimeInterval = 15

    public init(baseURL: URL, tokenProvider: @escaping @Sendable () -> String?, session: URLSession = .shared,
                appVersion: String = "1.0") {
        self.baseURL = baseURL; self.tokenProvider = tokenProvider; self.session = session; self.appVersion = appVersion
    }

    /// Same session/version, different server and no token (used for enrollment).
    public func withBaseURL(_ url: URL, tokenProvider: @escaping @Sendable () -> String? = { nil }) -> APIClient {
        APIClient(baseURL: url, tokenProvider: tokenProvider, session: session, appVersion: appVersion)
    }

    // MARK: Endpoints

    public func enroll(_ request: EnrollRequest) async throws -> EnrollResponse {
        let (data, _) = try await send("POST", "/devices/enroll", body: request, auth: false)
        return try decode(EnrollResponse.self, data)
    }

    public func fetchPolicy(ifNoneMatch: Int?) async throws -> PolicyFetchResult {
        var headers: [String: String] = [:]
        if let v = ifNoneMatch { headers["If-None-Match"] = "\"\(v)\"" }
        let (data, resp) = try await send("GET", "/devices/me/policy", headers: headers)
        if resp.statusCode == 304 { return .notModified }
        let bundle = try decode(PolicyBundle.self, data)
        return .updated(bundle)
    }

    public func ack(_ request: AckRequest) async throws {
        _ = try await send("POST", "/devices/me/ack", body: request)
    }

    public func postEvents(_ events: [DeviceEvent]) async throws {
        _ = try await send("POST", "/devices/me/events", body: EventsRequest(events: events))
    }

    public func updatePushToken(_ request: PushTokenRequest) async throws {
        _ = try await send("PUT", "/devices/me/push-token", body: request)
    }

    public func createUnlockRequest(_ request: CreateUnlockRequest) async throws -> UnlockRequest {
        let (data, _) = try await send("POST", "/devices/me/unlock-requests", body: request)
        return try decode(UnlockRequest.self, data)
    }

    public func getUnlockRequest(id: String) async throws -> UnlockRequest {
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let (data, _) = try await send("GET", "/devices/me/unlock-requests/\(enc)")
        return try decode(UnlockRequest.self, data)
    }

    public func unpair() async throws {
        _ = try await send("DELETE", "/devices/me")
    }

    /// `PUT /devices/me/local`: 204 = stored (or unchanged hash). 404/405 = server predates the endpoint.
    public func putLocalSnapshot(_ snapshot: LocalSnapshot) async throws -> SnapshotPutResult {
        do {
            _ = try await send("PUT", "/devices/me/local", body: snapshot)
            return .stored
        } catch APIError.notFound {
            return .serverTooOld
        } catch APIError.server(let status, _, _) where status == 405 {
            return .serverTooOld
        }
    }

    // MARK: Plumbing

    func makeURL(_ path: String) throws -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/v1") { base += "/v1" }
        guard let url = URL(string: base + path) else { throw APIError.transport(URLError(.badURL)) }
        return url
    }

    private func send(_ method: String, _ path: String, body: (any Encodable & Sendable)? = nil,
                      auth: Bool = true, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: try makeURL(path))
        req.httpMethod = method
        req.timeoutInterval = Self.requestTimeout
        req.setValue("Tether-iOS/\(appVersion)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do { req.httpBody = try TetherJSON.makeEncoder().encode(AnyEncodable(body)) }
            catch { throw APIError.decoding(error) }
        }
        if auth {
            guard let token = tokenProvider(), !token.isEmpty else { throw APIError.unauthorized }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let (data, resp) = try await perform(req)
        if (200..<300).contains(resp.statusCode) || resp.statusCode == 304 { return (data, resp) }
        throw Self.mapError(status: resp.statusCode, data: data, response: resp)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: request) { data, response, error in
                if let error { cont.resume(throwing: APIError.transport(error)); return }
                guard let http = response as? HTTPURLResponse else {
                    cont.resume(throwing: APIError.transport(URLError(.badServerResponse))); return
                }
                cont.resume(returning: (data ?? Data(), http))
            }
            task.resume()
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try TetherJSON.makeDecoder().decode(type, from: data) }
        catch { throw APIError.decoding(error) }
    }

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable { var code: String?; var message: String? }
        var error: Body?
    }

    static func mapError(status: Int, data: Data, response: HTTPURLResponse) -> APIError {
        let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        let code = env?.error?.code, message = env?.error?.message
        switch status {
        case 401: return .unauthorized
        case 404: return .notFound
        case 400, 422: return .validation(message ?? code ?? "Invalid request")
        case 429:
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            return .rateLimited(retryAfter: retry)
        default: return .server(status: status, code: code, message: message)
        }
    }
}

private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ v: any Encodable) { value = v }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
