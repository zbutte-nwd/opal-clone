# Architecture

```
┌──────────────────────── iPhone ─────────────────────────────────────────────┐
│                                                                             │
│  Tether.app (SwiftUI)          Extensions (each its own process)            │
│  ├─ UI (W6)                    ├─ TetherMonitor   DeviceActivityMonitor     │
│  ├─ AppModel                   ├─ TetherShieldConfig  ShieldConfiguration   │
│  └─ links TetherKit ───┐       ├─ TetherShieldAction  ShieldActionDelegate  │
│                        │       ├─ TetherReport    DeviceActivityReport      │
│                        ▼       └─ TetherPush      NotificationService (NSE) │
│        ┌─────────── TetherCore Swift package ───────────┐                   │
│        │ TetherCore  (pure Swift, Linux-testable)       │◀── all targets    │
│        │   models · PolicyEngine · TransitionPlanner    │                   │
│        │   StateStore (App Group JSON) · PIN hashing    │                   │
│        │ TetherAPI   (Foundation only, Linux-testable)  │                   │
│        │   APIClient · SyncEngine · PushPayload         │                   │
│        │ TetherKit   (Apple frameworks, iOS only)       │                   │
│        │   ShieldApplier · ActivityScheduler ·          │                   │
│        │   AuthorizationManager · SelectionStore ·      │                   │
│        │   Reconciler (the one function everyone calls) │                   │
│        └────────────────────────────────────────────────┘                   │
│                 App Group container: state.json, selections.json            │
└───────────────────────────────▲─────────────────────────────────────────────┘
                                │ HTTPS (bearer device token)   ▲ APNs
┌───────────────────────────────┴───────────────────────────────┴─────────────┐
│ server/ (W3)  Node 22 + TypeScript + Fastify + SQLite                       │
│   REST /v1 · pairing · policy versioning · APNs sender · TS engine port     │
│ admin/ (W4)   React + Vite dashboard talking to /v1                         │
└─────────────────────────────────────────────────────────────────────────────┘
```

Shared, language-neutral contract lives in `contracts/`:

- `contracts/policy-bundle.schema.json` — JSON Schema for the server→device policy.
- `contracts/engine-input.schema.json` — the full engine input (bundle + local state).
- `contracts/engine-vectors.json` — **golden test vectors**. Swift `TetherCore` tests and
  the server TS tests both load this file and must produce identical results. Changing
  semantics = change vectors first.
- `contracts/api.md` — REST endpoints. (W3 generates `server/openapi.yaml` from it.)
- `contracts/fixtures/*.json` — example payloads both sides decode in tests.
- `contracts/tools/gen_vectors.py` generates the vectors; `contracts/tools/ref_engine.py`
  is a ~80-line Python reference evaluator (`python3 contracts/tools/ref_engine.py contracts/engine-vectors.json`).

## 1. Core principle: reconcile, don't mutate

Nothing ever "adds a block" or "removes a block" imperatively. Every trigger — app
launch, schedule boundary, usage threshold, push, pause tap, session start — does:

1. Update **inputs** in `state.json` (new bundle, new session, new pause…).
2. Call `Reconciler.reconcile(now:)`:
   - `PolicyEngine.evaluate(input, at: now)` → `[GroupID: GroupState]`
   - `ShieldApplier.apply(states)` writes ManagedSettings stores (idempotent).
   - `TransitionPlanner.nextTransitions(input, after: now)` →
     `ActivityScheduler.schedule(transitions)` registers DeviceActivity schedules so the
     Monitor extension wakes at the next boundary.
3. Persist `lastReconciledAt`, applied bundle version; enqueue ack to server.

This makes every process (app, Monitor, NSE, ShieldAction) safe to run the same code and
makes the outcome a pure function of state + time → testable on Linux.

## 2. Data model (canonical; JSON field names are camelCase)

