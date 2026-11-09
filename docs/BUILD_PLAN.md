# Build Plan — for Claude agents

Read first: [`PLATFORM_CONSTRAINTS.md`](PLATFORM_CONSTRAINTS.md) → [`ARCHITECTURE.md`](ARCHITECTURE.md)
→ [`FEATURE_MAP.md`](FEATURE_MAP.md) → `contracts/`. The contract (`contracts/*`) and
`ios/Packages/TetherCore/Sources/TetherCore/Models.swift` are **frozen**: change them only
deliberately, in one commit that updates the schema, the vectors, the Swift models and the
server together.

## Phases

| Phase | Where | What | Status |
|---|---|---|---|
| P0 | cloud (Linux) | Docs, contract, JSON schemas, 61 golden engine vectors + Python reference engine, Swift models, package skeleton | ✅ done |
| P1 | cloud (Linux) | Workstreams W1–W7 in parallel (below) | see table |
| P2 | cloud (Linux) | W8: audit all Apple-framework Swift (can't be compiled on Linux) against real SDK signatures | ✅ |
| P3 | cloud (Linux) | Integration: cross-stack e2e smoke test (`make e2e`), device time zone on ack, Linux iOS type-check harness (`make typecheck-ios-linux`), placeholder app icon | ✅ |
| M0 | **Mac** | Toolchain + signing setup (`docs/MAC_HANDOFF.md`) | ⬜ |
| M1 | **Mac + iPhone** | Feasibility spikes S1–S6 | ⬜ |
| M2 | **Mac** | Generate Xcode project, compile all targets, fix errors, unit tests on iOS sim | ⬜ |
| M3 | **Mac + iPhone** | On-device test matrix (`docs/TEST_PLAN_DEVICE.md`) | ⬜ |
| M4 | **Mac** | Family Controls distribution entitlement, TestFlight, App Store review notes | ⬜ |
| S1 | anywhere | Deploy server (Fly.io/Render/VM) + APNs key | ⬜ |

## Workstreams (P1/P2)

Each workstream **owns** its directories; don't edit outside them (except appending to
"Open questions" at the bottom of this file). "Verify" is what proves it is done.

| ID | Workstream | Owns | Verify on Linux | Status |
|---|---|---|---|---|
| W1 | **Engine** — `PolicyEngine`, `ScheduleMath`, `TransitionPlanner`, `StateStore`, `PINHasher`, history/stats helpers | `ios/Packages/TetherCore/Sources/TetherCore/**` (not the JSON shape in Models.swift), `Tests/TetherCoreTests/**` | `swift test` — all 61 vectors pass | ✅ |
| W2 | **API client** — `APIClient`, `SyncEngine`, `PushPayload`, backoff | `Sources/TetherAPI/**`, `Tests/TetherAPITests/**` | `swift test` with URLProtocol stubs | ✅ |
| W3 | **Server** — Fastify API per `contracts/api.md`, SQLite, APNs, TS engine port, OpenAPI | `server/**` | `npm test` (incl. engine vectors), `npm run typecheck` | ✅ |
| W4 | **Admin dashboard** — React + Vite | `admin/**` | `npm run build`, `npm test` | ✅ |
| W5 | **iOS platform** — `TetherKit` (Reconciler, ShieldApplier, ActivityScheduler, AuthorizationManager, SelectionStore, ProtectionController, Keychain, AppGroup) + all 5 extensions | `Sources/TetherKit/**`, `ios/Extensions/**` | Linux build still passes (all Apple code behind `#if canImport(ManagedSettings)`); W8 audit | 🟡 written, needs Mac compile |
| W6 | **iOS app UI** — SwiftUI app, onboarding, groups, rules, sessions, pause, pairing, settings | `ios/App/**` | W8 audit; compiles on Mac in M2 | 🟡 written, needs Mac compile |
| W7 | **Project & infra** — XcodeGen `project.yml`, Info.plists, entitlements, xcconfig, privacy manifest, CI, scripts, Makefile | `ios/project.yml`, `ios/Config/**`, `.github/**`, `scripts/**`, `Makefile` | `python3 -c yaml.safe_load`, `actionlint` if available, scripts `bash -n` | ✅ |
| W8 | **Apple API audit** (after W5/W6) | review only; fixes in W5/W6 dirs | written report `docs/reviews/W8-apple-api-audit.md` | ✅ 31 issues (19 fixed, 12 left for Mac); TetherKit + extensions + app platform layer type-check against SDK-shaped shims; SwiftUI views hand-reviewed |

### Shared conventions (all Swift workstreams)

- Swift 5.10 language mode (tools-version 5.10), iOS 17 minimum, `@Observable` for UI models.
- Target / bundle IDs (prefix from `BUNDLE_ID_PREFIX` build setting, default `com.newwestsite`):

  | Target | Path | Bundle ID suffix | Principal type |
  |---|---|---|---|
  | `Tether` (app) | `ios/App/` | `.tether` | `@main struct TetherApp: App` |
  | `TetherMonitor` | `ios/Extensions/TetherMonitor/` | `.tether.monitor` | `class TetherMonitorExtension: DeviceActivityMonitor` |
  | `TetherShieldConfig` | `ios/Extensions/TetherShieldConfig/` | `.tether.shieldconfig` | `class TetherShieldConfigurationExtension: ShieldConfigurationDataSource` |
  | `TetherShieldAction` | `ios/Extensions/TetherShieldAction/` | `.tether.shieldaction` | `class TetherShieldActionExtension: ShieldActionDelegate` |
  | `TetherReport` | `ios/Extensions/TetherReport/` | `.tether.report` | `@main struct TetherReportExtension: DeviceActivityReportExtension` |
  | `TetherPush` | `ios/Extensions/TetherPush/` | `.tether.push` | `class TetherNotificationService: UNNotificationServiceExtension` |

