# Guarded Schedules + Phone Visibility/Copy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `guarded` rule strictness (pausable, but locked behind the ProtectionLock while active) and a
read-only device→server snapshot of phone-made state with a copy-to-server path.

**Architecture:** One contract change (bundle `strictness: guarded`, `BlockGroup.copiedFrom`, a new snapshot schema)
shipped on one feature branch. iOS: tolerant decoding + version bump, pure gate logic in TetherCore, wiring in
AppModel, a snapshot uploader in the sync path, a one-time selection carry-over on bundle apply. Server: version-gated
bundle output, a snapshot store + route, and MCP tools/status that read it. The engine semantics are unchanged:
guarded ≡ flexible.

**Tech Stack:** Swift 6 (TetherCore/TetherAPI/TetherKit, SwiftUI app), Node 22+ / TypeScript / Fastify / better-sqlite3 /
zod / vitest, Python 3 contract tools (ajv-style JSON Schema 2020-12).

**Spec:** `docs/superpowers/specs/2026-11-09-guarded-schedules-and-phone-visibility-design.md` (read it first;
"Decisions after the builder review" is normative for this plan). Background: `docs/superpowers/specs/2026-11-09-guarded-schedules-ios-review.md`.

## Ownership and branch

- Branch: `feature/guarded-and-visibility` off `claude/beautiful-wozniak-y76g65`, created by the **Mac/iOS agent**.
- **Mac/iOS agent** owns Tasks 1–6 (contracts/, ios/). **tether-dev-agent** (workstation) owns Tasks 7–10 (server/).
- Order: Task 1 first (it fixes the shapes). After that, Tasks 2–6 and 7–10 run in parallel on the same branch; pull
  before each task. Task 11 (device tests) comes last. The branch is squash-merged as **one PR** so main never has a
  half contract (CLAUDE.md: contract + vectors + Models + server in one commit).
- Agent comms: commits on the branch, recipient named in the commit message (user rule).
- tether-dev-agent runs server tests on Windows (Node 24; WSL has Node 20). Use `npm ci --ignore-scripts` in a
  separate worktree; never `npm ci` in the live `C:\Users\zakir\tether\server` while the server runs.

## Global Constraints

- Strictness values: `flexible` | `guarded` | `strict`. Engine: `guarded` behaves exactly like `flexible`.
- `guarded` is valid only with `action: "block"`.
- App version gate: the server sends `guarded` only to devices reporting appVersion ≥ **0.2.0** (numeric semver
  compare); others, and devices with no appVersion, get `flexible`. iOS `MARKETING_VERSION` becomes **0.2.0**.
- Snapshot: counts only (`apps`, `categories`, `webTokens`); never app tokens, names or bundle IDs.
  `additionalProperties: false` everywhere. Body cap **256 KB**. Hash over a canonical encoding **excluding `reportedAt`**.
- Snapshot sessions: active + upcoming + ended within the last **24 h**.
- Never import `LocalAuthentication`; all Apple-framework code stays inside `#if canImport(...)` so the package builds on Linux.
- Pause behavior and limits are unchanged (no pause-length cap).
- One PIN lockout counter shared by schedule gates and disable-protection.

## Review Focus

1. A change made **during a pause or a server `allow`** (e.g. adding a higher-priority allow rule) must still be gated.
   Test: Task 3 `testOutcomeGateIgnoresActivePause`, `testOutcomeGateIgnoresUnblockOverride`.
2. A **guarded window that crosses midnight** (22:00–02:00) must count as active at 01:00 on the next day.
   Test: Task 2 `testIsRuleActiveOvernightWindow`.
3. **Version strings** compare numerically: `0.10.0` ≥ `0.2.0`, `0.1.9` < `0.2.0`, missing/garbage → old.
   Test: Task 7 `appVersionAtLeast`.
4. The **same snapshot with a new `reportedAt`** is a no-op (204, no store write, no re-upload).
   Tests: Task 5 `testHashIgnoresReportedAt`, Task 8 `unchanged hash → 204`.