```swift
typealias GroupID = String   // "grp_…" server, "lgrp_…" local
typealias RuleID  = String

struct BlockGroup { id, name, colorHex?, webDomains: [String], source: .server/.local }
//  App/category/web *tokens* are NOT here — they live in SelectionStore keyed by GroupID.

struct Rule {
  id, name, groupIds: [GroupID], enabled: Bool,
  action: .block | .allow,
  trigger: Trigger,
  strictness: .flexible | .strict,      // strict = no pauses
  priority: Int = 0,                     // higher wins between rules
  maxPausesPerDay: Int?,                 // nil = unlimited (flexible only)
  source: .server | .local
}

enum Trigger {
  case schedule(windows: [Window])       // {days:[1..7 ISO Mon=1], start:"HH:mm", end:"HH:mm"}
  case usageLimit(dailyMinutes: Int, days: [Int])
  case manual(active: Bool)              // server/admin toggle
}

struct Override  { id, groupIds, action: .block|.unblock, startsAt, endsAt?, issuedAt, reason? }   // server only
struct FocusSession { id, name?, groupIds, startsAt, endsAt, strict: Bool, endedAt? }            // local
struct Pause     { id, groupIds, startsAt, endsAt, ruleId? }                                       // local
struct UsageLimitHit { ruleId, day: "YYYY-MM-DD" }                                                 // local, set by Monitor

struct PolicyBundle {           // server → device, versioned
  version: Int, generatedAt, timeZone: String?,  // nil = device local tz
  groups: [BlockGroup], rules: [Rule], overrides: [Override],
  settings: { protectionLock: .partnerPIN|.remoteApproval|.osOnly,
              allowLocalRules: Bool, denyAppRemoval: Bool }
}

struct EngineInput { bundle: PolicyBundle?, localGroups, localRules, sessions, pauses, usageLimitHits }

struct GroupState {
  groupId, blocked: Bool,
  reason: Reason,          // {kind: override|session|rule|pause|none, id: String?}
  strict: Bool,            // true → no pause button on shield
  until: Date?             // next time this group's state may change (best effort)
}
```

### Window semantics
- `days` ISO weekday (1 = Monday … 7 = Sunday) on which the window **starts**.
- `start`/`end` are `"HH:mm"` local wall-clock in the bundle `timeZone` (or device tz).
  `end` may be `"24:00"`. If `end < start` the window runs overnight into the next day.
  `end == start` is invalid → treated as never active (and rejected by server validation).
- Active iff `start ≤ t < end` (half-open).
- DST: evaluate wall-clock times via `Calendar`; a nonexistent start time rounds forward.

## 3. Resolution semantics (normative — mirrored in `engine-vectors.json`)

For each known group `g` at time `t`:

1. **Server overrides.** Among overrides containing `g` with `startsAt ≤ t < (endsAt ?? ∞)`,
   take the one with the latest `issuedAt` (tie: `id` lexicographically larger).
   - `block` → `blocked=true, strict=true, reason=override`.
   - `unblock` → `blocked=false, reason=override`. **Overrides are supreme** — they beat
     sessions, rules and pauses.
2. **Focus sessions.** Any session containing `g` with `startsAt ≤ t < endsAt` and
   `endedAt == nil` (or `t < endedAt`) → candidate block, `strict = any(session.strict)`,
   `reason=session(id)`: the strict session with smallest id, else the earliest-ending
   session (tie: smallest id).
3. **Rules** (server + local, enabled only; local rules ignored if
   `bundle.settings.allowLocalRules == false`). A rule is *active* at `t` when:
   - `schedule`: any window active;
   - `usageLimit`: today (in tz) ∈ `days` and a `UsageLimitHit(ruleId, today)` exists;
   - `manual`: `active == true`.
   Among active rules containing `g`, take max `priority`; within that priority **block
   beats allow**. Ties among the winning block rules: strict first, then smallest `id`;
   among allow rules: smallest `id`. If the winner is `allow` and no session applies → `blocked=false,
   reason=rule(id)`. If the winner is `block` → candidate block, `strict` if the rule is
   strict, `reason=rule(id)`. A session candidate (step 2) beats an allow rule; if both a
   session and a block rule apply, `reason` is the session, `strict = session.strict ||
   rule.strict`.
4. **Pauses.** If there is a candidate block, it is **not strict**, and an active pause
   (`startsAt ≤ t < endsAt`) contains `g` → `blocked=false, reason=pause(id)` (latest
   `endsAt` wins; tie: smallest id).
5. Otherwise `blocked=false, reason=none`.

Groups referenced by rules but unknown (no `BlockGroup`) are ignored. `until` is
computed by the TransitionPlanner and is not part of the vectors.

### Pause budget (D3)
`PolicyEngine.canPause(groupId, input, at:)` → `.allowed | .strict | .budgetExhausted`.
Counts pauses today (tz) whose `ruleId` matches the rule currently causing the block.

## 4. Persistence (`state.json` in the App Group)

