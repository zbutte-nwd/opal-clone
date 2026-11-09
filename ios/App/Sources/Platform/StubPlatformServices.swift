// StubPlatformServices.swift — in-memory platform for previews and the Simulator.

import Foundation
import Observation
import FamilyControls
import TetherCore
import TetherAPI

@MainActor @Observable
final class StubPlatformServices: PlatformServices {
    let isStub = true
    @ObservationIgnored let stateStore: StateStore
    var screenTimeAuth: ScreenTimeAuth = .notDetermined
    var defaultServerURL: URL? { URL(string: "https://tether.example.com") }

    @ObservationIgnored private var selections: [GroupID: FamilyActivitySelection] = [:]
    @ObservationIgnored private var pin: String?
    @ObservationIgnored private var pollCount = 0

    init(seed: PersistedState? = nil, authorized: Bool = false) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-stub-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = StateStore(directory: dir)
        if let seed { _ = try? store.update { $0 = seed } }
        self.stateStore = store
        if authorized { screenTimeAuth = .approved }
    }

    /// Fully populated store for previews: groups, rules, an active session, a server bundle.
    static func preview(now: Date = Date()) -> StubPlatformServices {
        StubPlatformServices(seed: SampleData.state(now: now), authorized: true)
    }

    func requestAuthorization(mode: AuthMode) async throws {
        try? await Task.sleep(for: .milliseconds(400))
        screenTimeAuth = .approved
    }

    func selection(for groupId: GroupID) -> FamilyActivitySelection { selections[groupId] ?? FamilyActivitySelection() }
    func hasSelection(for groupId: GroupID) -> Bool {
        guard let s = selections[groupId] else { return false }
        return !(s.applicationTokens.isEmpty && s.categoryTokens.isEmpty && s.webDomainTokens.isEmpty)
    }
    func setSelection(_ selection: FamilyActivitySelection, for groupId: GroupID) { selections[groupId] = selection }
    func removeSelection(for groupId: GroupID) { selections[groupId] = nil }

    func reconcile(now: Date) {
        _ = try? stateStore.update { $0.lastReconciledAt = now }
    }

    func enableProtection(lock: ProtectionLock, pin: String?) throws {
        if lock == .partnerPIN {
            guard let pin, (6...8).contains(pin.count) else { throw PlatformError.invalidInput("PIN must be 6–8 digits.") }
            self.pin = pin
        }
        _ = try stateStore.update {
            $0.protection.enabled = true; $0.protection.lock = lock; $0.protection.enabledAt = Date()
            $0.pendingEvents.append(DeviceEvent(type: .protectionEnabled))
        }
    }

    func disableProtection(pin: String?) throws {
        let lock = (try? stateStore.load().protection.lock) ?? .partnerPIN
        switch lock {
        case .partnerPIN: guard let pin, pin == self.pin else { throw PlatformError.wrongPIN }
        case .remoteApproval: throw PlatformError.message("Requires admin approval.")
        case .osOnly: throw PlatformError.message("Disable it in iOS Settings → Screen Time.")
        }
        try finishDisable()
    }

    func disableProtectionAfterRemoteApproval(requestId: String) throws { try finishDisable() }

    func localStateChanged() {}

    var effectiveProtectionLock: ProtectionLock { (try? stateStore.load().protection.lock) ?? .partnerPIN }

    func authorizeGuardedChange(pin: String?) throws {
        guard (try? stateStore.load().protection.enabled) == true else { return }
        switch effectiveProtectionLock {
        case .partnerPIN: guard let pin, pin == self.pin else { throw PlatformError.wrongPIN }
        case .remoteApproval, .osOnly: throw PlatformError.message("This schedule is active, so it can't be changed until it ends.")
        }
    }

    private func finishDisable() throws {
        _ = try stateStore.update {
            $0.protection.enabled = false
            $0.pendingEvents.append(DeviceEvent(type: .protectionDisabled))
        }
    }

    func changePIN(old: String, new: String) throws {
        guard old == pin else { throw PlatformError.wrongPIN }
        guard (6...8).contains(new.count) else { throw PlatformError.invalidInput("PIN must be 6–8 digits.") }
        pin = new
    }

    func syncNow() async -> SyncSummary {
        try? await Task.sleep(for: .milliseconds(500))
        let now = Date()
        guard let st = try? stateStore.load(), st.server != nil else { return .notPaired }
        _ = try? stateStore.update { $0.lastSyncAt = now; $0.pendingEvents.removeAll() }
        return SyncSummary(ok: true, message: nil, at: now)
    }

    func handlePush(userInfo: [AnyHashable: Any]) async { _ = await syncNow() }

    func pair(code: String, serverURL: URL?) async throws {
        try await Task.sleep(for: .milliseconds(600))
        guard code.filter(\.isLetter).count + code.filter(\.isNumber).count >= 6 else {
            throw PlatformError.invalidInput("That pairing code looks too short.")
        }
        let url = serverURL ?? defaultServerURL ?? URL(string: "https://tether.example.com")!
        _ = try stateStore.update { $0.server = ServerConfig(baseURL: url, deviceId: "dev_stub12345") }
    }

    func unpair() async { _ = try? stateStore.update { $0.server = nil; $0.bundle = nil } }

    func createUnlockRequest(kind: UnlockKind, groupIds: [GroupID], minutes: Int?, reason: String?) async throws -> String {
        pollCount = 0
        return "req_stub"
    }

    func unlockRequestStatus(id: String) async throws -> UnlockStatus {
        pollCount += 1
        return pollCount >= 3 ? .approved : .pending
    }

    func registerPushToken(hex: String) async {}
}

