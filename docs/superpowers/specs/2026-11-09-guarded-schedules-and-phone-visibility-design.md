# Guarded schedules + phone visibility/copy: design

Date: 2026-11-09. Status: behavior approved by the user in conversation; reviewed by a builder; "Decisions after the builder review" are tether-dev-agent's calls pending the user's check. Not yet planned or built.
Sources: user conversation with tether-dev-agent (workstation), and the Mac/iOS agent's feasibility notes
of 2026-11-09 (relayed by the user). Normative engine semantics stay in `docs/ARCHITECTURE.md` §3.

Two features, one design: they share one contract change and one release.

## Why

The user runs Tether on their own iPhone, with a day-to-day "controller" Claude session (the
`personal-assistant` folder) driving it through the server's MCP tools.

- **Guarded schedules.** During the workday they occasionally need e.g. Instagram for a minute. Today they
  either pick a *flexible* schedule (pausable, but also editable/deletable/disable-able at any moment, so it
  doesn't hold) or a *strict* one (no pauses at all). They want a schedule that allows the existing pauses
  but can't be switched off while it's running, except with the partner PIN or the remote admin's approval
  (emergencies, holidays).
- **Phone visibility + copy.** The controller only sees what the server created. Groups and schedules the
  user makes in the app are invisible to it (local `lgrp_…` groups and local rules are never uploaded), so
  it can't reason about them or take them over. The user wants the controller to *see* everything set up in
  the app and to be able to *copy* a phone group/schedule into a server-owned one.

## Goals

- G1. New rule strictness level **`guarded`**: blocks like `flexible`, pauses allowed under the existing
  pause rules (budget, `maxPausesPerDay`), but while it is active it can't be disabled, edited or deleted,
  and its groups can't lose apps/sites, without passing the device's effective ProtectionLock.
- G2. The server, and so the MCP controller, sees a read-only snapshot of phone-made state: local groups
  (names, colors, typed web domains, **counts** of apps/categories/web tokens), local rules, sessions,
  pauses, and phone-side protection settings.
- G3. The controller can **copy** a phone group (and a phone schedule) into a server-owned one. The phone
  carries the app selection across by itself. The original stays on the phone.
- G4. MCP `add_schedule` can create flexible, guarded or strict schedules; `status` shows phone-made items.

## Non-goals

- No change to pause friction or limits (the user explicitly likes the current friction). No pause-length cap.
- No server control of phone-made items: the server never edits, pauses, deletes or blocks a local group/rule.
  Control happens only through a copy.
- No ongoing sync of a copy: a copy is a one-time snapshot; later phone edits to the original don't propagate.
- No new unlock-request kind (see "Holidays and emergencies").
- Not removing the original after a copy (user decision: it stays).

## Anti-goals (fail even if it technically works)

- Any app identity, bundle ID, app name or per-app usage leaving the device. Only **counts** of
  apps/categories/web tokens are uploaded (Apple rule + CLAUDE.md). Group names and domains the user typed
  are user text, not app identities, and are allowed.
- Biometrics anywhere (product rule: never `LocalAuthentication`).
- A guarded schedule that a user can switch off mid-window without PIN/approval through some side path
  (editing its group, editing its window, disabling the rule, deleting it, changing its strictness, deleting
  the group).
- The snapshot upload becoming a battery/network cost: it must be change-driven, not periodic.

## Constraints

- **Contract is frozen-by-default** (CLAUDE.md): one commit changes `contracts/*.schema.json`,
  `contracts/tools/gen_vectors.py` (regenerated `engine-vectors.json`), `Models.swift`/DTOs, and `server/src`,
  with all tests green (Python ref, Swift, TS).
- **Ownership split.** Mac/iOS agent: `contracts/`, `ios/`, and the iOS half. Workstation agent
  (tether-dev-agent): `server/` + MCP. Proposed mechanics: the Mac agent opens a feature branch with the
  contract + Models + iOS changes; tether-dev-agent adds the server commit on the same branch; the branch is
  squash-merged as one PR so main never has a half contract.
- All gates are app-enforced. The OS backstop is the Screen Time passcode (stops app deletion and revoking
  access). Clock/time-zone changes shift schedule evaluation; that's existing behavior, covered by spike S1.
- Server is tailnet-only; the phone may be offline. Snapshot freshness is best effort.

## A. Guarded schedules: decided behavior

**Strictness values:** `flexible` | `guarded` | `strict` (new middle value on `Rule.strictness`).

**Engine (ARCHITECTURE.md §3):** `guarded` is treated exactly like `flexible`: a candidate block is
**not strict**, so step 4 pauses apply, and `canPause` (pause budget D3) counts the same way. Tie-breaks that
say "strict first" treat guarded as non-strict. Add golden vectors showing guarded = flexible for blocking and
pausing. ShieldConfiguration text may label it (e.g. "Work · guarded"), builder's choice.

**When the guard applies (user decision):** only **while the rule is active**, i.e. its trigger is active
per §3 step 3 (schedule window active; manual mode on; usage limit hit today) and the rule is enabled. This
includes time when a pause or an allow override is currently letting things through: a pause is a break, not
the schedule being off. **Outside its active time the rule is fully editable** like a flexible one. The user
accepted that this leaves the "delete it at 8:59 before a 9:00 start" path open.

**Gated actions while active** (local guarded rules; server rules are read-only on the phone anyway):
- disable the rule, delete it, edit its trigger/windows/days, change its strictness or action, remove a group
  from it;
- remove apps/categories/web tokens/domains from any group it references, or delete such a group. Adding
  apps/sites stays allowed (same rule the Mac agent shipped for strict blocks on 2026-11-09, d1a7bad);
- turning protection off is already gated by ProtectionLock and unchanged.

**What the gate is:** the device's **effective ProtectionLock** (the stricter of local and server, existing
logic in `ProtectionController.effectiveLock`):
- `partnerPIN` → PIN prompt (existing PIN check, existing throttling/lockout) authorizes that one change.
- `remoteApproval` → the change is refused while active, with a message explaining the user can ask the admin
  for an unlock of the groups instead (see below), or change the schedule after hours.
