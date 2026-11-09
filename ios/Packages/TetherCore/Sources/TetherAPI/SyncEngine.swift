import Foundation
import TetherCore

public enum SyncReason: String, Sendable, Hashable {
    case launch, foreground, push, background, monitor, manual, enrollment
}

public enum SyncOutcome: Sendable, Hashable {
    /// Nothing new from the server.
    case noChange
    /// A new bundle (version) was stored, `onBundleChanged` ran and an ack was attempted.
    case updated(version: Int)
    /// Server rejected the device token: the device was unpaired / revoked.
    case unauthorized
    /// A push said an unlock request was decided; caller should fetch it (`APIClient.getUnlockRequest`).
    case unlockDecided(requestId: String)
    /// Failed; `retryAfter` is the backoff delay (nil = not retryable).
    case failed(retryAfter: TimeInterval?)
}

public actor SyncEngine {
    private let api: APIClient
    private let store: any StateStoring
    private let now: @Sendable () -> Date
    private let onBundleChanged: @Sendable () async -> Void
    private let blockedGroupIdsProvider: @Sendable () async -> [String]
    private let authorizationStatusProvider: @Sendable () async -> AuthorizationStatusValue
    /// Current phone-made state, or nil when unavailable (extensions don't upload it).
    private let snapshotProvider: @Sendable () async -> LocalSnapshot?
    /// Hash the server last accepted; in memory, so a relaunch re-sends once (server answers 204, no write).
    private(set) var lastUploadedSnapshotHash: String?
    private var snapshotDebounce: Task<Void, Never>?
    private let jitter: @Sendable () -> Double

    private var inFlight: Task<SyncOutcome, Never>?
    private var failures = 0
    private var lastAckedVersion: Int?

    public private(set) var nextRetryDelay: TimeInterval?
    public var consecutiveFailures: Int { failures }

    public static let baseDelay: TimeInterval = 1
    public static let maxDelay: TimeInterval = 300

    /// `jitter` returns a multiplier applied to the exponential delay (default 0.75...1.25).
    public init(api: APIClient,
                store: any StateStoring,
                now: @escaping @Sendable () -> Date = Date.init,
                blockedGroupIdsProvider: @escaping @Sendable () async -> [String] = { [] },
                authorizationStatusProvider: @escaping @Sendable () async -> AuthorizationStatusValue = { .approved },
                snapshotProvider: @escaping @Sendable () async -> LocalSnapshot? = { nil },
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.75...1.25) },
                onBundleChanged: @escaping @Sendable () async -> Void) {
        self.api = api; self.store = store; self.now = now
        self.blockedGroupIdsProvider = blockedGroupIdsProvider
        self.authorizationStatusProvider = authorizationStatusProvider
        self.snapshotProvider = snapshotProvider
        self.jitter = jitter
        self.onBundleChanged = onBundleChanged
    }

    /// Exponential backoff 1 s, 2 s, 4 s … capped at 5 min (jitter applied before the cap).
    public static func backoffDelay(failures: Int, jitter: Double = 1) -> TimeInterval {
        let exp = pow(2.0, Double(max(0, failures - 1)))
        return min(maxDelay, baseDelay * exp * jitter)
    }

    // MARK: Sync

    public func syncNow(reason: SyncReason) async -> SyncOutcome {
        if let t = inFlight { return await t.value }
        let task = Task { () -> SyncOutcome in
            let r = await self.runSync()
            self.inFlight = nil
            return r
        }
        inFlight = task
        return await task.value
    }

    public nonisolated func handlePush(_ userInfo: [AnyHashable: Any]) async -> SyncOutcome {
        await handle(PushPayload.parse(userInfo))
    }

    private func handle(_ payload: PushPayload?) async -> SyncOutcome {
        guard let payload else { return await syncNow(reason: .push) }
        switch payload.type {
        case .unlockDecided:
            if let id = payload.requestId { return .unlockDecided(requestId: id) }
            return await syncNow(reason: .push)
        case .policyUpdated:
            if let t = inFlight { _ = await t.value }
            let current = (try? store.load())?.bundle?.version
            let pushed = payload.bundle?.version ?? payload.version
            if let pushed, let current, pushed <= current { return .noChange }
            if let bundle = payload.bundle, bundle.version > (current ?? -1) {
                return await applyBundle(bundle)
            }
            return await syncNow(reason: .push)
        case .unknown:
            return await syncNow(reason: .push)
        }
    }

    // MARK: Enrollment

    /// Enrolls against `server`, persists `ServerConfig`, and returns the device token
    /// (the caller must put it in the Keychain).
    public func enroll(pairingCode: String, server: URL, deviceInfo: DeviceInfo) async throws -> String {
        let code = PairingLink.normalizeCode(pairingCode) ?? pairingCode
        let client = api.withBaseURL(server)
        let resp = try await client.enroll(EnrollRequest(pairingCode: code, deviceInfo: deviceInfo))
        let config = ServerConfig(baseURL: resp.baseURL ?? server, deviceId: resp.deviceId)
        try store.update { $0.server = config }
        return resp.deviceToken
    }

    // MARK: Phone-made snapshot

    /// After a local change: upload the snapshot ~`delay` later, coalescing bursts of edits.
    public func scheduleSnapshotUpload(delay: TimeInterval = 2) {
        snapshotDebounce?.cancel()
        snapshotDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.uploadSnapshotIfChanged()
        }
    }

    /// Uploads only while paired and only when the content hash changed. Failures are retried on a later
    /// sync and never fail the sync itself (the snapshot is display-only).
    public func uploadSnapshotIfChanged() async {
        guard (try? store.load().server) != nil, let snap = await snapshotProvider(),
              snap.hash != lastUploadedSnapshotHash else { return }
        if case .stored? = try? await api.putLocalSnapshot(snap) { lastUploadedSnapshotHash = snap.hash }
    }

    // MARK: Internals

    private func runSync() async -> SyncOutcome {
        let outcome = await runPolicySync()
        if case .unauthorized = outcome { return outcome }
        await uploadSnapshotIfChanged()
        return outcome
    }

    private func runPolicySync() async -> SyncOutcome {
        var firstError: APIError?

        // (a) flush events
        do { try await flushEvents() }
        catch let e as APIError {
            if case .unauthorized = e { return .unauthorized }
            firstError = e
        } catch { firstError = .transport(error) }

        // (b) fetch
        let current: Int?
        do { current = try store.load().bundle?.version } catch { return fail(.decoding(error)) }
        do {
            switch try await api.fetchPolicy(ifNoneMatch: current) {
            case .updated(let bundle):
                let r = await applyBundle(bundle)
                if case .updated = r, let e = firstError { return fail(e) }
                return r
            case .notModified:
                let t = now()
                let state = try? store.update { $0.lastSyncAt = t }
                if let v = state?.bundle?.version, lastAckedVersion != v {
                    if let e = await sendAck(version: v) {
                        if case .unauthorized = e { return .unauthorized }
                        return fail(e)
                    }
                }
                if let e = firstError { return fail(e) }
                succeeded()
                return .noChange
            }
        } catch let e as APIError {
            if case .unauthorized = e { return .unauthorized }
            return fail(e)
        } catch { return fail(.transport(error)) }
    }

    private func flushEvents() async throws {
        let pending = try store.load().pendingEvents
        guard !pending.isEmpty else { return }
        try await api.postEvents(pending)
        let sent = Set(pending.map(\.id))
        try store.update { $0.pendingEvents.removeAll { sent.contains($0.id) } }
    }

    /// Store → onBundleChanged (caller reconciles) → ack.
    private func applyBundle(_ bundle: PolicyBundle) async -> SyncOutcome {
        let t = now()
        do { try store.update { $0.bundle = bundle; $0.lastSyncAt = t } }
        catch { return fail(.decoding(error)) }
        await onBundleChanged()
        if let e = await sendAck(version: bundle.version) {
            if case .unauthorized = e { return .unauthorized }
            return fail(e)
        }
        succeeded()
        return .updated(version: bundle.version)
    }

    /// Returns the error on failure.
    private func sendAck(version: Int) async -> APIError? {
        let blocked = await blockedGroupIdsProvider()
        let status = await authorizationStatusProvider()
        do {
            try await api.ack(AckRequest(version: version, appliedAt: now(), blockedGroupIds: blocked, authorizationStatus: status))
            lastAckedVersion = version
            return nil
        } catch let e as APIError { return e }
        catch { return .transport(error) }
    }

    private func succeeded() { failures = 0; nextRetryDelay = nil }

    private func fail(_ error: APIError) -> SyncOutcome {
        guard error.isRetryable else { return .failed(retryAfter: nil) }
        failures += 1
        var delay = Self.backoffDelay(failures: failures, jitter: jitter())
        if case .rateLimited(let ra?) = error { delay = max(delay, min(ra, Self.maxDelay * 12)) }
        nextRetryDelay = delay
        return .failed(retryAfter: delay)
    }
}
