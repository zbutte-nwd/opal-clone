#if os(iOS) && canImport(ManagedSettings)
import Foundation
import Combine
import Observation
import FamilyControls
import TetherCore
import TetherAPI

/// Mirrors `AuthorizationCenter.shared.authorizationStatus` for SwiftUI and queues a
/// `authorizationChanged` DeviceEvent whenever the status differs from the last one seen
/// (so a revocation that happened while the app was not running is still reported).
/// There is deliberately no `revoke` API: only iOS Settings (Screen Time passcode) can.
@MainActor
@Observable
public final class AuthorizationManager {
    public private(set) var status: AuthorizationStatus
    public private(set) var lastError: String?

    @ObservationIgnored private var cancellable: AnyCancellable?
    private static let lastSeenKey = "tether.lastAuthorizationStatus"

    public init() {
        self.status = AuthorizationCenter.shared.authorizationStatus
        // VERIFY: `AuthorizationCenter` is an ObservableObject exposing `$authorizationStatus`.
        self.cancellable = AuthorizationCenter.shared.$authorizationStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newStatus in
                Task { @MainActor [weak self] in self?.statusChanged(to: newStatus) }
            }
        recordIfChanged(status)
    }

    public var isApproved: Bool { status == .approved }

    /// The string form used by the ack payload and events.
    public var statusValue: AuthorizationStatusValue { Self.value(for: status) }

    /// Asks for `.individual` authorization (system prompt; Apple ID / device auth).
    public func requestIndividual() async throws {
        try await request(.individual)
    }

    /// Asks for `.child` authorization (Family Sharing child; guardian approves).
    public func requestChild() async throws {
        try await request(.child)
    }

    private func request(_ member: FamilyControlsMember) async throws {
        do {
            lastError = nil
            try await AuthorizationCenter.shared.requestAuthorization(for: member)
            statusChanged(to: AuthorizationCenter.shared.authorizationStatus)
        } catch {
            lastError = error.localizedDescription
            TLog.auth.error("requestAuthorization failed: \(String(describing: error))")
            statusChanged(to: AuthorizationCenter.shared.authorizationStatus)
            throw error
        }
    }

    private func statusChanged(to new: AuthorizationStatus) {
        if status != new { status = new }
        recordIfChanged(new)
    }

    private func recordIfChanged(_ s: AuthorizationStatus) {
        Self.recordIfChanged(Self.value(for: s))
    }

    // MARK: Non-isolated helpers (usable from extensions / SyncEngine providers)

    public nonisolated static func currentStatusValue() -> AuthorizationStatusValue {
        value(for: AuthorizationCenter.shared.authorizationStatus)
    }

    nonisolated static func value(for s: AuthorizationStatus) -> AuthorizationStatusValue {
        switch s {
        case .approved: return .approved
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// Queues an `authorizationChanged` event if the status differs from the last one stored.
    public nonisolated static func recordIfChanged(_ new: AuthorizationStatusValue, now: Date = Date()) {
        let defaults = AppGroup.defaults
        let previous = defaults.string(forKey: lastSeenKey)
        guard previous != new.rawValue else { return }
        defaults.set(new.rawValue, forKey: lastSeenKey)
        guard let previous else { return }   // first launch: nothing to report yet
        do {
            _ = try StateStore(directory: AppGroup.containerURL).update { s in
                s.enqueue(event: DeviceEvent(type: .authorizationChanged, occurredAt: now,
                                             data: ["status": new.rawValue, "previous": previous]))
            }
        } catch {
            TLog.auth.error("enqueue authorizationChanged failed: \(String(describing: error))")
        }
    }
}
#endif
