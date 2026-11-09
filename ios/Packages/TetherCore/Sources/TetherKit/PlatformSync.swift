#if os(iOS) && canImport(ManagedSettings)
import Foundation
import TetherCore
import TetherAPI

/// Glue between TetherAPI (network + sync) and the Apple-only platform layer. Used by the
/// app (foreground / BGAppRefresh / silent push) and by the TetherPush notification service.
public final class PlatformSync: @unchecked Sendable {
    public static let shared = PlatformSync()

    private let mutex = NSLock()
    private var cachedEngine: SyncEngine?
    private var cachedBaseURL: URL?

    public init() {}

    /// True once a device token and a server URL exist (the device is paired).
    public var isPaired: Bool { Keychain.deviceToken != nil && resolvedBaseURL() != nil }

    /// Server URL: persisted `state.server.baseURL`, else Info.plist `TetherDefaultServerURL`.
    public func resolvedBaseURL() -> URL? {
        if let s = try? StateStore(directory: AppGroup.containerURL).load(), let url = s.server?.baseURL { return url }
        return AppGroup.defaultServerURL
    }

    /// Builds (or returns the cached) engine; nil when not paired.
    public func engine() -> SyncEngine? {
        guard Keychain.deviceToken != nil, let base = resolvedBaseURL() else { return nil }
        mutex.lock(); defer { mutex.unlock() }
        if let e = cachedEngine, cachedBaseURL == base { return e }
        let e = Self.makeEngine(baseURL: base)
        cachedEngine = e; cachedBaseURL = base
        return e
    }

    /// Forget the cached engine (after unpair / re-enroll).
    public func reset() {
        mutex.lock(); defer { mutex.unlock() }
        cachedEngine = nil; cachedBaseURL = nil
    }

    static func makeEngine(baseURL: URL, appVersion: String? = nil) -> SyncEngine {
        let version = appVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "1.0"
        let api = APIClient(baseURL: baseURL, tokenProvider: { Keychain.deviceToken }, appVersion: version)
        return SyncEngine(
            api: api,
            store: StateStore(directory: AppGroup.containerURL),
            blockedGroupIdsProvider: { Reconciler.shared.snapshot().blockedGroupIds },
            authorizationStatusProvider: { AuthorizationManager.currentStatusValue() },
            onBundleChanged: { Reconciler.shared.reconcile() })
    }

    // MARK: Operations

    public func syncNow(reason: SyncReason) async -> SyncOutcome {
        guard let e = engine() else { return .failed(retryAfter: nil) }
        let outcome = await e.syncNow(reason: reason)
        await handleUnauthorized(outcome)
        return outcome
    }

    /// Push entry point (NSE or silent push). Applies the bundle (inline or fetched),
    /// reconciles, acks (inside SyncEngine) and returns the outcome.
    public func handlePush(_ userInfo: [AnyHashable: Any]) async -> SyncOutcome {
        guard let e = engine() else { return .failed(retryAfter: nil) }
        let outcome = await e.handlePush(userInfo)
        await handleUnauthorized(outcome)
        return outcome
    }

    /// Enrolls with a pairing code, stores the token in the Keychain (shared group), then syncs.
    public func enroll(pairingCode: String, server: URL, deviceInfo: DeviceInfo) async throws -> SyncOutcome {
        reset()
        let bootstrap = Self.makeEngine(baseURL: server)
        let token = try await bootstrap.enroll(pairingCode: pairingCode, server: server, deviceInfo: deviceInfo)
        // Throwing write (not the `deviceToken` setter, which swallows errors): a missing
        // keychain-access-groups entitlement (-34018) must surface as a pairing error instead of
        // a silently unpaired device that later reports "couldn't reach the server".
        try Keychain.setString(token, account: Keychain.Account.deviceToken)
        reset()
        return await syncNow(reason: .enrollment)
    }

    private func handleUnauthorized(_ outcome: SyncOutcome) async {
        if case .unauthorized = outcome {
            // The server no longer knows this device. Keep protection state as-is (the lock
            // decides whether the user can disable); just report via the next event flush.
            TLog.sync.error("device token rejected (unauthorized)")
        }
    }
}
#endif