5. **Copying a schedule that mixes `grp_` and `lgrp_` groups**, or copying an `lgrp_` group twice: `grp_` is kept,
   an existing copy of the same `lgrp_` is reused, and nothing is duplicated.
   Test: Task 10 `copy_from_phone schedule reuses existing copies`.

---

### Task 1 (Mac/iOS): Contract: guarded, copiedFrom, snapshot schema, vectors

**Files:**
- Modify: `contracts/policy-bundle.schema.json` (`Rule.strictness`, `BlockGroup`)
- Create: `contracts/device-local.schema.json`
- Create: `contracts/fixtures/device-local.example.json`
- Modify: `contracts/tools/gen_vectors.py`, regenerate `contracts/engine-vectors.json`
- Modify: `contracts/tools/validate.py` (validate the new fixture against the new schema)
- Modify: `contracts/api.md` (new endpoint; `GET /devices/:id` gains `local`; `POST /groups` accepts `copiedFrom`)

**Interfaces:**
- Produces: `Rule.strictness` enum `["flexible","guarded","strict"]`, with an `if/then` so that `guarded` requires `action: "block"`.
  `BlockGroup.copiedFrom`: optional string matching `^lgrp_`. Snapshot schema, root object:
  `{ hash: string, reportedAt: date-time, groups: LocalGroup[], rules: Rule[], sessions: LocalSession[], pauses: LocalPause[], settings: { protectionEnabled: bool, protectionLock: enum } }`,
  where `LocalGroup = { id: ^lgrp_, name, colorHex?, webDomains: string[], counts: { apps: int≥0, categories: int≥0, webTokens: int≥0 } }`,
  `LocalSession = { id, name?, groupIds, startsAt, endsAt, strict, endedAt? }` and `LocalPause = { id, groupId, startsAt, endsAt }`.
  `Rule` is `$ref`'d from the bundle schema with `source: "local"`.
  Endpoint `PUT /v1/devices/me/local` (device auth): `204` (stored, or unchanged hash), `413` (over 256 KB), `422` (schema).

- [ ] **Step 1:** Add vectors to `gen_vectors.py`: `"guarded rule blocks like flexible"` (expect blocked, `strict:false`,
  reason rule) and `"guarded rule is pausable"` (pause inside the window → unblocked, reason pause), mirroring the existing
  `"strict rule marks strict"` and strict-pause vectors with `strictness="guarded"`.
- [ ] **Step 2:** Run `python3 contracts/tools/gen_vectors.py && python3 contracts/tools/ref_engine.py contracts/engine-vectors.json`.
  Expected: the new vectors pass with no `ref_engine.py` change (its checks compare `== "strict"`). If they fail, stop: the spec says guarded ≡ flexible.
- [ ] **Step 3:** Make the schema edits and the fixture above. Run `python3 contracts/tools/validate.py`. Expected: all valid.
  Add one negative check to `validate.py`: a rule with `strictness: "guarded"` and `action: "allow"` must FAIL validation,
  and a snapshot group with an extra key `appTokens` must FAIL.
- [ ] **Step 4:** Commit: `contract: guarded strictness, BlockGroup.copiedFrom, device-local snapshot (for: tether-dev-agent)`.
  This commit alone breaks nothing: no implementation emits the new values yet.

### Task 2 (Mac/iOS): Models + tolerant decoding + isRuleActive

**Files:**
- Modify: `ios/Packages/TetherCore/Sources/TetherCore/Models.swift:88` (`Strictness`), `BlockGroup`
- Modify: `ios/Packages/TetherCore/Sources/TetherCore/PolicyEngine.swift` (extract step 3 activity check)
- Modify: `ios/Config/Base.xcconfig:15` → `MARKETING_VERSION = 0.2.0`
- Test: `ios/Packages/TetherCore/Tests/TetherCoreTests/ModelsDecodeTests.swift`, `PolicyEngineTests.swift`, `EngineVectorTests.swift` (unchanged; must pass with the new vectors)

