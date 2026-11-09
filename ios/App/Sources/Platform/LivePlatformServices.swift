// LivePlatformServices.swift — the ONLY file that talks to TetherKit / TetherAPI directly.
// Signatures were reconciled against W2/W5 sources as of writing; remaining doubts carry `// VERIFY:`.

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
    private let authManager: AuthorizationManager        // @MainActor @Observable (TetherKit)
    private let protection = ProtectionController.shared
    private let sync = PlatformSync.shared

    init() {
        self.stateStore = StateStore(directory: AppGroup.containerURL)
        self.selections = SelectionStore.shared
        self.authManager = AuthorizationManager()
    }

    var defaultServerURL: URL? { AppGroup.defaultServerURL }

    // MARK: Authorization

    var screenTimeAuth: ScreenTimeAuth {
        switch authManager.status {
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
        _ = Reconciler.shared.reconcile(now: now)
    }

    // MARK: Protection

    func enableProtection(lock: ProtectionLock, pin: String?) throws {
        let mode = (try? stateStore.load().protection.authMode) ?? .individual
        try protection.enable(lock: lock, pin: pin, authMode: mode)
    }

    func disableProtection(pin: String?) throws { try protection.disable(pin: pin) }

    func disableProtectionAfterRemoteApproval(requestId: String) throws {
        try protection.disableAfterRemoteApproval(requestId: requestId)
    }

    func changePIN(old: String, new: String) throws { try protection.changePIN(old: old, new: new) }

    // MARK: Server

    private func deviceInfo() -> DeviceInfo {
        let d = UIDevice.current
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return DeviceInfo(name: d.name, model: d.model, osVersion: d.systemVersion, appVersion: version)
    }

    private func makeClient(baseURL: URL) -> APIClient {
        APIClient(baseURL: baseURL, tokenProvider: { Keychain.deviceToken }, appVersion: deviceInfo().appVersion)
    }

    private func requireClient() throws -> APIClient {
        guard let server = (try? stateStore.load())?.server else { throw PlatformError.notPaired }
        return makeClient(baseURL: server.baseURL)
    }

    func syncNow() async -> SyncSummary {
        guard sync.isPaired else { return .notPaired }
        return summarize(await sync.syncNow(reason: .manual))
    }

    func handlePush(userInfo: [AnyHashable: Any]) async {
        _ = await sync.handlePush(userInfo)
    }

    private func summarize(_ outcome: SyncOutcome) -> SyncSummary {
        let now = Date()
        switch outcome {
        case .noChange, .updated, .unlockDecided:
            return SyncSummary(ok: true, message: nil, at: now)
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
            throw PlatformError.invalidInput("Pairing codes have 8 letters or numbers, like K7Q2-M9XD.")
        }
        _ = try await sync.enroll(pairingCode: normalized, server: server, deviceInfo: deviceInfo())
    }

    func unpair() async {
        if let client = try? requireClient() { try? await client.unpair() }   // best effort
        Keychain.deviceToken = nil
        _ = try? stateStore.update { $0.server = nil }
        sync.reset()
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
