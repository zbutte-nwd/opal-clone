// AppModel.swift — single observable model behind every screen.
// Every intent: mutate PersistedState via StateStore.update -> Reconciler (through
// PlatformServices) -> enqueue DeviceEvent -> trigger sync (ARCHITECTURE §1).

import Foundation
import Observation
import FamilyControls
import TetherCore
import TetherAPI

struct NextBlock: Equatable {
    var date: Date
    var groupIds: [GroupID]
}

struct BlockedItem: Identifiable {
    var group: BlockGroup
    var state: GroupState
    var subtitle: String
    var until: Date?
    var id: GroupID { group.id }
}

@MainActor @Observable
final class AppModel {
    let platform: PlatformServices

    // MARK: Observable state
    private(set) var state = PersistedState()
    private(set) var now = Date()
    private(set) var groupStates: [GroupID: GroupState] = [:]
    private(set) var untilByGroup: [GroupID: Date] = [:]
    private(set) var nextBlock: NextBlock?
    private(set) var lastSync: SyncSummary?
    private(set) var hasOnboarded: Bool
    private(set) var hardeningChecks: Set<String>
    private(set) var selectionRevision = 0
    var isSyncing = false
    var lastError: String?

    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private let defaults = UserDefaults.standard
    private enum Key {
        static let onboarded = "tether.ui.onboarded"
        static let hardening = "tether.ui.hardeningChecks"
        static let pushToken = "tether.ui.pushTokenHex"
    }

    init(platform: PlatformServices) {
        self.platform = platform
        self.hasOnboarded = UserDefaults.standard.bool(forKey: Key.onboarded)
        self.hardeningChecks = Set(UserDefaults.standard.stringArray(forKey: Key.hardening) ?? [])
        refresh()
    }

    /// Fully populated model for SwiftUI previews.
    static func preview(onboarded: Bool = true) -> AppModel {
        let m = AppModel(platform: StubPlatformServices.preview())
        m.hasOnboarded = onboarded
        return m
    }

    // MARK: Lifecycle

    func start() {
        refresh()
        startTicker()
    }

    func sceneBecameActive() {
        refresh()
        platform.reconcile(now: Date())
        refresh()
        startTicker()
        Task { await syncNow() }
    }

    func sceneEnteredBackground() {
        ticker?.cancel(); ticker = nil
    }

    func backgroundRefresh() async {
        _ = await platform.syncNow()
        platform.reconcile(now: Date())
        refresh()
    }

    func handlePush(userInfo: [AnyHashable: Any]) async {
        await platform.handlePush(userInfo: userInfo)
        platform.reconcile(now: Date())
        refresh()
    }