**Interfaces:**
- Produces: `public enum Strictness: String, Codable { case flexible, guarded, strict }` whose `init(from:)` maps unknown
  raw values to `.flexible`. `BlockGroup.copiedFrom: GroupID?` (absent/unknown → nil).
  `public static func isRuleActive(_ rule: Rule, _ input: EngineInput, at now: Date, timeZone: TimeZone) -> Bool` on `PolicyEngine`
  (true iff the rule is enabled, counts for this input (local rules ignored when `allowLocalRules == false`), and its trigger is active per §3 step 3).
  `evaluate` must call it, so there is no second copy of the logic.

- [ ] **Step 1:** Tests: `testUnknownStrictnessDecodesAsFlexible` (decode a bundle with `"strictness":"ultra"`, expect `.flexible` and the
  whole bundle decoded), `testGuardedRoundTrips`, `testCopiedFromOptional`, `testIsRuleActiveScheduleWindow`,
  `testIsRuleActiveOvernightWindow` (window 22:00–02:00 on Mon; Tue 01:00 local → true; Tue 03:00 → false),
  `testIsRuleActiveDisabledRule` (false), `testIsRuleActiveManualMode` (`active:true` → true).
- [ ] **Step 2:** `cd ios/Packages/TetherCore && swift test`. Expected: the new tests FAIL to compile or fail.
- [ ] **Step 3:** Implement. Bump `MARKETING_VERSION`.
- [ ] **Step 4:** `swift test`. Expected: all pass, including `EngineVectorTests` with the Task 1 vectors.
- [ ] **Step 5:** Commit: `iOS models: guarded + tolerant decoding, copiedFrom, isRuleActive; app 0.2.0`.

### Task 3 (Mac/iOS): ScheduleGuard (pure gate decisions)

**Files:**
- Create: `ios/Packages/TetherCore/Sources/TetherCore/ScheduleGuard.swift`
- Test: `ios/Packages/TetherCore/Tests/TetherCoreTests/ScheduleGuardTests.swift`

**Interfaces:**
- Consumes: `PolicyEngine.isRuleActive`, `PolicyEngine.evaluate` (Task 2).
- Produces:
  - `public enum GuardDecision: Equatable { case allowed; case locked(reason: String) }`
  - `public static func ruleChange(before: EngineInput, after: EngineInput, at: Date, timeZone: TimeZone) -> GuardDecision`.
    It returns `.locked` when (a) any rule that is guarded or strict and active in `before` differs in `after` in any field, or is missing from `after`, or
    (b) `evaluate` on `before` and on `after`, **both with active pauses and active unblock overrides removed**, shows some group
    blocked by an active guarded/strict rule in `before` that is not blocked in `after`.
  - `public static func isShrinkLocked(groupId: GroupID, _ input: EngineInput, at: Date, timeZone: TimeZone) -> Bool`.
    True iff g is referenced by an enabled **block** rule (local or server) with strictness ∈ {guarded, strict} that is active now, or g is
    covered now by a strict session or a block override.

