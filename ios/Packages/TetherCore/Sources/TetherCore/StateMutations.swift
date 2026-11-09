// StateMutations.swift — pure, in-place state transitions used by the app and extensions.
//
// Call them inside `StateStore.update { state in … }` so the change is persisted atomically.
// Mutations that correspond to a server-visible event enqueue it themselves
// (sessionStarted / sessionEnded / pauseStarted / usageLimitReached), so callers must not
// enqueue those again.

import Foundation

public enum StateMutationError: Error, Equatable, Sendable {
    case sessionNotFound(String)
    /// A strict focus session cannot be ended before `endsAt`.
    case strictSessionActive(endsAt: Date)
    case invalidDuration
    case groupNotBlocked(GroupID)
    case strictBlock(GroupID)
    case pauseBudgetExhausted(limit: Int)
}

extension PersistedState {

    // MARK: Sessions

    /// Starts a focus session of `duration` seconds (clamped to ≥ 60 s) and queues `sessionStarted`.
    @discardableResult
    public mutating func startSession(groupIds: [GroupID], duration: TimeInterval, strict: Bool,
                                      name: String? = nil, now: Date = Date()) -> FocusSession {
        let session = FocusSession(id: TetherID.make("ses"), name: name, groupIds: groupIds, startsAt: now,
                                   endsAt: now.addingTimeInterval(max(duration, 60)), strict: strict)
        sessions.append(session)
        enqueue(event: DeviceEvent(type: .sessionStarted, occurredAt: now, data: [
            "sessionId": session.id,
            "groupIds": groupIds.joined(separator: ","),
            "minutes": String(Int((max(duration, 60) / 60).rounded())),
            "strict": strict ? "true" : "false",
        ]))
        return session
    }

    /// Ends a session early (`endedAt = now`). Strict sessions can only end once `endsAt` has
    /// passed. Ending an already-ended session is a no-op.
    public mutating func endSession(id: String, now: Date = Date()) throws {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { throw StateMutationError.sessionNotFound(id) }
        let s = sessions[i]
        if let ended = s.endedAt, ended <= now { return }
        if now >= s.endsAt { return }                       // already over; nothing to cut short
        if s.strict { throw StateMutationError.strictSessionActive(endsAt: s.endsAt) }
        sessions[i].endedAt = now
        enqueue(event: DeviceEvent(type: .sessionEnded, occurredAt: now, data: ["sessionId": id, "early": "true"]))
    }

    // MARK: Pauses

    /// Pauses `groupId` for `minutes`. Throws unless `PolicyEngine.canPause` is `.allowed`.
    /// `ruleId` is set to the blocking rule when the block's reason is a rule (budget accounting).
    @discardableResult
    public mutating func startPause(groupId: GroupID, minutes: Int, now: Date = Date(), timeZone: TimeZone) throws -> Pause {
        guard minutes > 0 else { throw StateMutationError.invalidDuration }
        let input = engineInput
        switch PolicyEngine.canPause(groupId: groupId, input, at: now, timeZone: timeZone) {
        case .notBlocked: throw StateMutationError.groupNotBlocked(groupId)
        case .strict: throw StateMutationError.strictBlock(groupId)
        case .budgetExhausted(let limit): throw StateMutationError.pauseBudgetExhausted(limit: limit)
        case .allowed: break
        }
        let reason = PolicyEngine.evaluate(input, at: now, timeZone: timeZone)[groupId]?.reason
        let ruleId = (reason?.kind == .rule) ? reason?.id : nil
        let pause = Pause(id: TetherID.make("pau"), groupIds: [groupId], startsAt: now,
                          endsAt: now.addingTimeInterval(Double(minutes) * 60), ruleId: ruleId)
        pauses.append(pause)
        var data = ["pauseId": pause.id, "groupId": groupId, "minutes": String(minutes)]
        if let ruleId = ruleId { data["ruleId"] = ruleId }
        enqueue(event: DeviceEvent(type: .pauseStarted, occurredAt: now, data: data))
        return pause
    }

    // MARK: Usage limits

    /// Records that `ruleId`'s daily limit was reached today (idempotent per day).
    /// Returns true if a new hit was recorded.
    @discardableResult
    public mutating func recordUsageLimitHit(ruleId: RuleID, now: Date = Date(), timeZone: TimeZone) -> Bool {
        let day = ScheduleMath.dayString(now, in: timeZone)
        if usageLimitHits.contains(where: { $0.ruleId == ruleId && $0.day == day }) { return false }
        usageLimitHits.append(UsageLimitHit(ruleId: ruleId, day: day))
        enqueue(event: DeviceEvent(type: .usageLimitReached, occurredAt: now, data: ["ruleId": ruleId, "day": day]))
        return true
    }

    // MARK: Events & bundle

    /// Queues an event for upload; the queue is capped at `maxPendingEvents` (oldest dropped).
    public mutating func enqueue(event: DeviceEvent) {
        pendingEvents.append(event)
        if pendingEvents.count > Self.maxPendingEvents {
            pendingEvents.removeFirst(pendingEvents.count - Self.maxPendingEvents)
        }
    }

    /// Installs a freshly fetched bundle. Returns false if it is identical to the current one.
    /// Does not touch `appliedBundleVersion` (the Reconciler sets that after applying shields).
    @discardableResult
    public mutating func applyBundle(_ newBundle: PolicyBundle) -> Bool {
        if bundle == newBundle { return false }
        bundle = newBundle
        return true
    }
}