```jsonc
{
  "schemaVersion": 1,
  "bundle": { /* PolicyBundle or null */ },
  "localGroups": [], "localRules": [], "sessions": [], "pauses": [], "usageLimitHits": [],
  "appliedBundleVersion": 41, "lastReconciledAt": "…",
  "pendingEvents": [ /* DeviceEvent queued for upload */ ],
  "protection": { "enabled": true, "lock": "partnerPIN", "authMode": "individual" },
  "server": { "baseURL": "https://…", "deviceId": "dev_…" }   // token is in Keychain
}
```
- `StateStore` (TetherCore) reads/writes atomically (write temp + rename) and uses
  `NSFileCoordinator` when available. Pruning: drop sessions/pauses ended > 7 days ago,
  limit hits > 2 days old.
- `selections.json` (TetherKit): `[GroupID: FamilyActivitySelection]` (Codable).
- PIN: `PINHasher` (TetherCore) PBKDF2-HMAC-SHA256, 200k iterations, 16-byte salt;
  hash stored in Keychain (TetherKit), never in state.json.

## 5. Scheduling strategy (TransitionPlanner + ActivityScheduler)

`TransitionPlanner.nextTransitions(input, after: now, horizon: 7 days, limit: 16)` returns
sorted `Date`s where *any* group's state may change: window starts/ends, session ends,
pause ends, override starts/ends, local midnight (usage-limit reset). It evaluates the
engine at candidate times and keeps only real changes.