- Every target's Info.plist has keys (W7 sets them from build settings):
  `TetherAppGroup` = `group.$(BUNDLE_ID_PREFIX).tether`,
  `TetherKeychainGroup` = `$(AppIdentifierPrefix)$(BUNDLE_ID_PREFIX).tether.shared`,
  `TetherDefaultServerURL` = `$(TETHER_SERVER_URL)`.
  `TetherKit.AppGroup` reads them via `Bundle.main.object(forInfoDictionaryKey:)`.
- URL scheme `tether://` — `tether://pair?code=…&server=…`, `tether://pause?group=<id>`,
  `tether://session/new`.
- Extensions link **only** `TetherCore` + `TetherKit` (+ `TetherAPI` for `TetherPush` and
  `TetherMonitor` heartbeats). Keep the Monitor extension tiny (6 MB memory cap).
- No biometrics (`LocalAuthentication` must not be imported anywhere).
- Logging: `os.Logger(subsystem: "tether", category: …)` behind `#if canImport(os)`.

### Server conventions (W3/W4)

- Node 22, TypeScript strict, ESM. Server port `8787`. Admin dev server proxies `/v1` → 8787.
- Server serves `admin/dist` at `/` when it exists (production single deploy).
- Env: `PORT`, `DATABASE_PATH` (default `./data/tether.db`), `JWT_SECRET`,
  `PUBLIC_BASE_URL`, `APNS_KEY_P8` (PEM contents or path), `APNS_KEY_ID`, `APNS_TEAM_ID`,
  `APNS_TOPIC` (= app bundle id), `APNS_ENV` (`sandbox`|`production`). Without APNs vars a
  logging mock transport is used.

## Mac phases in detail

### M0 — setup (≈30 min)
`scripts/bootstrap-mac.sh`: checks Xcode ≥ 16, installs `xcodegen` (brew), runs
`xcodegen generate` in `ios/`, runs `swift test` for the package, runs server tests.
Human needed for: Apple Developer team ID → `ios/Config/Local.xcconfig`
(`DEVELOPMENT_TEAM`, `BUNDLE_ID_PREFIX`), signing in to Xcode, plugging in an iPhone
(iOS 17+, Developer Mode on).

### M1 — spikes (must pass before relying on the feature)
| Spike | Question | Pass criteria | Fallback if it fails |
|---|---|---|---|
| S1 | With a Screen Time passcode set, does revoking our app in Settings → Screen Time require the passcode? Does `denyAppRemoval` stop deletion? | Both need the passcode / are blocked | Rely on `.child` mode for strict users; strengthen tamper alerts |
| S2 | Can `TetherPush` (NSE) write `ManagedSettingsStore` + read App Group within its time budget? | Shield appears/disappears ≤ 5 s after push with app force-quit | Silent push + BGAppRefresh; document latency |
| S3 | Can `TetherShieldAction` post a local notification that deep-links into the pause flow? | Tap "Unlock for 5 min" → notification → app opens on pause screen | Shield secondary button just says "Open Tether to pause" |
| S4 | DeviceActivity limits: min interval (15 min?) and max concurrent activities (20?) on iOS 17/18 | Document actual numbers; TransitionPlanner limit fits | Lower `limit` in ActivityScheduler |
| S5 | `webContent.blockedByFilter = .specific` with 50 domains, together with `shield.webDomains` | Both apply in Safari | Use tokens only for websites |
| S6 | Monitor extension memory under 6 MB with TetherCore linked | No jetsam in Console | Trim TetherCore imports / avoid JSONDecoder hot paths |

Record results in `docs/reviews/M1-spikes.md` and update `PLATFORM_CONSTRAINTS.md` **[VERIFY]** tags.

### M2 — compile & fix
1. `cd ios && xcodegen generate && open Tether.xcodeproj`.
2. Build each scheme for a generic iOS device; fix compile errors **in place** (W5/W6
   code was written without a compiler — expect a batch of fixes).
3. `xcodebuild test -scheme TetherCore-Package -destination 'platform=iOS Simulator,name=iPhone 16'`.
4. Run the app in the Simulator with `TETHER_PLATFORM_STUB=1` (W6 provides stub
   platform so UI is navigable without FamilyControls).

### M3 — on-device matrix → `docs/TEST_PLAN_DEVICE.md`

### M4 — release
- Request **Family Controls (Distribution)** for all 6 bundle IDs (weeks of lead time —
  do it as soon as bundle IDs are registered in M0).
- App Review notes: explain Screen Time API use, server feature, and that no usage data
  leaves the device.
- APNs: production key, `APNS_ENV=production` on server.

## Open questions (append below; tag with workstream)

- [ ] (product) Final app name / bundle prefix — currently "Tether", `com.newwestsite`.
- [ ] (product) Hosting for the server (Fly.io suggested: SQLite volume + single machine).
- [ ] (product) Does the partner PIN default to "same as Screen Time passcode" in copy, or do we recommend a different secret?
- [x] (W8) `docs/ARCHITECTURE.md` §5 still names one-shot activities `tether.t.<n>`; W8 renamed them `tether.t.<epochSeconds>` (stable names, no churn) and decomposes them in the device calendar.
- [ ] (W8) Per-store token cap for `shield.applications`/`webDomains` assumed 50 → ShieldApplier shards over `tether.block[.1…3]`; confirm in spike S5.
- [ ] (W1) `StateStore.update` prunes on every write by default (`pruneOnUpdate: true`, 7-day sessions/pauses, 2-day usage hits, 500 events); tests that persist old fixed-date sessions should pass `pruneOnUpdate: false`.
