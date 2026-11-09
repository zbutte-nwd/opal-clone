import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TetherCore
@testable import TetherAPI

struct RecordedRequest: @unchecked Sendable {
    let request: URLRequest
    let body: Data?
    var method: String { request.httpMethod ?? "" }
    var path: String { request.url?.path ?? "" }
    func header(_ n: String) -> String? { request.value(forHTTPHeaderField: n) }
    func json() -> [String: Any]? { body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (RecordedRequest) throws -> (Int, [String: String], Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: Handler?
    nonisolated(unsafe) private static var _recorded: [RecordedRequest] = []

    static var handler: Handler? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }
    static var recorded: [RecordedRequest] { lock.lock(); defer { lock.unlock() }; return _recorded }
    static func reset() { lock.lock(); _handler = nil; _recorded = []; lock.unlock() }

    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            body = data
        }
        let rec = RecordedRequest(request: request, body: body)
        Self.lock.lock(); Self._recorded.append(rec); let h = Self._handler; Self.lock.unlock()
        guard let h else { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        do {
            let (status, headers, data) = try h(rec)
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class InMemoryStore: StateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state: PersistedState
    init(_ s: PersistedState = PersistedState()) { state = s }
    func load() throws -> PersistedState { lock.lock(); defer { lock.unlock() }; return state }
    @discardableResult
    func update(_ body: (inout PersistedState) throws -> Void) throws -> PersistedState {
        lock.lock(); defer { lock.unlock() }
        var s = state; try body(&s); state = s; return s
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func increment() { lock.lock(); n += 1; lock.unlock() }
}

enum Fixtures {
    static let dir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("contracts/fixtures")
    static func data(_ name: String) throws -> Data { try Data(contentsOf: dir.appendingPathComponent(name)) }
    static func object(_ name: String) throws -> [AnyHashable: Any] {
        try JSONSerialization.jsonObject(with: data(name)) as! [AnyHashable: Any]
    }
    static func bundle(version: Int = 42) throws -> PolicyBundle {
        var b = try TetherJSON.makeDecoder().decode(PolicyBundle.self, from: data("policy-bundle.example.json"))
        b.version = version
        return b
    }
}
