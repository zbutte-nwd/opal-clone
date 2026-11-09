# Feature Map — "Tether" (working name)

An iOS focus / screen-time app in the same space as Opal: block apps and websites by
schedule, by usage, on demand, **and remotely from a server**, protected by the
**Screen Time passcode** instead of Face ID. Constraints that shape every feature are in
[`PLATFORM_CONSTRAINTS.md`](PLATFORM_CONSTRAINTS.md).

Priority: **P0** = MVP (first TestFlight), **P1** = v1.0, **P2** = later.
Owner column = workstream in [`BUILD_PLAN.md`](BUILD_PLAN.md).

## A. Setup & protection

| ID | Feature | Pri | Owner | Notes |
|---|---|---|---|---|
| A1 | Onboarding flow: explain → request Screen Time authorization → pick first group | P0 | W6 app | `.individual` by default |
| A2 | Family Sharing (`.child`) authorization option | P1 | W6/W5 | Guardian approves on their device |
| A3 | **Protection Lock** setup: `partnerPIN` / `remoteApproval` / `osOnly` | P0 | W6/W5 | No biometrics anywhere |
| A4 | Screen Time passcode hardening guide (step-by-step: set passcode, Account Changes: Don't Allow, Passcode Changes: Don't Allow) with "I've done this" checklist | P0 | W6 | Deep-link to Settings where possible |
| A5 | Tamper-lock: `denyAppRemoval` while protection is on | P0 | W5 | Separate named store `tamper` |
| A6 | Tamper detection: authorization revoked / device silent → report & alert admin | P0 | W5/W3 | Server marks device `stale` after N hours |
| A7 | "Disable protection" flow gated by Protection Lock | P0 | W6 | Clears all stores, reports to server |

## B. Blocking primitives

| ID | Feature | Pri | Owner | Notes |
|---|---|---|---|---|
| B1 | **Groups**: named sets of apps + categories + websites, picked with `FamilyActivityPicker` | P0 | W6/W5 | Local or server-defined (server groups need local mapping) |
| B2 | Server-pushed website domains on a group (`webContent.blockedByFilter`) | P0 | W5 | ≤ 50 domains |
| B3 | Custom shield screen (branding, rule name, "until 3:00 PM", motivational line) | P0 | W5 | ShieldConfiguration extension |
| B4 | Shield actions: "Close" / "Unlock for N min" (→ notification → pause flow) | P1 | W5/W6 | |
| B5 | Allow-list rules (exempt a group during a broader block, e.g. "Maps always allowed") | P1 | W1 | `action: allow` + priority |
| B6 | Block *all apps except* allow-list (`shield.applicationCategories = .all(except:)`) | P2 | W5 | "Deep work" mode |

## C. Triggers (what turns a block on)

| ID | Feature | Pri | Owner | Notes |
|---|---|---|---|---|
| C1 | **Schedules**: weekly windows (days + start/end, overnight supported) | P0 | W1/W5 | Rolling DeviceActivity scheduling |
| C2 | **Focus session (now)**: block groups for N minutes, starts immediately | P0 | W1/W6 | |
| C3 | **Strict/"Deep Focus" session**: cannot end early or pause | P0 | W1/W6 | |
| C4 | **Usage limit**: block group after N minutes/day of use | P1 | W1/W5 | `DeviceActivityEvent` threshold |
| C5 | **Server manual toggle** (rule with `manual` trigger, e.g. "Homework mode") | P0 | W1/W3 | |
| C6 | **Server override**: block/unblock group(s) now, optional end time | P0 | W1/W3 | Expiry enforced offline |
| C7 | Server-scheduled rules (admin edits schedule in dashboard) | P0 | W3/W4 | Same schedule type as C1 |
| C8 | Open-limit trigger (block after N opens/day) | P2 | — | No direct API; approximate via shield action counter |
| C9 | Location / Wi-Fi triggers | P2 | — | Needs background location; App Review risk |
| C10 | Calendar-based triggers (block during "Focus" events) | P2 | — | EventKit → generate schedule windows |

## D. Friction & exceptions

| ID | Feature | Pri | Owner | Notes |
|---|---|---|---|---|
| D1 | **Pause**: temporary unblock (1/5/15 min) for non-strict blocks | P0 | W1/W6 | Re-block scheduled offline |
| D2 | Pause friction: countdown / breathing screen before pause is granted | P1 | W6 | |
| D3 | Pause budget: max pauses per day per rule | P1 | W1 | `rule.maxPausesPerDay` |
| D4 | **Unlock request** to server (admin approves/denies; approval = server override) | P1 | W2/W3/W4 | |
| D5 | Strictness levels per rule: `flexible` (pausable) / `strict` (no pause) | P0 | W1 | |

## E. Remote management (server + dashboard)

| ID | Feature | Pri | Owner | Notes |
|---|---|---|---|---|
| E1 | Admin accounts (email/password), owns devices | P0 | W3 | |
| E2 | Device pairing via 8-char code / QR | P0 | W3/W2/W6 | |
| E3 | Policy bundle per device, versioned; device acks applied version | P0 | W3/W2 | |
| E4 | Push delivery (APNs token auth): NSE alert push + silent push | P0 | W3/W5 | |
| E5 | Dashboard: devices, status (online/stale/revoked), currently blocked groups, applied version | P0 | W4 | Server computes status with the same engine semantics (TS port, same test vectors) |
| E6 | Dashboard: edit groups (names, web domains), rules (schedules), overrides | P0 | W4 | |
| E7 | Dashboard: unlock-request inbox | P1 | W4 | |
| E8 | Device groups / apply policy to many devices | P1 | W3 | "Fleet" for families/classrooms |
| E9 | Webhooks / REST API keys for third-party automation (e.g. "block games until chores done" from Home Assistant) | P1 | W3 | Same override endpoint |
| E10 | Audit log (who changed what, device events) | P1 | W3 | |
| E11 | Email/push alerts to admin on tamper | P1 | W3 | |

## F. Insight & motivation

| ID | Feature | Pri | Owner | Notes |
|---|---|---|---|---|
| F1 | Usage report (DeviceActivityReport extension): today / week, by group | P1 | W5 | Stays on device |
| F2 | Focus stats: minutes focused, sessions, pauses, streak | P1 | W1/W6 | Computed from local history |
| F3 | Home screen widget: current status / next block | P2 | — | WidgetKit |
| F4 | Live Activity for focus sessions | P2 | — | ActivityKit |
| F5 | Focus score / gamification | P2 | — | |

## G. Platform & quality

| ID | Feature | Pri | Owner |
|---|---|---|---|
| G1 | Shared pure-Swift engine with test vectors (runs on Linux CI) | P0 | W1 |
| G2 | Server test suite running the same engine vectors | P0 | W3 |
| G3 | XcodeGen project, entitlements, CI (Linux + macOS) | P0 | W7 |
| G4 | Privacy: no app identities leave device; privacy manifest (`PrivacyInfo.xcprivacy`) | P0 | W7 |
| G5 | Accessibility & Dynamic Type across app UI | P1 | W6 |
| G6 | Localization scaffolding | P2 | W6 |

## MVP definition (first TestFlight)

All **P0** rows. Concretely, a user can: authorize → set Protection Lock → create a
group with the picker → create a weekday schedule → see the custom shield at the right
time with the app closed → start a strict 25-min session → pair with the server → have an
admin block/unblock the group from the dashboard within seconds, with timed unblocks that
re-block offline → and cannot delete the app or revoke access without the Screen Time
passcode.
