# Tether app (W6) — screen map & platform design

SwiftUI, iOS 17, Swift 5.10, `@Observable`. Written without a compiler (Linux); see `// VERIFY:` comments.

## Layout
```
Sources/
  App/         TetherApp (@main) · AppDelegate (+AppEnvironment) · AppModel · DeepLinkRouter · RootView(+MainTabView)
  Platform/    PlatformServices (protocol) · LivePlatformServices (TetherKit/TetherAPI) · StubPlatformServices (+SampleData)
  Components/  PINPad · WeekdayPicker · GroupChip(+Picker) · CountdownRing · StatusBanner · EmptyState · Card · Formatters · ColorHex
  Features/
    Onboarding/  Welcome → How it works → Screen Time permission → Protection Lock → Hardening checklist → First group → First block → Done
    Home/        status banner, unmapped-server-group prompts, session card (ring), "Blocked now", quick start, next block; StartSessionView
    Groups/      list (local / managed), GroupEditorView (FamilyActivityPicker, domains), ServerGroupView (read-only + app mapping)
    Rules/       list (local / managed, lock icon), RuleEditorView (+RuleDraft validation), RuleDetailView (read-only)
    Pause/       PauseFlowView: eligibility → 10 s breathing friction → 1/5/15 min → StateMutations.startPause; "Ask admin" in remoteApproval
    Insights/    FocusStats cards + DeviceActivityReport(.totalActivity)
    Settings/    SettingsView · PairingView · ProtectionView (+Disable, ChangePIN) · HardeningChecklistView · DiagnosticsView
Resources/Assets.xcassets   AppIcon (placeholder, no image) + AccentColor
```

## Data flow
`AppModel` (main actor) owns a copy of `PersistedState`. Every intent:
`StateStore.update { mutation }` → `platform.reconcile(now:)` → `refresh()` (reload, `PolicyEngine.evaluate`,
`TransitionPlanner.annotateUntil`) → events are enqueued by `StateMutations` → `syncNow()`.
A 1 s ticker runs only while the scene is active; it re-evaluates the engine each second and does a full refresh
when any group state changes or every 15 s. Scene `.active` → reconcile + refresh + sync.

## PlatformServices
Protocol (`@MainActor`) wrapping everything platform-specific: authorization, per-group `FamilyActivitySelection`
store, reconcile, protection enable/disable/changePIN, sync, push, pairing, unlock requests.
- `LivePlatformServices` — the only file touching `TetherKit` (`AuthorizationManager`, `SelectionStore`,
  `Reconciler`, `ProtectionController`, `PlatformSync`, `Keychain`, `AppGroup`) and `TetherAPI` (`APIClient`).
- `StubPlatformServices` — in-memory (temp-dir `StateStore`), used by `#Preview`s (`AppModel.preview()`),
  the Simulator (default) and when env `TETHER_PLATFORM_STUB=1`. On the Simulator `TETHER_PLATFORM_STUB=0` forces Live.
  Fake PIN, fake pairing (any 8-char code), unlock request auto-approves after 3 polls.

## Deep links & system hooks
`tether://pair?code=&server=` → pairing sheet · `tether://pause?group=` → pause flow · `tether://session/new` → start session.
Notification taps read `userInfo["url"]` (set by the shield-action extension / NSE). `AppDelegate` registers for remote
notifications, forwards silent pushes to `PlatformSync.handlePush`, registers BGAppRefresh `tether.refresh`.

## Product rules honoured
No `LocalAuthentication`, no biometrics. Onboarding states that iOS only lets the Screen Time passcode protect the app at
the OS level. Strict blocks: no pause, no end early, local group/rule edits that would loosen them are refused.

## Info.plist / entitlements needed (W7)
See the W6 hand-off report: `CFBundleURLTypes` (tether), `BGTaskSchedulerPermittedIdentifiers` = `tether.refresh`,
`UIBackgroundModes` = `remote-notification`, `fetch`; entitlements: family-controls, app group, keychain group, `aps-environment`.
Do NOT add `NSFaceIDUsageDescription`.