- [ ] **Step 1:** Tests:
  - `testEditingActiveGuardedRuleIsLocked` (change its end time at 10:00 within 09:00–17:00 → `.locked`)
  - `testEditingGuardedRuleOutsideWindowIsAllowed` (same edit at 18:00 → `.allowed`)
  - `testNewHigherPriorityAllowRuleIsLocked`
  - `testAddingBlockRuleIsAllowed`
  - `testOutcomeGateIgnoresActivePause` (pause active at 10:00, add an allow rule → `.locked`)
  - `testOutcomeGateIgnoresUnblockOverride` (server unblock override active → still `.locked`)
  - `testRaisingMaxPausesOnActiveGuardedIsLocked`
  - `testFlexibleRulesNeverLocked`
  - `testShrinkLockedForActiveServerGuardedRule`
  - `testShrinkLockedDuringPause` (a pause doesn't unlock it)
  - `testShrinkNotLockedAfterHours`
  - `testShrinkLockedForBlockOverride`
- [ ] **Step 2:** `swift test --filter ScheduleGuardTests`. Expected: FAIL (missing type).
- [ ] **Step 3:** Implement `ScheduleGuard`. The pause/unblock stripping uses `input.pauses.filter { !active }`, and drops overrides with
  `action == .unblock` that are active at `now`.
- [ ] **Step 4:** `swift test`. Expected: all pass.
- [ ] **Step 5:** Commit: `TetherCore: ScheduleGuard for guarded/strict rules`.

### Task 4 (Mac/iOS): Wire the gate into the app (PIN / refusal) + guarded in the rule editor

**Files:**
- Modify: `ios/Packages/TetherCore/Sources/TetherKit/ProtectionController.swift` (public guard authorization)
- Modify: `ios/App/Sources/App/AppModel.swift:271-345` (`setSelection`, `wouldShrinkStrictGroup`, `saveGroup`, `deleteGroup`, `saveRule`, `deleteRule`, `setRuleEnabled`)
- Modify: `ios/App/Sources/Features/Rules/RuleEditorView.swift`, `RuleDraft.swift` (three-way strictness picker; guarded only for block rules)
- Test: `ios/Packages/TetherCore/Tests/...` only where logic is pure. AppModel wiring is verified in Task 11.

**Interfaces:**
- Consumes: `ScheduleGuard.ruleChange`, `ScheduleGuard.isShrinkLocked` (Task 3); `ProtectionController.effectiveLock`.
- Produces: `public func authorizeGuardedChange(pin: String?, now: Date = Date()) throws` on `ProtectionController`. It returns when
  protection is off, or when the lock is partnerPIN and the PIN verifies. It uses the **same** `verifyPINThrottled` counter. It throws
  `ProtectionError.remoteApprovalRequired` or `.notAllowedInApp(...)` for the other locks. AppModel builds before/after `EngineInput` for each mutation,
  asks `ScheduleGuard`, and on `.locked` either prompts for the PIN (partnerPIN) or shows the refusal.
  Copy for remoteApproval/osOnly (spec decision 1): "This schedule is active, so it can't be changed until it ends. For a holiday or
  emergency, ask your admin to unlock it, or ask your assistant to copy this schedule to the server so it can be unlocked remotely."
- [ ] **Step 1:** Replace the `groupStates[gid]?.strict` key in `wouldShrinkStrictGroup` with `ScheduleGuard.isShrinkLocked`. Route
  rule mutations through `ScheduleGuard.ruleChange`. Show the PIN sheet on `.locked` when the effective lock is partnerPIN.
- [ ] **Step 2:** Build for device; `cd ios/Packages/TetherCore && swift test` stays green; `make typecheck-ios-linux` passes on Linux if available.
- [ ] **Step 3:** Commit: `iOS: guard guarded/strict rules and their groups behind the ProtectionLock`.

### Task 5 (Mac/iOS): Snapshot builder + upload

**Files:**
- Create: `ios/Packages/TetherCore/Sources/TetherAPI/LocalSnapshot.swift` (DTO + canonical hash)
- Modify: `ios/Packages/TetherCore/Sources/TetherAPI/APIClient.swift` (`putLocalSnapshot`)
- Modify: `ios/Packages/TetherCore/Sources/TetherAPI/SyncEngine.swift` (upload when the hash changed)
- Create: `ios/Packages/TetherCore/Sources/TetherKit/SnapshotBuilder.swift` (`#if canImport(FamilyControls)`; counts from selections)
- Test: `ios/Packages/TetherCore/Tests/TetherAPITests/LocalSnapshotTests.swift`, `SyncEngineTests.swift`

**Interfaces:**
- Produces: `public struct LocalSnapshot: Codable` (matches `device-local.schema.json`). `public func contentHash() -> String` computes SHA-256 hex over
  sorted-keys JSON of everything except `hash` and `reportedAt`. `APIClient.putLocalSnapshot(_: LocalSnapshot) async throws -> SnapshotPutResult`, where
  `enum SnapshotPutResult { case stored, serverTooOld }` and 404/405 map to `.serverTooOld`.
  `SyncEngine` stores `lastUploadedSnapshotHash` and uploads (debounced ~2 s) after local mutations and on `syncNow`, only while paired.
  `SnapshotBuilder.build(state:selections:now:) -> LocalSnapshot` includes local groups (counts from each selection's token sets), local rules,
  sessions that are active, upcoming, or ended < 24 h before `now`, active/upcoming pauses, and `{protectionEnabled, protectionLock}` (the effective lock).
- [ ] **Step 1:** Tests: `testHashIgnoresReportedAt`, `testHashChangesWhenGroupRenamed`, `testEncodingHasNoTokenFields` (the encoded JSON keys ⊆ schema keys),
  `testServerTooOldKeepsSnapshotForRetry` (404 → hash not recorded → next sync retries), `testNoUploadWhenUnpaired`.
- [ ] **Step 2:** `swift test`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test`. Expected: pass.
- [ ] **Step 5:** Commit: `iOS: upload a read-only snapshot of phone-made state (for: tether-dev-agent)`.

### Task 6 (Mac/iOS): Copy carry-over on bundle apply

**Files:**
- Modify: `ios/Packages/TetherCore/Sources/TetherKit/SelectionStore.swift` (persist `appliedCopies: Set<GroupID>`)
- Modify: `ios/Packages/TetherCore/Sources/TetherKit/PlatformSync.swift` or `Reconciler.swift` (on bundle apply)
- Test: pure part in TetherCore if extractable (`CopyPlanner.copies(bundleGroups:, localGroupIds:, applied:) -> [(from: GroupID, to: GroupID)]`)

**Interfaces:**
- Produces: for each bundle group with `copiedFrom == lgrp_x` whose id ∉ `appliedCopies`: if `lgrp_x` exists locally, copy its selection to the server
  group and insert the id into `appliedCopies`. If `lgrp_x` is missing, do nothing (the group asks "Choose apps for …"). Never copy twice.
- [ ] **Step 1:** Tests for `CopyPlanner`: `testCopiesOnce`, `testMissingSourceIgnored`, `testClearedCopyNotRecopied` (id already applied).
- [ ] **Step 2:** `swift test`. Expected: FAIL. **Step 3:** Implement. **Step 4:** `swift test`. Expected: pass.
- [ ] **Step 5:** Commit: `iOS: carry a phone group's apps into its server copy once`.

### Task 7 (server): guarded in schemas, version-gated bundle, MCP add_schedule strictness

> **Added by Mac/iOS agent (found while installing 0.2.0):** `devices.app_version` is only written at enroll, so an
> already-paired phone stays `0.1.0` forever and would never get `guarded`. Every device request already carries
> `User-Agent: Tether-iOS/<version>` (APIClient). In `deviceAuth` (or the ack handler), parse that and update
> `app_version` when it differs. Test: enroll with appVersion 0.1.0, then GET /devices/me/policy with
> `User-Agent: Tether-iOS/0.2.0` → a guarded rule comes back as `guarded`. No contract change. The user's phone
> already runs 0.2.0 (installed 2026-11-09 04:15 PT).

**Files:**
- Modify: `server/src/engine/index.ts:12` (`strictness: 'flexible' | 'guarded' | 'strict'`)
- Modify: `server/src/policy/schemas.ts:43` (zod enum + refine: guarded requires `action === 'block'`)
- Modify: `server/src/policy/service.ts:54` (`buildBundle` takes `app_version`; downgrades guarded→flexible for old apps), `:79` (`buildBundleById` selects `app_version`)
- Modify: `server/src/util.ts` (version compare)
- Modify: `server/src/mcp.ts` (`add_schedule`: `strictness` enum, `strict: true` alias; status prints ` | guarded` / ` | strict`; instructions line)
- Test: `server/test/api.test.ts`, `server/test/mcp.test.ts`, `server/test/engine.test.ts` (vectors)

**Interfaces:**
- Produces: `export function appVersionAtLeast(v: string | null | undefined, min: string): boolean` in `util.ts`.
  `buildBundle(ctx, device: Pick<DeviceRow, 'id'|'admin_id'|'latest_version'|'app_version'>)`. `GUARDED_MIN_APP_VERSION = '0.2.0'`.
- [ ] **Step 1:** Tests:
  - `appVersionAtLeast` cases: (`'0.2.0','0.2.0'`)→true, (`'0.10.0','0.2.0'`)→true, (`'0.1.9','0.2.0'`)→false, (`null`)→false, (`'abc'`)→false.
  - api: `POST /v1/rules` with `strictness:'guarded', action:'allow'` → 422.
  - api: a guarded rule appears as `guarded` in `/devices/me/policy` for a device with appVersion `0.2.0`, and as `flexible` for `0.1.0`;
    both bundles validate against the schema.
  - mcp: `add_schedule {strictness:'guarded'}` → status contains `| guarded`; `{strict:true}` → `| strict`.
- [ ] **Step 2:** On Windows: `npx vitest run`. Expected: the new tests FAIL.
- [ ] **Step 3:** Implement. The engine needs only the type change (its comparisons are `=== 'strict'`).
- [ ] **Step 4:** `npm test && npx tsc --noEmit`. Expected: all pass, including the engine vectors from Task 1.
- [ ] **Step 5:** Commit: `server: guarded strictness, version-gated bundle, add_schedule strictness`.

### Task 8 (server): snapshot store + route

**Files:**
- Modify: `server/src/db.ts` (migration 3 `device_local`: `device_id TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE, hash TEXT NOT NULL, snapshot TEXT NOT NULL, received_at TEXT NOT NULL`)
- Modify: `server/src/routes/devices.ts` (`d.put('/devices/me/local')`; device delete paths remove the row)
- Modify: `server/src/policy/schemas.ts` (zod `LocalSnapshot` mirroring the contract, `.strict()` objects)
- Modify: `server/src/devices.ts` (`deviceSummary` gains `local: { receivedAt, snapshot } | null`)
- Modify: `server/openapi.yaml`
- Test: `server/test/api.test.ts` (validate the stored snapshot against `contracts/device-local.schema.json` via the ajv helper)

**Interfaces:**
- Produces: `GET /v1/devices/:id` → `local: { receivedAt: string, snapshot: LocalSnapshot } | null`. Route-level body limit 262144 bytes.
- [ ] **Step 1:** Tests:
  - `PUT /v1/devices/me/local` with the fixture → 204, and `GET /devices/:id` returns it.
  - Unchanged hash → 204 with `received_at` unchanged.
  - Extra key `appTokens` in a group → 422.
  - Body over 256 KB → 413.
  - Admin `DELETE /devices/:id`, and `DELETE /devices/me`, remove the snapshot.
  - Admin token (not a device token) on the PUT → 401.
- [ ] **Step 2:** `npx vitest run test/api.test.ts`. Expected: FAIL. **Step 3:** Implement. **Step 4:** `npm test`, `npm run openapi:check`. Expected: pass.
- [ ] **Step 5:** Commit: `server: store the phone's read-only snapshot (PUT /devices/me/local)`.

### Task 9 (server): MCP status: phone-made section + named local groups

**Files:**
- Modify: `server/src/mcp.ts` (`status`)
- Test: `server/test/mcp.test.ts`

**Interfaces:**
- Consumes: `deviceSummary(...).local` (Task 8).
- Produces: under each device, after "phone reports": `    phone-made (as of <time>): groups: Socials (3 apps, 1 category) id=lgrp_…; schedules: Work: block Socials | mon-fri 09:00-17:00 | guarded id=…; active: pause Socials until 10:05`.
  When there's no snapshot: `    phone-made: not reported yet (app 0.2.0+ needed)`. "phone reports" names `lgrp_` groups from the snapshot when known
  (falls back to counting them).
- [ ] **Step 1:** Tests: `status` after PUT of the fixture contains `phone-made (as of` and `Socials (3 apps, 1 category)`; after an ack with `lgrp_` id → `blocked … Socials`;
  with no snapshot → `not reported yet`.
- [ ] **Step 2:** FAIL → **Step 3:** implement (keep it compact: one line per section) → **Step 4:** `npm test` passes.
- [ ] **Step 5:** Commit: `MCP status: show phone-made groups, schedules and activity`.

### Task 10 (server): copy_from_phone + BlockGroup.copiedFrom

**Files:**
- Modify: `server/src/db.ts` (migration 4: `ALTER TABLE groups ADD COLUMN copied_from TEXT`)
- Modify: `server/src/policy/service.ts` (`groupOut` emits `copiedFrom` when set), `server/src/policy/schemas.ts`, `server/src/routes/policy.ts` (`POST /groups` accepts `copiedFrom` matching `^lgrp_`)
- Modify: `server/src/mcp.ts` (new tool `copy_from_phone`)
- Test: `server/test/mcp.test.ts`, `server/test/api.test.ts`

**Interfaces:**
- Consumes: the snapshot (Task 8).
- Produces: MCP tool `copy_from_phone { group?: string, schedule?: string, name?: string, device?: string }` (exactly one of group/schedule; refs by
  name or `lgrp_`/rule id within the snapshot; `device` defaults to the only device, and errors listing devices when there are several).
  - Group: creates a server group `{ name: name ?? original, webDomains, colorHex, copiedFrom }`. Reuses an existing server group with the same
    `copied_from` instead of creating a second one.
  - Schedule: copies each `lgrp_` group (reusing copies), keeps `grp_` ids, creates a server rule with the same trigger/action/strictness/priority/maxPausesPerDay.
  - Reply text says the original stays on the phone and the apps carry over the next time the phone syncs.
- [ ] **Step 1:** Tests:
  - group copy creates a group with `copiedFrom` in the device bundle.
  - Copying the same `lgrp_` twice → one server group.
  - `copy_from_phone schedule reuses existing copies` (schedule with one `grp_` and one already-copied `lgrp_` → the rule's groupIds are the `grp_` + the existing copy; no new groups).
  - Unknown name → error listing known phone-made names.
  - Missing snapshot → error "phone hasn't reported yet".
  - Copied guarded rule is sent as `flexible` to an app 0.1.0 device.
- [ ] **Step 2:** FAIL → **Step 3:** implement → **Step 4:** `npm test && npx tsc --noEmit` pass.
- [ ] **Step 5:** Commit: `MCP: copy_from_phone (group/schedule) with copiedFrom carry-over (for: Mac/iOS agent)`.

### Task 11 (Mac/iOS, with the user): device tests, then merge

**Files:**
- Modify: `docs/TEST_PLAN_DEVICE.md` (new run section)
- Modify: `docs/WORKSTATION.md` (tool list: `copy_from_phone`; `add_schedule` strictness), `server/README.md`

- [ ] **Step 1:** Install 0.2.0. Device checks, each recorded PASS/FAIL:
  - (1) guarded local schedule pauses as before;
  - (2) during its window, delete/disable/edit is PIN-gated (partnerPIN) or refused (remoteApproval), and after hours it's free;
  - (3) removing an app from a group of an active **server** guarded schedule is refused;
  - (4) status shows the phone-made section within ~1 minute of creating a group;
  - (5) `copy_from_phone` of a phone group → the server copy blocks the same apps without re-picking; the original is untouched;
  - (6) an app on 0.1.0 (if one is still around) keeps applying policy when the server has a guarded rule.
- [ ] **Step 2:** All tests green: `make test` on the Mac (contracts + Swift + server + admin).
- [ ] **Step 3:** Open one PR `feature/guarded-and-visibility` → `claude/beautiful-wozniak-y76g65`, squash-merge. tether-dev-agent deploys the
  server (stop → install → build → `-Restart`) after the phone has 0.2.0.
