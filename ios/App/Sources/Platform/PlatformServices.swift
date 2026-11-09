// PlatformServices.swift
// Everything platform-specific the UI needs, behind one protocol so the whole app is
// navigable in SwiftUI previews / the Simulator (StubPlatformServices) without
// FamilyControls, and so the unverified TetherKit/TetherAPI call sites live in ONE file
// (LivePlatformServices.swift).

import Foundation
import FamilyControls
import TetherCore
import TetherAPI   // UnlockKind, UnlockStatus (TetherAPI/DTOs.swift)

/// UI-level view of the Screen Time authorization status.
enum ScreenTimeAuth: Equatable, Sendable {
    case notDetermined
    case approved
    /// Denied or revoked (e.g. user switched Tether off in Settings → Screen Time).
    case denied
}

struct SyncSummary: Sendable, Equatable {
    var ok: Bool
    var message: String?
    var at: Date?
    static let notPaired = SyncSummary(ok: false, message: "Not paired with a server.", at: nil)
}

enum PlatformError: LocalizedError {
    case wrongPIN
    case notPaired
    case invalidInput(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .wrongPIN: return "That PIN is not correct."
        case .notPaired: return "This device is not paired with a server yet."
        case .invalidInput(let s), .message(let s): return s
        }
    }
}

@MainActor
protocol PlatformServices: AnyObject {
    /// True for the in-memory stub (Simulator / previews).
    var isStub: Bool { get }
    /// Shared App Group state store (the app mutates `PersistedState` through it).
    var stateStore: StateStore { get }

    // Authorization
    var screenTimeAuth: ScreenTimeAuth { get }
    func requestAuthorization(mode: AuthMode) async throws

    // Selections (device-local app/category/web tokens, keyed by group id)
    func selection(for groupId: GroupID) -> FamilyActivitySelection
    func hasSelection(for groupId: GroupID) -> Bool
    func setSelection(_ selection: FamilyActivitySelection, for groupId: GroupID)
    func removeSelection(for groupId: GroupID)

    // Reconcile (synchronous; applies shields + schedules monitors)
    func reconcile(now: Date)

    // Protection
    func enableProtection(lock: ProtectionLock, pin: String?) throws
    func disableProtection(pin: String?) throws
    func disableProtectionAfterRemoteApproval(requestId: String) throws
    func changePIN(old: String, new: String) throws

    // Server
    func syncNow() async -> SyncSummary
    func handlePush(userInfo: [AnyHashable: Any]) async
    func pair(code: String, serverURL: URL?) async throws
    func unpair() async
    func createUnlockRequest(kind: UnlockKind, groupIds: [GroupID], minutes: Int?, reason: String?) async throws -> String
    func unlockRequestStatus(id: String) async throws -> UnlockStatus
    func registerPushToken(hex: String) async
    /// Default server URL from Info.plist (`TetherDefaultServerURL`), if any.
    var defaultServerURL: URL? { get }
}
