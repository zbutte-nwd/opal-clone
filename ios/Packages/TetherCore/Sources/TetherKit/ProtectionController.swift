#if os(iOS) && canImport(ManagedSettings)
import Foundation
import TetherCore

public enum ProtectionError: Error, Equatable, LocalizedError {
    case wrongPIN(attemptsLeft: Int)
    case lockedOut(until: Date)
    case pinRequired
    case pinInvalidFormat
    case pinNotSet
    /// In-app disable is not possible for this lock mode; `instructions` tells the user what to do.
    case notAllowedInApp(instructions: String)
    /// Lock is `remoteApproval`: create a `disableProtection` unlock request instead.
    case remoteApprovalRequired
    case notEnabled
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .wrongPIN(let left): return "Incorrect PIN. \(left) attempt\(left == 1 ? "" : "s") left."
        case .lockedOut(let until):
            let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
            return "Too many attempts. Try again at \(f.string(from: until))."
        case .pinRequired: return "Enter the Tether PIN."
        case .pinInvalidFormat: return "The PIN must be 6 to 8 digits."
        case .pinNotSet: return "No Tether PIN has been set."
        case .notAllowedInApp(let text): return text
        case .remoteApprovalRequired: return "Ask your administrator to approve disabling protection."
        case .notEnabled: return "Protection is not enabled."
        case .storage(let m): return "Could not save protection settings: \(m)"
        }
    }
}

/// Persisted PIN attempt throttle (survives relaunch): 5 failures -> 15 minute lockout.
struct PINAttemptState: Codable, Equatable {
    var failures: Int = 0
    var lockedUntil: Date?
}

/// Enabling/disabling protection. Disabling is gated by the `ProtectionLock` (no biometrics,
/// ever): `partnerPIN` (PINHasher), `remoteApproval` (server-approved request), `osOnly`
/// (not possible in-app — Screen Time passcode in iOS Settings).
public final class ProtectionController: @unchecked Sendable {
    public static let shared = ProtectionController()
    public static let maxFailures = 5
    public static let lockoutSeconds: TimeInterval = 15 * 60

    private let directoryOverride: URL?
    private let mutex = NSLock()

    public init(directory: URL? = nil) { self.directoryOverride = directory }

    private var directory: URL { directoryOverride ?? AppGroup.containerURL }
    private var store: StateStore { StateStore(directory: directory) }
    private var attemptsURL: URL { directory.appendingPathComponent("pinAttempts.json") }

    // MARK: Status

    public var isEnabled: Bool { (try? store.load().protection.enabled) ?? false }

    /// The lock stored locally when protection was enabled.
    public var lock: ProtectionLock { (try? store.load().protection.lock) ?? .partnerPIN }

    /// The lock that actually applies: the stricter of the local choice and the server's
    /// `settings.protectionLock` (the server may force `remoteApproval`/`osOnly`).
    public var effectiveLock: ProtectionLock {
        guard let s = try? store.load() else { return .partnerPIN }
        return Self.effectiveLock(s)
    }

    public var hasPIN: Bool { Keychain.loadPINRecord() != nil }

    /// When the PIN lockout ends, if currently locked out.
    public func lockoutEnd(now: Date = Date()) -> Date? {
        if let until = loadAttempts().lockedUntil, until > now { return until }
        return nil
    }

    static func strictness(_ l: ProtectionLock) -> Int {
        switch l { case .partnerPIN: return 0; case .remoteApproval: return 1; case .osOnly: return 2 }
    }

    static func effectiveLock(_ s: PersistedState) -> ProtectionLock {
        let local = s.protection.lock
        guard let server = s.bundle?.settings.protectionLock else { return local }
        return strictness(server) > strictness(local) ? server : local
    }

    public static let osOnlyInstructions =
        "This device is set to OS-only protection. To turn Tether off, open Settings, then Screen Time, "
        + "and revoke Tether's access (this needs the Screen Time passcode)."

    // MARK: Enable

    /// Turns protection on. For `partnerPIN` a 6–8 digit `pin` is required unless one is
    /// already stored. Writes `state.protection`, queues `protectionEnabled`, reconciles.
    public func enable(lock requested: ProtectionLock, pin: String?, authMode: AuthMode = .individual,
                       now: Date = Date()) throws {
        mutex.lock(); defer { mutex.unlock() }
        let current = try loadState()
        var probe = current; probe.protection.lock = requested
        let effective = Self.effectiveLock(probe)

        if effective == .partnerPIN {
            if let pin {
                guard Self.isValidPIN(pin) else { throw ProtectionError.pinInvalidFormat }
                do { try Keychain.savePINRecord(PINHasher.makeRecord(pin: pin)) }
                catch { throw ProtectionError.storage("keychain: \(error)") }
                resetAttempts()
            } else if Keychain.loadPINRecord() == nil {
                throw ProtectionError.pinRequired
            }
        } else {
            Keychain.deletePINRecord()
        }

        do {
            _ = try store.update { s in
                s.protection.enabled = true
                s.protection.lock = effective
                s.protection.authMode = authMode
                s.protection.enabledAt = s.protection.enabledAt ?? now
                s.enqueue(event: DeviceEvent(type: .protectionEnabled, occurredAt: now,
                                                   data: ["lock": effective.rawValue, "authMode": authMode.rawValue]))
            }
        } catch { throw ProtectionError.storage(String(describing: error)) }
        Reconciler.shared.reconcile(now: now)
    }

