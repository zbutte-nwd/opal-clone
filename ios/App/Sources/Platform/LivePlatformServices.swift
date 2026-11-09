// LivePlatformServices.swift — the ONLY file that talks to TetherKit / TetherAPI directly.
// Every call whose signature I could not confirm carries a `// VERIFY:` comment.

import Foundation
import UIKit
import FamilyControls
import TetherCore
import TetherAPI
import TetherKit

@MainActor
final class LivePlatformServices: PlatformServices {
    let isStub = false
    let stateStore: StateStore

    private let selections: SelectionStore
    // VERIFY: AuthorizationManager / ProtectionController initialisers (W5). Assumed `.shared`-less plain inits.
    private let authManager: AuthorizationManager
    private let protection: ProtectionController
    private var syncEngine: SyncEngine?
    private var syncEngineKey: String?

    init() {
        self.stateStore = StateStore(directory: AppGroup.containerURL)
        self.selections = SelectionStore.shared
        self.authManager = AuthorizationManager()      // VERIFY: init signature / singleton
        self.protection = ProtectionController()        // VERIFY: init signature / singleton
    }

    var defaultServerURL: URL? { AppGroup.defaultServerURL }

    // MARK: Authorization

    var screenTimeAuth: ScreenTimeAuth {
        // VERIFY: AuthorizationManager.status's type. Reading the system center directly is the
        // well-known API and gives the same answer.
        switch AuthorizationCenter.shared.authorizationStatus {
        case .approved: return .approved
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    func requestAuthorization(mode: AuthMode) async throws {
        switch mode {
        case .individual: try await authManager.requestIndividual()
        case .child: try await authManager.requestChild()
        }
    }

    // MARK: Selections

    func selection(for groupId: GroupID) -> FamilyActivitySelection { selections.selection(for: groupId) ?? FamilyActivitySelection() }
    func hasSelection(for groupId: GroupID) -> Bool { selections.selection(for: groupId)?.hasTokens ?? false }
    func setSelection(_ selection: FamilyActivitySelection, for groupId: GroupID) { selections.set(selection, for: groupId) }
    func removeSelection(for groupId: GroupID) { selections.remove(groupId) }

    // MARK: Reconcile

    func reconcile(now: Date) {
        _ = Reconciler.shared.reconcile(now: now)   // VERIFY: Reconciler.reconcile(now:) -> ReconcileResult (discardable?)
    }

    // MARK: Protection

    func enableProtection(lock: ProtectionLock, pin: String?) throws {
        try protection.enable(lock: lock, pin: pin)   // VERIFY: signature `enable(lock:pin:) throws`
    }

    func disableProtection(pin: String?) throws {
        try protection.disable(pin: pin)              // VERIFY: signature `disable(pin:) throws`
    }

    func disableProtectionAfterRemoteApproval(requestId: String) throws {
        try protection.disableAfterRemoteApproval(requestId: requestId)   // VERIFY
    }

    func changePIN(old: String, new: String) throws {
        try protection.changePIN(old: old, new: new)  // VERIFY: label names
    }

    // MARK: Server

    private func deviceInfo() -> DeviceInfo {
        let d = UIDevice.current
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return DeviceInfo(name: d.name, model: d.model, osVersion: d.systemVersion, appVersion: version)
    }

    private func makeClient(baseURL: URL) -> APIClient {
        APIClient(baseURL: baseURL, tokenProvider: { Keychain.deviceToken },
                  appVersion: deviceInfo().appVersion)
    }

    /// Builds (and caches per base URL) a SyncEngine for the paired server. nil = not paired.
    private func engine() -> SyncEngine? {
        guard let server = (try? stateStore.load())?.server else { return nil }
        let key = server.baseURL.absoluteString
        if let e = syncEngine, syncEngineKey == key { return e }
        // VERIFY: StateStore conforms to StateStoring (W2 says StateStore+StateStoring.swift provides it).
        let e = SyncEngine(api: makeClient(baseURL: server.baseURL), store: stateStore,
                           authorizationStatusProvider: { [weak self] in
                               await MainActor.run {
                                   switch self?.screenTimeAuth ?? .notDetermined {
                                   case .approved: return .approved
                                   case .denied: return .denied
                                   case .notDetermined: return .notDetermined
                                   }
                               }
                           },
                           onBundleChanged: { [weak self] in
                               await MainActor.run { self?.reconcile(now: Date()) }
                           })
        syncEngine = e; syncEngineKey = key
        return e
    }

    func syncNow() async -> SyncSummary {
        guard let engine = engine() else { return .notPaired }
        let outcome = await engine.syncNow(reason: .manual)
        return summarize(outcome)
    }

    func handlePush(userInfo: [AnyHashable: Any]) async {
        guard let engine = engine() else { return }
        _ = await engine.handlePush(userInfo)
    }

    private func summarize(_ outcome: SyncOutcome) -> SyncSummary {
        let now = Date()
        switch outcome {
        case .noChange, .updated, .unlockDecided: return SyncSummary(ok: true, message: nil, at: now)
        case .unauthorized:
            return SyncSummary(ok: false, message: "The server no longer recognises this device. Pair again.", at: nil)
        case .failed:
            return SyncSummary(ok: false, message: "Couldn't reach the server. Will retry.", at: nil)
        }
    }

    func pair(code: String, serverURL: URL?) async throws {
        guard let server = serverURL ?? defaultServerURL else {
            throw PlatformError.invalidInput("Enter the server address.")
        }
        guard let normalized = PairingLink.normalizeCode(code) else {
            throw PlatformError.invalidInput("Pairing codes have 8 letters/numbers, like K7Q2-M9XD.")
        }
        let tmp = SyncEngine(api: makeClient(baseURL: server), store: stateStore, onBundleChanged: {})
        let token = try await tmp.enroll(pairingCode: normalized, server: server, deviceInfo: deviceInfo())
        Keychain.deviceToken = token
        syncEngine = nil; syncEngineKey = nil
    }

    func unpair() async {
        if let server = (try? stateStore.load())?.server {
            try? await makeClient(baseURL: server.baseURL).unpair()   // best effort
        }
        Keychain.deviceToken = nil
        _ = try? stateStore.update { $0.server = nil }
        syncEngine = nil; syncEngineKey = nil
    }

    private func requireClient() throws -> APIClient {
        guard let server = (try? stateStore.load())?.server else { throw PlatformError.notPaired }
        return makeClient(baseURL: server.baseURL)
    }

    func createUnlockRequest(kind: UnlockKind, groupIds: [GroupID], minutes: Int?, reason: String?) async throws -> String {
        let r = try await requireClient().createUnlockRequest(
            CreateUnlockRequest(kind: kind, groupIds: groupIds.isEmpty ? nil : groupIds, minutes: minutes, reason: reason))
        return r.id
    }

    func unlockRequestStatus(id: String) async throws -> UnlockStatus {
        try await requireClient().getUnlockRequest(id: id).status
    }

    func registerPushToken(hex: String) async {
        guard let client = try? requireClient() else { return }
        #if DEBUG
        let env = PushEnvironment.sandbox
        #else
        let env = PushEnvironment.production   // VERIFY: TestFlight/App Store use production; dev-signed builds use sandbox.
        #endif
        try? await client.updatePushToken(PushTokenRequest(token: hex, environment: env))
    }
}