`ActivityScheduler` (TetherKit) maps them onto DeviceActivity:
- Activity names `tether.t.<n>` for one-shot transitions: interval `[transition, transition+15min]`
  (`intervalDidStart` is the wake-up; we don't rely on `intervalDidEnd`).
- Activity `tether.daily` repeating 00:00–23:59 to wake at midnight & re-plan.
- Activity `tether.usage.<ruleId>` with `DeviceActivityEvent`s for usage-limit rules.
- Total ≤ 20 activities; stop all `tether.t.*` and re-register on every reconcile.
- Monitor extension: every callback → `Reconciler.reconcile(now: Date())`.

## 6. ManagedSettings stores

| Store name | Contents |
|---|---|
| `tether.block` | Union of tokens of all blocked groups: `shield.applications`, `shield.applicationCategories (.specific)`, `shield.webDomains`, `shield.webDomainCategories`; plus `webContent.blockedByFilter = .specific(domains)` from `BlockGroup.webDomains` |
| `tether.tamper` | `application.denyAppRemoval = true` while protection enabled |

The shield extension needs to know *which* rule/session blocked a token to render
"School hours · until 3:00 PM". `Reconciler` writes `shieldContext.json`
(`[tokenHash: {groupName, reasonTitle, until, strict}]`) — the ShieldConfiguration
extension looks the token up (token is `Hashable`/`Codable`; key = base64 of encoded token).

## 7. Sync protocol (device ⇄ server)

1. **Enroll**: `POST /v1/devices/enroll {pairingCode, name, model, osVersion, appVersion}` →
   `{deviceId, deviceToken, baseURL}`. Token → Keychain (shared access group).
2. **Push token**: `PUT /v1/devices/me/push-token {token, environment: "sandbox"|"production"}`.
3. **Fetch**: `GET /v1/devices/me/policy` with `If-None-Match: "<version>"` → `200 PolicyBundle`
   or `304`.
4. **Apply** → reconcile → **Ack**: `POST /v1/devices/me/ack {version, appliedAt, blockedGroupIds, authorizationStatus}`.
5. **Events**: `POST /v1/devices/me/events {events:[{id, type, occurredAt, data}]}`
   types: `authorizationChanged`, `protectionDisabled`, `protectionEnabled`, `sessionStarted`,
   `sessionEnded`, `pauseStarted`, `usageLimitReached`, `heartbeat`.
6. **Unlock request**: `POST /v1/devices/me/unlock-requests {kind, groupIds, minutes, reason}`;
   `groups` approval creates an `unblock` override with `endsAt` → bundle version bump → push.
   `disableProtection` approval (Protection Lock `remoteApproval`) is polled/pushed back and
   the device disables protection locally.

Push payload (both alert-NSE and silent):
```json
{ "aps": { "alert": {"title": "Tether", "body": "Your focus settings were updated"},
           "mutable-content": 1, "sound": null },
  "tether": { "type": "policyUpdated", "version": 42, "bundle": { /* optional inline if < 3 KB */ } } }
```
NSE: parse → if inline bundle use it else fetch (NSE has ~30 s) → reconcile → ack →
rewrite notification text (e.g. "Social is now blocked until 3:00 PM").
Silent variant: `{"aps":{"content-available":1}, "tether":{…}}` → app delegate does the same.

Backoff: SyncEngine retries with exponential backoff (1 s → 5 min cap, jitter); heartbeat
every app foreground and every Monitor wake (rate-limited to 1 / 15 min).

## 8. Module public interfaces (agents implement exactly these names)

```swift
// TetherCore
public enum PolicyEngine {
  public static func evaluate(_ input: EngineInput, at now: Date, timeZone: TimeZone) -> [GroupID: GroupState]
  public static func canPause(groupId: GroupID, _ input: EngineInput, at now: Date, timeZone: TimeZone) -> PauseEligibility
  public static func effectiveTimeZone(_ input: EngineInput, deviceTimeZone: TimeZone) -> TimeZone
}
public enum TransitionPlanner {
  public static func nextTransitions(_ input: EngineInput, after now: Date, timeZone: TimeZone,
                                     horizon: TimeInterval = 7*86400, limit: Int = 16) -> [Date]
}
public final class StateStore: @unchecked Sendable {
  public init(directory: URL)                       // App Group container URL
  public func load() throws -> PersistedState
  public func update(_ body: (inout PersistedState) throws -> Void) throws -> PersistedState
}
public struct PersistedState: Codable, Sendable { … as §4 …; public var engineInput: EngineInput { get } }
public enum PINHasher { static func hash(pin:salt:iterations:) -> Data; static func verify(pin:record:) -> Bool }
public enum ScheduleMath { /* window activity, next boundary, ISO weekday helpers */ }

// TetherAPI
public struct APIClient { public init(baseURL: URL, tokenProvider: @Sendable () -> String?, session: URLSession = .shared)
  func enroll(_:) async throws -> EnrollResponse; func fetchPolicy(ifNoneMatch: Int?) async throws -> PolicyFetchResult
  func ack(_:) async throws; func postEvents(_:) async throws; func updatePushToken(_:) async throws
  func createUnlockRequest(_:) async throws -> UnlockRequest }
public actor SyncEngine { public init(api: APIClient, store: StateStore, onBundleChanged: @Sendable () async -> Void)
  public func syncNow(reason: SyncReason) async -> SyncOutcome
  public func handlePush(_ userInfo: [AnyHashable: Any]) async -> SyncOutcome }
public struct PushPayload: Decodable { type, version, bundle: PolicyBundle? ; static func parse(_ userInfo:) -> PushPayload? }

// TetherKit (iOS only, all files wrapped in #if canImport(ManagedSettings))
public final class Reconciler { public static let shared: Reconciler
  public func reconcile(now: Date = Date()) -> ReconcileResult }        // sync, safe in extensions
public final class ShieldApplier { func apply(_ states: [GroupID: GroupState], groups: [BlockGroup], selections: [GroupID: FamilyActivitySelection]); func clearAll() }
public final class ActivityScheduler { func schedule(transitions: [Date], usageRules: [Rule], selections: …) }
@MainActor @Observable public final class AuthorizationManager { var status; func requestIndividual() async throws; func requestChild() async throws }
public final class SelectionStore { func selection(for: GroupID) -> FamilyActivitySelection?; func set(_:for:) }
public final class ProtectionController { func enable(lock:) ; func disable(pin: String?) throws; var isEnabled: Bool }
public enum AppGroup { public static let identifier: String; public static var containerURL: URL }
```

## 9. Server (W3) outline

- Node 22, TypeScript (strict), Fastify, Zod, better-sqlite3, vitest, `pino` logging.
- Tables: `admins`, `devices`, `pairing_codes`, `groups`, `rules`, `overrides`,
  `device_policy` (per-device version), `events`, `unlock_requests`, `audit_log`, `api_keys`.
- Policy model: groups/rules/overrides belong to an admin account and are assigned to
  devices (P0: all of an account's devices get the same bundle; P1: device groups).
  Any change → bump version for affected devices → enqueue APNs push.
- `src/engine/` — TS port of §3 passing `contracts/engine-vectors.json`; used for the
  dashboard's "currently blocked" column and for validation.
- APNs: HTTP/2 + ES256 JWT provider token (`APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`,
  `APNS_TOPIC`, `APNS_ENV`); mock transport in tests / when unset.
- Device auth: opaque random token, stored as SHA-256 hash. Admin auth: argon2/scrypt
  password hash + HTTP-only session cookie or bearer JWT. API keys for automation (E9).