// MARK: - Sample data for previews / simulator

enum SampleData {
    static func state(now: Date = Date()) -> PersistedState {
        var s = PersistedState()
        let games = BlockGroup(id: "grp_games", name: "Games", colorHex: "#7C5CFF", webDomains: ["twitch.tv"], source: .server)
        let social = BlockGroup(id: "lgrp_social", name: "Social", colorHex: "#FF6B6B", webDomains: ["x.com", "instagram.com"], source: .local)
        let news = BlockGroup(id: "lgrp_news", name: "News", colorHex: "#2EC4B6", webDomains: [], source: .local)
        s.localGroups = [social, news]
        s.localRules = [
            Rule(id: "lrule_work", name: "Work hours", groupIds: ["lgrp_social"],
                 trigger: .schedule(windows: [Window(days: [1, 2, 3, 4, 5], start: "09:00", end: "17:00")]),
                 maxPausesPerDay: 3),
            Rule(id: "lrule_bed", name: "Bedtime", groupIds: ["lgrp_news", "lgrp_social"],
                 trigger: .schedule(windows: [Window(days: [1, 2, 3, 4, 5, 6, 7], start: "22:00", end: "07:00")]),
                 strictness: .strict),
            Rule(id: "lrule_limit", name: "News limit", groupIds: ["lgrp_news"],
                 trigger: .usageLimit(dailyMinutes: 30, days: [1, 2, 3, 4, 5, 6, 7]))
        ]
        s.bundle = PolicyBundle(version: 3, generatedAt: now, groups: [games], rules: [
            Rule(id: "rule_games", name: "No games on school nights", groupIds: ["grp_games"],
                 trigger: .schedule(windows: [Window(days: [1, 2, 3, 4], start: "16:00", end: "20:00")]),
                 strictness: .strict, source: .server)
        ], settings: PolicySettings(protectionLock: .partnerPIN, allowLocalRules: true, denyAppRemoval: true))
        s.sessions = [FocusSession(id: "ses_demo", name: "Deep work", groupIds: ["lgrp_social"],
                                   startsAt: now.addingTimeInterval(-10 * 60), endsAt: now.addingTimeInterval(15 * 60), strict: false)]
        s.protection = ProtectionState(enabled: true, lock: .partnerPIN, authMode: .individual, enabledAt: now)
        s.server = ServerConfig(baseURL: URL(string: "https://tether.example.com")!, deviceId: "dev_demo12345")
        s.lastSyncAt = now.addingTimeInterval(-300)
        return s
    }
}