- `osOnly` → refused while active; no in-app path.

**Holidays and emergencies:** use what exists: the phone sends an unlock request `kind=groups` (minutes up
to 1440) and the admin/controller approves it via `approve_unlock`. The approval is an unblock override, which
beats the guarded rule for that time. The schedule itself is untouched.

**Server-created schedules:** read-only on the phone, so for them `guarded` only means "pausable"
(server `guarded` ≡ `flexible` in effect). MCP `add_schedule` replaces `strict: boolean` with
`strictness: "flexible" | "guarded" | "strict"` (default `flexible`; keep accepting `strict: true` as an alias
for one release, builder's call). `status` prints the level.

## B. Phone visibility + copy: decided behavior

**Read-only snapshot (device → server).** New device-authenticated endpoint (proposed
`PUT /v1/devices/me/local`), an idempotent full snapshot:
```
{ hash, reportedAt,
  groups:   [{ id:"lgrp_…", name, colorHex, webDomains:[typed domains], counts:{ apps, categories, webTokens } }],
  rules:    [Rule with source:"local"],
  sessions: [{ id, name, groupIds, startsAt, endsAt, strict, endedAt }],   // active + upcoming + ended < 24 h
  pauses:   [{ id, groupId, startsAt, endsAt }],
  settings: { protectionEnabled, protectionLock } }
```
- Sent by the app, debounced, after any local mutation, and on sync whenever the hash changed. Not periodic.
  Extensions don't need to send it.
- The schema must make app identities impossible: counts only, no token blobs, `additionalProperties: false`.
- Server: stores the latest snapshot per device (JSON + hash + receivedAt), answers 204 when the hash is
  unchanged, caps the body (~256 KB). Snapshot is replaced, never merged.
- Surfaced read-only in `GET /v1/devices/:id` and in MCP `status` as a "phone-made" section (groups with
  counts, rules with windows/strictness, active sessions/pauses, protection settings, snapshot age). Reported
  `lgrp_` ids in acks are resolved to snapshot names (today status can only count them).
- Freshness target: within about a minute of a change while the phone is online (user accepted). Offline →
  next sync.

**Copy (server → device), user decision: the original stays.**
- New MCP tool, proposed `copy_from_phone { group | schedule, name? }`.
- Copying a group: the server creates a normal server group with new optional field
  `BlockGroup.copiedFrom: "lgrp_…"` and the snapshot's webDomains. On bundle apply, the phone copies that local
  group's app/category/web-token selection into the new server group **once**, if the server group has no
  selection yet. If the phone no longer has that `lgrp_`, it ignores `copiedFrom` and the group shows the usual
  "Choose apps for …".
- Copying a schedule: copy each referenced local group first (reusing an existing copy of the same `lgrp_` if
  one exists), then create a server rule with the same trigger/action/strictness pointing at the server group
  ids. The result is server-owned, so it is read-only on the phone (this doubles as a "lock this schedule" button).
- Both the original and the copy block the same apps, which is harmless. The controller tells the user they can
  delete the original on the phone if they don't want both.

## Decisions after the builder review (tether-dev-agent's calls; the user can overrule any)

1. **Emergency exit for phone-made guarded schedules.** This follows from the user's "only see, and copy"
   decision: the server can't unblock `lgrp_` groups, and unlock requests/`allow` stay server-group-only.
   So:
   - **Server-owned guarded schedule** (created via MCP, or copied from the phone): emergency/holiday =
     the user asks the controller, which uses `allow` (or `approve_unlock`) for the day.
   - **Phone-made guarded schedule:** during its hours the ways out are the partner PIN (if the effective lock
     is partnerPIN), waiting until after hours, or turning protection off (which already needs the lock).
     Under remoteApproval/osOnly, the refusal message should say this and suggest "ask your assistant to copy
     this schedule to the server" for future emergencies.
   - No phone UI for group unlock requests is built in this project.
2. **The gate is outcome-based, not a list of fields.** A local change is gated when (a) it touches a
   guarded rule that is active (any field: enabled, trigger, strictness, action, priority, maxPausesPerDay,
   groupIds, deletion), or (b) applying it would unblock any group that an active guarded rule is blocking
   right now. Check (b) by running the engine on before/after state at `now`. This catches new or edited
   higher-priority allow rules, priority changes, and group shrinking/deletion. Raising `maxPausesPerDay` on an
   active guarded rule is gated by (a). Adding apps/sites, or creating block rules, is never gated. `guarded`
   on an `allow`-action rule has no meaning: reject it in validation (schema: `guarded` only with
   `action: block`, or enforce in Models/server).
3. **Strict rules get at least the same gate.** Today a local strict rule is only locked while it is the active
   block reason; extend it to the guarded definition ("while active", plus the outcome check) so strict is
   never weaker than guarded.
4. **When protection is off, there is no gate** (the PIN is deleted on disable, and turning protection off is
   itself gated by the same lock).
5. **One phone for now.** `copy_from_phone` takes an optional `device` (defaults to the only device; error
   listing devices if there are several). `status` shows one phone-made section per device. A copied rule
   applies to all devices like any server rule; the selection carries over only on the source phone.
6. **Snapshot is display-only.** "server expects" keeps evaluating server policy only. The phone-made section is
   shown separately and is not fed into the server engine.
7. **Rollout gap is handled, not assumed away.** iOS decodes an unknown `strictness` as `flexible` and an
   unknown/absent `copiedFrom` as nothing, and ships first. The server sends `guarded` only to devices whose
   reported `appVersion` is at or above the first version that understands it (else `flexible`). The phone
   treats 404 on the snapshot endpoint as "server not updated yet": keep the snapshot and retry on a later sync.

## Contract changes (one commit)

- `policy-bundle.schema.json`: `Rule.strictness` enum gains `guarded`; `BlockGroup.copiedFrom` (optional,
  `lgrp_` id).
- New `contracts/device-local.schema.json` for the snapshot; `contracts/api.md` + `server/openapi.yaml` for the
  endpoint and for `GET /devices/:id` gaining the snapshot.
- `gen_vectors.py`: guarded vectors (blocking + pause + canPause identical to flexible); regenerate.
- `Models.swift`/DTOs; server zod schemas, migration (snapshot table/column), route, MCP.

## Left to the builders

- Exact endpoint/tool names, table layout, debounce interval, hash algorithm.
- UI copy and where the PIN prompt appears; how the app explains a refused change under remoteApproval/osOnly.
- How `status` lays out the phone-made section (keep it compact; the controller reads it every turn).
- Whether the shield says "guarded".
- Test strategy beyond: golden vectors for guarded, server route tests (hash/204/cap/privacy rejection), MCP
  tests for copy and status, iOS unit tests for the gate decision, and device tests in `TEST_PLAN_DEVICE.md`
  (gate during window vs. after hours; copy carries apps across; original untouched).