    func registerPushToken(hex: String) async {
        defaults.set(hex, forKey: Key.pushToken)
        await platform.registerPushToken(hex: hex)
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    private func tick() {
        now = Date()
        tickCount += 1
        let fresh = PolicyEngine.evaluate(input, at: now, timeZone: timeZone)
        // 1 s cadence while a session/pause is live, otherwise every 15 s is plenty.
        if fresh != groupStates { refresh() }
        else if tickCount % 15 == 0 { refresh() }
    }

    /// Reload from disk and recompute everything derived. Cheap enough to call freely.
    func refresh() {
        if let loaded = try? platform.stateStore.load() { state = loaded }
        now = Date()
        let input = state.engineInput
        let tz = PolicyEngine.effectiveTimeZone(input, deviceTimeZone: .current)
        let evaluated = PolicyEngine.evaluate(input, at: now, timeZone: tz)
        let transitions = TransitionPlanner.nextTransitions(input, after: now, timeZone: tz, horizon: 7 * 86400, limit: 16)
        groupStates = evaluated
        // `until` (next change per group) is filled in by TransitionPlanner.annotateUntil.
        let annotated = TransitionPlanner.annotateUntil(evaluated, input: input, now: now, timeZone: tz)
        untilByGroup = annotated.compactMapValues { $0.blocked ? $0.until : nil }

        nextBlock = nil
        for t in transitions {
            let st = PolicyEngine.evaluate(input, at: t, timeZone: tz)
            let newly = st.filter { $0.value.blocked && groupStates[$0.key]?.blocked != true }.map(\.key).sorted()
            if !newly.isEmpty { nextBlock = NextBlock(date: t, groupIds: newly); break }
        }
    }

    // MARK: Derived

    /// Read through to the platform (TetherKit's `AuthorizationManager` is `@Observable`), so views
    /// update as soon as iOS reports a change (e.g. revocation, or the launch-time status settling)
    /// instead of on the next `refresh()`.
    var screenTimeAuth: ScreenTimeAuth { platform.screenTimeAuth }

    var input: EngineInput { state.engineInput }
    var timeZone: TimeZone { PolicyEngine.effectiveTimeZone(input, deviceTimeZone: .current) }
    var allGroups: [BlockGroup] { input.allGroups }
    var allowLocalRules: Bool { state.bundle?.settings.allowLocalRules ?? true }
    var protectionLock: ProtectionLock { state.protection.lock }
    var isPaired: Bool { state.server != nil }

    func group(_ id: GroupID) -> BlockGroup? { allGroups.first { $0.id == id } }

    var allRules: [Rule] { (state.bundle?.rules ?? []) + state.localRules }

    var blockedItems: [BlockedItem] {
        allGroups.compactMap { g in
            guard var gs = groupStates[g.id], gs.blocked else { return nil }
            gs.until = untilByGroup[g.id]
            let copy = ShieldCopy.make(groupId: g.id, state: gs, input: input, now: now, timeZone: timeZone)
            return BlockedItem(group: g, state: gs, subtitle: copy.subtitle + (gs.strict ? " · strict" : ""), until: gs.until)
        }
    }

    var activeSession: FocusSession? {
        state.sessions
            .filter { $0.startsAt <= now && now < $0.endsAt && ($0.endedAt == nil || now < $0.endedAt!) }
            .min { $0.endsAt < $1.endsAt }
    }

    var stats: FocusStats { FocusStats.compute(state: state, now: now, timeZone: timeZone) }

    /// Server groups with no apps mapped on this device yet (SelectionStore) and no domains of their own.
    var unmappedServerGroups: [BlockGroup] {
        _ = selectionRevision
        return allGroups.filter { $0.source == .server && $0.webDomains.isEmpty && !platform.hasSelection(for: $0.id) }
    }

    enum ProtectionStatus { case protected, notProtected, authorizationRevoked, needsAuthorization }
    var protectionStatus: ProtectionStatus {
        switch screenTimeAuth {
        case .denied: return hasOnboarded ? .authorizationRevoked : .needsAuthorization
        case .notDetermined: return .needsAuthorization
        case .approved: return state.protection.enabled ? .protected : .notProtected
        }
    }

    func pauseEligibility(_ gid: GroupID) -> PauseEligibility {
        PolicyEngine.canPause(groupId: gid, input, at: now, timeZone: timeZone)
    }

    func selection(for gid: GroupID) -> FamilyActivitySelection { platform.selection(for: gid) }

    // MARK: Mutation plumbing

    @discardableResult
    private func mutate(sync: Bool = false, _ body: (inout PersistedState) throws -> Void) -> Bool {
        do {
            _ = try platform.stateStore.update { s in try body(&s) }
            platform.reconcile(now: Date())
            refresh()
            platform.localStateChanged()
            if sync { Task { await syncNow() } }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: Onboarding / authorization / protection

    func requestAuthorization(mode: AuthMode) async -> Bool {
        do {
            try await platform.requestAuthorization(mode: mode)
            mutate { $0.protection.authMode = mode }
            refresh()
            return screenTimeAuth == .approved
        } catch {
            refresh()
            lastError = error.localizedDescription
            return false
        }
    }

    func enableProtection(lock: ProtectionLock, pin: String?) -> Bool {
        do {
            try platform.enableProtection(lock: lock, pin: pin)
            refresh()
            Task { await syncNow() }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Returns nil on success or a user-facing error.
    func disableProtection(pin: String?) -> String? {
        do { try platform.disableProtection(pin: pin); refresh(); Task { await syncNow() }; return nil }
        catch { return error.localizedDescription }
    }

    func completeRemoteDisable(requestId: String) -> String? {
        do { try platform.disableProtectionAfterRemoteApproval(requestId: requestId); refresh(); Task { await syncNow() }; return nil }
        catch { return error.localizedDescription }
    }

    func changePIN(old: String, new: String) -> String? {
        do { try platform.changePIN(old: old, new: new); return nil }
        catch { return error.localizedDescription }
    }

    func completeOnboarding() {
        hasOnboarded = true
        defaults.set(true, forKey: Key.onboarded)
    }

    func resetOnboardingForDebug() {
        hasOnboarded = false
        defaults.set(false, forKey: Key.onboarded)
    }

    func setHardeningCheck(_ key: String, on: Bool) {
        if on { hardeningChecks.insert(key) } else { hardeningChecks.remove(key) }
        defaults.set(Array(hardeningChecks), forKey: Key.hardening)
    }

    // MARK: Guarded/strict schedule gate (TetherCore.ScheduleGuard)

    /// A change held until the partner PIN is entered because an active guarded/strict schedule is involved.
    struct PendingGuardedChange: Identifiable {
        let id = UUID()
        let reason: String
        let apply: () -> Void
    }
    var pendingGuardedChange: PendingGuardedChange?

    static let guardedHint = "For a holiday or emergency, ask your admin to unlock it, or ask your assistant to copy "
        + "this schedule to the server so it can be unlocked remotely."

    /// Runs `apply` now when allowed (or protection is off). Otherwise holds it for the PIN (partnerPIN, see
    /// `pendingGuardedChange`) or refuses with `lastError` (remoteApproval/osOnly). Returns whether it ran.
    private func gate(_ decision: GuardDecision, _ apply: @escaping () -> Void) -> Bool {
        guard case .locked(let reason) = decision, state.protection.enabled else { apply(); return true }
        if platform.effectiveProtectionLock == .partnerPIN {
            pendingGuardedChange = PendingGuardedChange(reason: reason, apply: apply)
        } else {
            lastError = reason + " " + Self.guardedHint
        }
        return false
    }

    /// The PIN for `pendingGuardedChange` (shared throttle with disable-protection). nil on success.
    func confirmGuardedChange(pin: String) -> String? {
        guard let p = pendingGuardedChange else { return nil }
        do { try platform.authorizeGuardedChange(pin: pin) } catch { return error.localizedDescription }
        pendingGuardedChange = nil
        p.apply()
        return nil
    }

    /// ScheduleGuard verdict for a change to local rules/groups, simulated on a copy of the state.
    private func ruleDecision(_ body: (inout PersistedState) throws -> Void) -> GuardDecision {
        var after = state
        guard (try? body(&after)) != nil else { return .allowed }   // the real mutation reports the error
        return ScheduleGuard.ruleChange(before: state.engineInput, after: after.engineInput, at: Date(), timeZone: timeZone)
    }

    /// A group may gain apps/sites but not lose any while an active guarded/strict schedule, a strict
    /// session or a server block covers it (pauses don't unlock it). `selection == nil` means deletion.
    private func shrinkDecision(_ gid: GroupID, selection: FamilyActivitySelection?, domains: [String]? = nil) -> GuardDecision {
        let now = Date()
        guard ScheduleGuard.isShrinkLocked(groupId: gid, input, at: now, timeZone: timeZone) else { return .allowed }
        if let selection {
            let old = platform.selection(for: gid)
            let lostSites = domains.map { d in !Set(group(gid)?.webDomains ?? []).isSubset(of: Set(d)) } ?? false
            guard lostSites
                || !old.applicationTokens.isSubset(of: selection.applicationTokens)
                || !old.categoryTokens.isSubset(of: selection.categoryTokens)
                || !old.webDomainTokens.isSubset(of: selection.webDomainTokens) else { return .allowed }
        }
        let name = ScheduleGuard.lockingRule(for: gid, input, at: now, timeZone: timeZone)?.name
        return .locked(reason: name.map { "“\($0)” is active, so its groups can't lose apps or sites until it ends." }
                       ?? "A strict block is active right now, so this group can't lose apps or sites until it ends.")
    }

    private func firstLocked(_ ds: GuardDecision...) -> GuardDecision {
        ds.first { if case .locked = $0 { return true } else { return false } } ?? .allowed
    }

    // MARK: Groups

    @discardableResult
    func setSelection(_ selection: FamilyActivitySelection, for gid: GroupID) -> Bool {
        gate(shrinkDecision(gid, selection: selection)) { [weak self] in self?.applySelection(selection, for: gid) }
    }

    private func applySelection(_ selection: FamilyActivitySelection, for gid: GroupID) {
        platform.setSelection(selection, for: gid)
        selectionRevision += 1
        platform.reconcile(now: Date())
        refresh()
        platform.localStateChanged()
    }

    @discardableResult
    func saveGroup(id: GroupID?, name: String, colorHex: String?, domains: [String], selection: FamilyActivitySelection) -> GroupID? {
        let gid = id ?? TetherID.make("lgrp")
        var saved: GroupID?
        let ran = gate(shrinkDecision(gid, selection: selection, domains: domains)) { [weak self] in
            guard let self else { return }
            let ok = self.mutate { s in
                if let i = s.localGroups.firstIndex(where: { $0.id == gid }) {
                    s.localGroups[i].name = name; s.localGroups[i].colorHex = colorHex; s.localGroups[i].webDomains = domains
                } else {
                    s.localGroups.append(BlockGroup(id: gid, name: name, colorHex: colorHex, webDomains: domains, source: .local))
                }
            }
            if ok { self.applySelection(selection, for: gid); saved = gid }
        }
        return ran ? saved : nil
    }

    @discardableResult
    func deleteGroup(_ gid: GroupID) -> Bool {
        let body: (inout PersistedState) -> Void = { s in
            s.localGroups.removeAll { $0.id == gid }
            for i in s.localRules.indices { s.localRules[i].groupIds.removeAll { $0 == gid } }
            s.localRules.removeAll { $0.groupIds.isEmpty }
        }
        return gate(firstLocked(shrinkDecision(gid, selection: nil), ruleDecision(body))) { [weak self] in
            guard let self else { return }
            self.mutate(body)
            self.platform.removeSelection(for: gid)
            self.selectionRevision += 1
        }
    }

    // MARK: Rules

    @discardableResult
    func saveRule(_ rule: Rule) -> Bool {
        guard allowLocalRules else { lastError = "Your admin has turned off local schedules on this device."; return false }
        if rule.strictness == .guarded && rule.action != .block { lastError = "Only block schedules can be guarded."; return false }
        let body: (inout PersistedState) -> Void = { s in
            if let i = s.localRules.firstIndex(where: { $0.id == rule.id }) { s.localRules[i] = rule }
            else { s.localRules.append(rule) }
        }
        return gate(ruleDecision(body)) { [weak self] in self?.mutate(body) }
    }

    @discardableResult
    func deleteRule(_ id: RuleID) -> Bool {
        let body: (inout PersistedState) -> Void = { $0.localRules.removeAll { $0.id == id } }
        return gate(ruleDecision(body)) { [weak self] in self?.mutate(body) }
    }

    @discardableResult
    func setRuleEnabled(_ id: RuleID, _ on: Bool) -> Bool {
        let body: (inout PersistedState) -> Void = { s in if let i = s.localRules.firstIndex(where: { $0.id == id }) { s.localRules[i].enabled = on } }
        return gate(ruleDecision(body)) { [weak self] in self?.mutate(body) }
    }

    // MARK: Sessions & pauses

    /// StateMutations enqueue the matching DeviceEvent themselves (sessionStarted / sessionEnded / pauseStarted).
    @discardableResult
    func startSession(name: String?, groupIds: [GroupID], minutes: Int, strict: Bool) -> Bool {
        guard !groupIds.isEmpty, minutes > 0 else { lastError = "Pick at least one group and a duration."; return false }
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        return mutate(sync: true) {
            $0.startSession(groupIds: groupIds, duration: TimeInterval(minutes) * 60, strict: strict,
                            name: (trimmed?.isEmpty ?? true) ? nil : trimmed)
        }
    }

    @discardableResult
    func endSession(_ id: String) -> Bool {
        if state.sessions.first(where: { $0.id == id })?.strict == true {
            lastError = "This is a Deep Focus session. It can't be ended early."
            return false
        }
        return mutate(sync: true) { try $0.endSession(id: id) }
    }

    @discardableResult
    func startPause(groupId: GroupID, minutes: Int) -> Bool {
        let tz = timeZone
        return mutate(sync: true) { try $0.startPause(groupId: groupId, minutes: minutes, timeZone: tz) }
    }

    // MARK: Server

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        let result = await platform.syncNow()
        isSyncing = false
        lastSync = result
        platform.reconcile(now: Date())
        refresh()
    }

    func pair(code: String, server: URL?) async -> Bool {
        do {
            try await platform.pair(code: code, serverURL: server)
            refresh()
            if let hex = defaults.string(forKey: Key.pushToken) { await platform.registerPushToken(hex: hex) }
            await syncNow()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func unpair() async {
        await platform.unpair()
        refresh()
    }

    func requestUnlock(kind: UnlockKind, groupIds: [GroupID], minutes: Int?, reason: String?) async -> String? {
        do { return try await platform.createUnlockRequest(kind: kind, groupIds: groupIds, minutes: minutes, reason: reason) }
        catch { lastError = error.localizedDescription; return nil }
    }

    func forceReconcile() {
        platform.reconcile(now: Date())
        refresh()
    }

    var prettyStateJSON: String {
        guard let data = try? TetherJSON.makeEncoder(pretty: true).encode(state) else { return "(unable to encode state)" }
        return String(decoding: data, as: UTF8.self)
    }
}