    // MARK: Disable

    /// Disables protection after verifying the partner PIN. Throws for other lock modes.
    public func disable(pin: String?, now: Date = Date()) throws {
        mutex.lock(); defer { mutex.unlock() }
        let s = try loadState()
        guard s.protection.enabled else { throw ProtectionError.notEnabled }
        switch Self.effectiveLock(s) {
        case .osOnly: throw ProtectionError.notAllowedInApp(instructions: Self.osOnlyInstructions)
        case .remoteApproval: throw ProtectionError.remoteApprovalRequired
        case .partnerPIN:
            try verifyPINThrottled(pin, now: now)
            try performDisable(method: "pin", extra: [:], now: now)
        }
    }

    /// Disables protection for `remoteApproval` mode. The CALLER must already have verified
    /// that unlock request `requestId` is `approved` (APIClient.getUnlockRequest).
    public func disableAfterRemoteApproval(requestId: String, now: Date = Date()) throws {
        mutex.lock(); defer { mutex.unlock() }
        let s = try loadState()
        guard s.protection.enabled else { throw ProtectionError.notEnabled }
        guard Self.effectiveLock(s) == .remoteApproval else {
            throw ProtectionError.notAllowedInApp(instructions:
                Self.effectiveLock(s) == .osOnly ? Self.osOnlyInstructions : "Remote approval is not enabled for this device.")
        }
        try performDisable(method: "remoteApproval", extra: ["requestId": requestId], now: now)
    }

    // MARK: PIN management

    public func changePIN(old: String, new: String, now: Date = Date()) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard Keychain.loadPINRecord() != nil else { throw ProtectionError.pinNotSet }
        guard Self.isValidPIN(new) else { throw ProtectionError.pinInvalidFormat }
        try verifyPINThrottled(old, now: now)
        do { try Keychain.savePINRecord(PINHasher.makeRecord(pin: new)) }
        catch { throw ProtectionError.storage("keychain: \(error)") }
    }

    /// Verifies a PIN with throttling but changes nothing (e.g. gate for loosening a rule).
    public func verifyPIN(_ pin: String?, now: Date = Date()) throws {
        mutex.lock(); defer { mutex.unlock() }
        try verifyPINThrottled(pin, now: now)
    }

    public static func isValidPIN(_ pin: String) -> Bool {
        PINHasher.isValidPIN(pin)
    }

    // MARK: Private

    private func loadState() throws -> PersistedState {
        do { return try store.load() } catch { throw ProtectionError.storage(String(describing: error)) }
    }

    private func performDisable(method: String, extra: [String: String], now: Date) throws {
        do {
            _ = try store.update { s in
                s.protection.enabled = false
                s.protection.enabledAt = nil
                var data = extra; data["method"] = method
                s.enqueue(event: DeviceEvent(type: .protectionDisabled, occurredAt: now, data: data))
            }
        } catch { throw ProtectionError.storage(String(describing: error)) }
        // Clear immediately (do not rely on the reconcile alone), then reconcile to stop schedules.
        ShieldApplier().clearAll()
        TamperLock().clearAll()
        Keychain.deletePINRecord()
        resetAttempts()
        Reconciler.shared.reconcile(now: now)
    }

    /// Must be called with `lock` held.
    private func verifyPINThrottled(_ pin: String?, now: Date) throws {
        var a = loadAttempts()
        if let until = a.lockedUntil, until > now { throw ProtectionError.lockedOut(until: until) }
        if a.lockedUntil != nil { a.lockedUntil = nil; a.failures = 0 }   // lockout expired
        guard let pin, !pin.isEmpty else { throw ProtectionError.pinRequired }
        guard let record = Keychain.loadPINRecord() else { throw ProtectionError.pinNotSet }
        if PINHasher.verify(pin: pin, record: record) {
            resetAttempts()
            return
        }
        a.failures += 1
        if a.failures >= Self.maxFailures {
            let until = now.addingTimeInterval(Self.lockoutSeconds)
            a.lockedUntil = until
            saveAttempts(a)
            throw ProtectionError.lockedOut(until: until)
        }
        saveAttempts(a)
        throw ProtectionError.wrongPIN(attemptsLeft: Self.maxFailures - a.failures)
    }

    private func loadAttempts() -> PINAttemptState {
        guard let d = try? Data(contentsOf: attemptsURL),
              let a = try? TetherJSON.makeDecoder().decode(PINAttemptState.self, from: d) else { return PINAttemptState() }
        return a
    }

    private func saveAttempts(_ a: PINAttemptState) {
        do { try TetherJSON.makeEncoder().encode(a).write(to: attemptsURL, options: [.atomic]) }
        catch { TLog.protection.error("pin attempts save failed: \(String(describing: error))") }
    }

    private func resetAttempts() { saveAttempts(PINAttemptState()) }
}
#endif
