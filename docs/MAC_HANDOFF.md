# Mac Handoff — instructions for the Claude agent on a Mac

You are picking up a repo that was planned and largely written in a Linux cloud
container. Everything that *could* be compiled and tested on Linux was (see "State at
handoff" below). Everything that touches Apple frameworks was written **without a
compiler** and audited by reading (`docs/reviews/W8-apple-api-audit.md`). Your job:
make it build, run it on a real iPhone, prove the risky assumptions (spikes), and get
to TestFlight.

## Where the Mac left off (2026-11-09) — read this first when resuming

Done: M0 (paid team `W6Y8QLHYZ3`, all 6 targets signed with Family Controls + Push), M2 (everything compiles on
Xcode 26.5 / iOS 26.5 SDK), app **0.2.0** on the user's iPhone 17 Pro (iOS 26.6), paired to the workstation server
(`docs/WORKSTATION.md`), APNs live (sandbox). Guarded schedules + phone visibility/copy shipped (#2). Device results:
`docs/TEST_PLAN_DEVICE.md` (Runs 1–2); spike notes and findings: `docs/reviews/M1-spikes.md`.

To resume on a Mac:
1. `git pull` on `claude/beautiful-wozniak-y76g65`, then `./scripts/bootstrap-mac.sh` (or `cd ios && xcodegen generate`).
2. Recreate the gitignored `ios/Config/Local.xcconfig`: `DEVELOPMENT_TEAM = W6Y8QLHYZ3`,
   `BUNDLE_ID_PREFIX = com.newwestsite`,
   `TETHER_SERVER_URL = https:/$()/zakir-workstation.tail9389f4.ts.net:47443` (port required).
3. Install: `xcodebuild -scheme Tether -destination 'id=<device>' -allowProvisioningUpdates build`, then
   `xcrun devicectl device install app …`. Wireless install needs the phone on the same Wi-Fi as the Mac, or a cable.
   Updating over the existing app keeps pairing, the PIN and state.
4. MCP from the Mac: `claude mcp add --transport http --scope user tether <url>/mcp --header "Authorization: Bearer <key>"`
   (key from `npm run cli -- apikey <name>` on the workstation; never commit keys).
5. Agents talk through commits on this branch (recipient in the commit message). The workstation agent owns `server/`.

Open next steps: S1 (app deletion, iCloud sign-out) while the user still knows the Screen Time passcode, because
someone else will hold it later; S3–S6; the M3 cases not yet run (apps in server groups, usage limits, schedules C*,
the partnerPIN guard prompt); M4: request the Family Controls **Distribution** entitlement for all 6 bundle IDs
(weeks of lead time); bump `MARKETING_VERSION` with every app release (the server gates features on it).

## 0. Before you start (needs the human)

Ask the human for / to do these — you cannot do them yourself:

1. **Apple Developer Program** membership (paid, $99/yr) and the **Team ID**.
2. A **physical iPhone** on iOS 17+ with **Developer Mode** on (Settings → Privacy &
   Security → Developer Mode). FamilyControls does not work in the Simulator.
3. Xcode 16+ signed in to their Apple ID (Xcode → Settings → Accounts).
4. Decide the final **bundle ID prefix** (default `com.newwestsite`) and app name
   (default "Tether").
5. Later (M4): request **Family Controls (Distribution)** entitlement for all six bundle
   IDs at https://developer.apple.com/contact/request/family-controls-distribution
   — weeks of lead time, so ask on day one, right after the bundle IDs exist.
6. For remote control: an **APNs auth key** (.p8, Key ID) from
   Certificates, Identifiers & Profiles → Keys, and somewhere to host `server/`.

## 1. Bootstrap (M0)

```bash
git clone <repo> && cd opal-clone
DEVELOPMENT_TEAM=XXXXXXXXXX BUNDLE_ID_PREFIX=com.newwestsite ./scripts/bootstrap-mac.sh
open ios/Tether.xcodeproj
```
The script installs XcodeGen, writes `ios/Config/Local.xcconfig`, generates the
project, runs the Swift package tests and the server tests. Regenerate the project
whenever `ios/project.yml` changes (`make ios-project`). Never commit the `.xcodeproj`.

In Xcode, for each of the 6 targets, confirm Signing & Capabilities shows: Family
Controls, App Groups (`group.<prefix>.tether`), Keychain Sharing, and (app only) Push
Notifications + Background Modes. Automatic signing should register the App IDs and
App Group for you.

## 2. Compile & fix (M2)

1. Build `TetherCore` package scheme first (it already passes on Linux).
2. Build the `Tether` scheme for "Any iOS Device". Most likely first errors (from the
   W8 audit): SwiftUI result-builder inference in long view bodies, `Label(token)`
   overloads, `DeviceActivityEvent(... includesPastActivity:)` label, Report extension
   embedding (`Tether.app/Extensions/TetherReport.appex`). Expect compile errors in
   `Sources/TetherKit`, `ios/Extensions/*`, `ios/App/*` — these were written blind.
   Fix them **in place**, preserving the public interfaces in `ARCHITECTURE.md §8`
   where possible. Start with `docs/reviews/W8-apple-api-audit.md`, which lists the
   known suspicious API usages and every `// VERIFY:` comment.
3. Run the app in the Simulator with `TETHER_PLATFORM_STUB=1` (scheme env var) to click
   through every screen without FamilyControls.
4. When the real compiler disagrees with a shim in `tools/linux-ios-typecheck/Sources/<Framework>/Shim.swift`,
   fix the shim too, so Linux agents keep an accurate type-checker.
5. Keep `swift test` green on Linux-compatible targets — don't let Apple-only imports
   leak into `TetherCore` / `TetherAPI` (CI runs them on Linux).

## 3. Spikes on device (M1) — do these before polishing anything

Full table in `BUILD_PLAN.md` § M1. In priority order:

- **S1 Screen Time passcode gate**: set a Screen Time passcode, enable protection in
  the app, then try to (a) delete the app, (b) revoke Tether in Settings → Screen Time,
  (c) sign out of iCloud. Record exactly what iOS asks for. This is the user's
  headline requirement — report results to the human immediately.
- **S2 NSE applies policy**: force-quit the app, block a group from the dashboard,
  time until the shield appears.
- **S3 ShieldAction → notification → pause flow**.
- **S4/S5/S6** limits (schedule length, activity count, web filter domains, memory).

Write results to `docs/reviews/M1-spikes.md` and update `[VERIFY]` tags in
`PLATFORM_CONSTRAINTS.md`. If a spike fails, implement the fallback listed in the table.

## 4. Run the server locally against the phone

```bash
cd server && npm install && npm run seed && npm run dev    # prints a pairing code
cd admin && npm install && npm run dev                      # http://localhost:5173
```
The phone can't reach `localhost` — use the Mac's LAN IP (`TETHER_SERVER_URL` in
`Local.xcconfig`, or enter the server URL on the pairing screen) or a tunnel
(`cloudflared tunnel --url http://localhost:8787`). APNs from a dev build needs
`APNS_ENV=sandbox` and the .p8 key env vars (see `server/README.md`).

## 5. Device test matrix (M3)

Work through `docs/TEST_PLAN_DEVICE.md`, filling in the results table. File bugs as
GitHub issues or fix directly.

## 6. Release (M4)

- Distribution entitlement approved for all 6 bundle IDs (see §0.5).
- Archive → TestFlight. Production APNs (`aps-environment = production`,
  `APNS_ENV=production`).
- App Review notes template: what the Screen Time API is used for; that the remote
  server only controls named groups and never receives app identities or usage; demo
  account + pairing code for reviewers.

## State at handoff

As of the original Linux handoff (superseded by the section at the top and `docs/BUILD_PLAN.md`):

| Area | Verified on Linux? |
|---|---|
| contracts (schemas, 61 vectors, Python reference) | ✅ validated & passing |
| `TetherCore` (engine, planner, store, PIN, stats) | ✅ `swift test` |
| `TetherAPI` (client, sync, push parsing) | ✅ `swift test` with stubbed URLProtocol |
| `server/` | ✅ `npm test` (incl. engine vectors + schema validation of emitted bundles) |
| `admin/` | ✅ `npm run build && npm test` |
| cross-stack e2e (server ⇄ device API ⇄ Swift engine) | ✅ `make e2e` |
| `TetherKit`, 4 extensions, app platform/model layer | ⚠️ type-checked on Linux against SDK **shims** (`make typecheck-ios-linux`) + audited; **needs real compile** |
| SwiftUI views (24 files), Report extension | ⚠️ syntax-checked + hand-audited only; expect result-builder errors |
| `ios/project.yml`, plists, entitlements | ⚠️ syntax-validated; needs `xcodegen generate` |
