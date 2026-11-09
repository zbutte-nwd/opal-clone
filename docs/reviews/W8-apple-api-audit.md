# W8 — Apple API audit (iOS 17/18 SDK)

Scope: every Apple-framework Swift file — `TetherKit` (15 files), the 5 extensions, `ios/App/**`
(platform layer, app shell, all SwiftUI views), `ios/project.yml`, `ios/Config/**`.
Written on Linux; nothing here was compiled against the real SDK. Fixes are in place; nothing committed by W8.

## Summary

- **Method.** (1) Line-by-line review against the iOS 17/18 SDK surface. (2) A **cross-module
  type-check harness** (`/tmp/w8-check`, throwaway): a SwiftPM package that depends on the real
  `TetherCore`/`TetherAPI` (path dependency) plus hand-written fake modules named `FamilyControls`,
  `ManagedSettings`, `ManagedSettingsUI`, `DeviceActivity`, `UserNotifications`, `BackgroundTasks`,
  `UIKit` (subset), `Combine` (subset), `Security`, `os`. The fakes copy the real SDK signatures,
  including the iOS 18 concurrency annotations that cause trouble (`@MainActor UIApplicationDelegate`,
  `@Sendable` BGTask/UN completion handlers, escaping `OSLogMessage` autoclosures). Into it go, unmodified
  except for the `#if os(iOS)` line: all of TetherKit (except the SwiftUI-only `ReportContexts.swift`), the
  Monitor/Push/ShieldAction/ShieldConfig extensions, and the non-SwiftUI app files (`AppModel`,
  `AppDelegate`+`AppEnvironment`, `DeepLinkRouter`, `PlatformServices`, `Live/StubPlatformServices`,
  `Formatters`, `RuleDraft`). **They now type-check with 0 errors** (one Swift-5-mode Sendable
  warning, see L1). 5 XCTest cases cover the new pure helpers (one-shot activity names, pause deep-link
  round trip including an empty group, domain normalization, token sharding, category fallback).
  SwiftUI views (24 files) cannot be type-checked on Linux; they were reviewed by hand (list below), and
  targeted language questions (memberwise inits with `private` wrapped properties, tuple key paths,
  `.map(String.init)`, ternary-with-assignment, `@MainActor` method references) were confirmed with `swiftc`.
- **Every cross-module call is consistent**: every TetherCore/TetherAPI/TetherKit symbol that App and
  Extensions use exists with the exact labels and types (`SyncEngine.init` providers, `APIClient`,
  `StateMutations`, `ShieldCopy`, `TransitionPlanner.annotateUntil`, `PairingLink`, DTO enums, …).
- **Found 31 issues: 19 fixed in place, 12 left for the Mac with reasons.** The most important fixes:
  an invalid `SWIFT_VERSION` that breaks every target, a compile error in the BGTask handler, a
  DeviceActivity time-zone bug, a shield "Unlock" button that did nothing for category-blocked apps,
  launch-time reconcile/sync never running, and spurious tamper events at launch.
- Confirmed: no `LocalAuthentication`/`LAContext`/`NSFaceIDUsageDescription` anywhere (the only
  mention is README prose); every TetherKit file is wrapped in `#if os(iOS) && canImport(…)`; all
  project.yml paths exist; all plists/entitlements parse; principal classes match the Info.plists; every
  extension links the products whose modules it imports; every `.swift` file passes `swiftc -parse`.

## Issues

Confidence = how sure W8 is that the problem is real *and* the fix is right.

### Fixed in place

| # | File:line | Problem | Fix | Conf. |
|---|---|---|---|---|
| F1 | `ios/project.yml:24`, `ios/Config/Base.xcconfig:20` | `SWIFT_VERSION = 5.10`. That is a compiler version, not a language mode. Xcode accepts only 4.0 / 4.2 / 5.0 / 6.0 and rejects anything else for **every target** ("SWIFT_VERSION '5.10' is unsupported"). | Set `5.0` (= Swift 5 language mode, same as the package's tools-version 5.10). | high |
| F2 | `App/Sources/App/AppDelegate.swift` (BGTask register) | `AppDelegate` is implicitly `@MainActor` (it conforms to `UIApplicationDelegate`). The iOS 18 SDK `launchHandler` is `@Sendable`, so the synchronous call to `Self.handleRefresh` (main-actor) is a **compile error**, reproduced in the harness: "call to main actor-isolated static method in a synchronous nonisolated context". | `nonisolated static let refreshTaskId`; `scheduleRefresh` and `handleRefresh` are `nonisolated static`; the work runs in `Task { @MainActor … }`, and the task is completed with `!Task.isCancelled`. | high |
| F3 | `AppDelegate.swift` (UN delegate) | The `UNUserNotificationCenterDelegate` requirements are nonisolated and can be called off the main thread, but they were implemented as main-actor methods. That gives a warning now, an error in Swift 6, and a runtime queue assertion if dynamic isolation checks are on. | Both methods are `nonisolated`, take their payload (`url` string, completion handler) into `UncheckedBox`, and hop to the main actor. They use `NotificationRouter.urlKey`. The completion-handler variants are kept, without async duplicates. | med-high |
| F4 | `TetherKit/AuthorizationManager.swift:25` | `private static let lastSeenKey` in a `@MainActor` class was read from the `nonisolated static recordIfChanged` (harness warning; error in Swift 6). | `private nonisolated static let`. | high |
| F5 | `TetherKit/AuthorizationManager.swift` | Right after launch `authorizationStatus` can briefly read `.notDetermined` even when approved. The first snapshot or publisher value was then recorded as approved→notDetermined→approved, which queues 2 spurious `authorizationChanged` events per launch (false tamper alerts on the dashboard). | A `settled` flag: `.notDetermined` is not recorded until a definite status (approved or denied) has been seen in the process. | medium |
| F6 | `TetherKit/ActivityScheduler.swift` (`schedule`) | One-shot `DateComponents` were decomposed in the **policy** time zone (`bundle.timeZone`), but `DeviceActivitySchedule` reads components in the **device** calendar. When the two differ, every wake fires at the wrong wall-clock time. | Decompose with `Calendar.current`. The policy tz stays in the signature so a change still forces a re-plan. | high |
| F7 | `ActivityScheduler.swift` | One-shots were named `tether.t.<index>`. As soon as the first transition passed, every name/signature shifted, so all ~18 activities were stopped and re-registered on every wake. That is churn, and it risks the S4 restart/re-fire behaviour. | Name = `tether.t.<epochSeconds>` (`oneShotActivityName(for:)` / `transitionDate(fromActivity:)`), so unchanged transitions are left alone. Legacy `tether.t.N` entries are still owned (prefix) and get stopped. | medium |
| F8 | `ActivityScheduler.swift` + `Extensions/TetherMonitor/TetherMonitorExtension.swift` | `DateComponents` drop sub-seconds, so the wake could land up to 1 s *before* a session/pause end. The engine then still sees the old state, the transition stays "in the future", the activity is unchanged and is not re-registered: **the change is missed**. | The fire time is rounded up to a whole second. In `intervalDidStart`, if the OS wakes a one-shot early (≤ 120 s), the Monitor reconciles at the transition instant. | medium |
| F9 | `ActivityScheduler.swift` (usage events) | iOS 17.4 added `includesPastActivity` (default **false** in the new init). A usage rule registered or changed mid-day ignored the usage already accumulated that day. | `DeviceActivityEvent(…, threshold:, includesPastActivity: true)` under `#available(iOS 17.4, *)`, with the old init below that. Re-firing on re-registration is harmless because `recordUsageLimitHit` is idempotent per day. | medium (label: VERIFY) |
| F10 | `TetherKit/ShieldApplier.swift` | `shield.applications` / `shield.webDomains` are believed to accept ≤ 50 tokens **per store** (more and the store's app shield is ignored). Large groups would silently unblock. | Tokens are sharded deterministically (by token key) over `tether.block`, `tether.block.1…3` (up to 200 per kind). Categories and the web filter stay on shard 0, and `clearAll()` clears every shard. Harmless if the real cap is higher. | medium (limit: VERIFY S5) |
| F11 | `Extensions/TetherShieldAction/TetherShieldActionExtension.swift`, `TetherKit/ShieldContext.swift` | For an app or site shielded **through a category**, ShieldConfig finds the category entry and shows "Unlock for 5 min". `ShieldActionDelegate`, however, only receives the app/site token, which has no entry, so the button just closed the shield. | New `ShieldContextStore.categoryFallbackEntry()`: one group → that entry; several groups → a non-strict entry with `groupId ""` (the pause flow lets the user choose); all strict → strict (close). | high |
| F12 | `App/Sources/App/TetherApp.swift:20` | `.onChange(of: scenePhase)` never reports the *initial* `.active`, so a cold launch skipped `sceneBecameActive()`: no reconcile, no sync, no heartbeat until the next foreground. | `.onChange(of: scenePhase, initial: true)` (iOS 17). The handler is idempotent. | med-high |
| F13 | `App/Sources/App/AppModel.swift` | `screenTimeAuth` was a snapshot copied in `refresh()`, so a revocation or the launch-time status settling showed up only after the next refresh (up to 15 s), with a wrong "access needed" banner meanwhile. | Computed read-through `platform.screenTimeAuth` (`AuthorizationManager` and the stub are `@Observable`, so views update immediately). | medium |
| F14 | `App/Sources/Features/Insights/InsightsView.swift:67` | `DeviceActivityFilter(segment:)` relied on default `users`/`devices`. | Arguments spelled out exactly as in Apple's sample (`users: .all, devices: .init([.iPhone])`). | low |
| F15 | `ios/Config/PrivacyInfo.xcprivacy` | The code uses `UserDefaults(suiteName: appGroup)` (`AppGroup.defaults`), which needs reason **1C8F.1**; only CA92.1 was declared (ITMS-91053 at submission). | Added `1C8F.1`. | high |
| F16 | `TetherKit/PlatformSync.swift:81`, `TetherKit/Keychain.swift:11` | `enroll` stored the token through the `deviceToken` setter, which uses `try?`. A missing keychain-access-groups entitlement (-34018, a classic first-build problem) left the device silently unpaired, showing "couldn't reach the server". | Throwing `Keychain.setString`, and `KeychainError: LocalizedError` with a -34018 hint. | medium |
| F17 | `TetherKit/AppGroup.swift` | If the App Group is not provisioned, every target silently gets its own private directory, so the extensions never see app state. | Logs a `.fault` once per process. | low |
| F18 | `Extensions/TetherPush/TetherNotificationService.swift` | `NSLock` was used with only `import UserNotifications` (works through re-export, but is fragile). | `import Foundation`. | low |
| F19 | various `// VERIFY:` | Signature VERIFYs that W8 confirmed (ShieldConfiguration init, DeviceActivity names/center, `ActivityCategoryPolicy.specific`, `Context("…")`) were noise. | Re-marked as `W8-audited`; `ios/Extensions/README.md` VERIFY list updated. | — |

### Left for the Mac (not changed)

| # | File:line | Problem | Why not fixed / what to do | Conf. |
|---|---|---|---|---|
| L1 | `App/Sources/Platform/LivePlatformServices.swift:98` | Passing a non-Sendable `[AnyHashable: Any]` from the main actor into `PlatformSync.handlePush`. | Swift 5 warning only, and the dictionary is not mutated. In Swift 6 mode, box it or decode `PushPayload` first. | high (warning) |
| L2 | `LivePlatformServices.swift:140-147` | Push environment is chosen by `#if DEBUG`. A Release build signed with a development profile uses the APNs *sandbox* but reports `production`. | Needs the real provisioning setup; read `aps-environment` from the embedded profile, or have the server retry the other environment on `BadDeviceToken`. | medium |
| L3 | `TetherKit/PlatformSync.swift:51` (`authorizationStatusProvider`) | An ack sent in the first moments after launch can report `notDetermined` (same quirk as F5). | Depends on observed device behaviour; if seen, have the provider wait briefly or report the last *settled* value. | low-med |
| L4 | `App/Resources/Assets.xcassets/AppIcon.appiconset` | Contains no image. Fine for dev builds (warning); TestFlight/App Store validation fails. | Needs artwork (M4). | high |
| L5 | `ActivityScheduler.swift` daily/usage schedules | `00:00–23:59` is device-local midnight. If `bundle.timeZone` ≠ device tz, the usage-limit day and the midnight re-plan follow the device, not the policy tz. | DeviceActivity has no tz parameter; acceptable edge case, document it. | medium |
| L6 | `docs/ARCHITECTURE.md` §5 | Still says `tether.t.<n>` (now `tether.t.<epochSeconds>`). | Outside W8's edit scope; one-line doc update for the doc owner. | high |
| L7 | `ios/project.yml:84-101,161-164` | XcodeGen `extensionkit-extension` + `embed: true` must put `TetherReport.appex` in `Tether.app/Extensions`, not `PlugIns`. | XcodeGen behaviour can only be checked on the Mac; fallback is documented inline. | medium |
| L8 | `ios/project.yml:200-206` | Scheme test targets `package: TetherCore/TetherCoreTests`. | Needs a recent XcodeGen; delete the block if `generate` errors. | medium |
| L9 | `TetherKit/ReportContexts.swift` | TetherKit (linked into Monitor/Shield/NSE) references the SwiftUI `DeviceActivityReport.Context`. If the SDK marks `DeviceActivityReport` extension-unavailable and Xcode builds the package with `APPLICATION_EXTENSION_API_ONLY`, those extensions will not link. It also adds SwiftUI to the Monitor (S6). | Unlikely, and the Report extension needs the type anyway. If it bites, move the 3-line extension into the App and the Report target (identical string). | low-med |
| L10 | `App/Sources/Features/Groups/SelectionSummary.swift` | `Label(_: ApplicationToken/ActivityCategoryToken/WebDomainToken)` is believed to be in **FamilyControls** (iOS 15.2+); the file imports ManagedSettings and ManagedSettingsUI too. | Should compile either way. | med-high |
| L11 | `TetherKit/ShieldApplier.swift` (`denyAppRemoval ?? true`) | Without a bundle, protection blocks deletion of **all** apps on the device. | Product decision; spike S1. | n/a |
| L12 | iOS 18 SDK annotations | If `AuthorizationCenter` is `@MainActor` in the iOS 18 SDK, `AuthorizationManager.currentStatusValue()` (nonisolated, called from SyncEngine) gets a warning or error. | Not believed to be annotated. If it is, read the status via `await MainActor.run`. | low |

SwiftUI constructs hand-checked as correct (iOS 17): `@Observable` + `.environment(_:)`/`@Environment(T.self)`;
`@Bindable` local in `body` and as a stored property; `NavigationStack`; `.sheet(item:)` with `Identifiable`
(`DeepLink`, `BlockGroup`, `PauseTarget`); `if` inside `.toolbar` (ToolbarContentBuilder `buildIf`, iOS 16+);
`Section(_:content:)` / `Section(content:header:footer:)`; `ForEach($draft.windows) { $w in }`;
`DatePicker(… displayedComponents: .hourAndMinute)`; `.familyActivityPicker(isPresented:selection:)`;
`DeviceActivityReport(.totalActivity, filter:)`; `.onChange(of:)` two-parameter form;
`.confirmationDialog`; `.alert(_:isPresented:actions:message:)`; `LabeledContent`; `.refreshable`; `#Preview`.
Memberwise inits used across files (StepScaffold, StatusBanner, EmptyState, CountdownRing, PINPad, GroupEditorView)
match parameter order, and trailing closures bind to the intended parameter.

Verified correct with no change needed: `ManagedSettingsStore(named:)` + all `shield.*`, `webContent.blockedByFilter = .specific(Set<WebDomain>)`,
`WebDomain(domain:)`, `application.denyAppRemoval`, `clearAllSettings()`; `DeviceActivityCenter.startMonitoring(_:during:events:)`
/ `stopMonitoring(_:)` / `activities`; `DeviceActivitySchedule(intervalStart:intervalEnd:repeats:)`; the three
`DeviceActivityMonitor` overrides (all call `super`); all four `ShieldConfigurationDataSource` overrides, `ShieldConfiguration`
and `.Label(text:color:)`, `Application/WebDomain/ActivityCategory.token`; all three `ShieldActionDelegate.handle` overloads and
`.close/.defer/.none`; `AuthorizationCenter.shared.requestAuthorization(for:)` / `$authorizationStatus`; the report scene (`context`,
`content`, `makeConfiguration(representing:) async`, `activitySegments → categories → applications`, `totalActivityDuration`,
`localizedDisplayName`); the NSE (`didReceive(_:withContentHandler:)`, `serviceExtensionTimeWillExpire`, single-delivery lock);
BGTask registration inside `didFinishLaunching`, `BGTaskSchedulerPermittedIdentifiers` + `fetch` background mode; Keychain dictionaries
(`kSecClassGenericPassword`, access group, `AfterFirstUnlock`, update-then-add on `errSecItemNotFound`); extension point identifiers
and `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).<Class>` for all 4 NSExtension targets; `EXAppExtensionAttributes`
for the Report extension; `ASSETCATALOG_COMPILER_APPICON_NAME` / accent color; `PrivacyInfo.xcprivacy` as a resource.

## Remaining VERIFY list (consolidated, ranked by risk)

1. **S2 — NSE writes ManagedSettings + DeviceActivity + reads App Group/Keychain while locked** (`TetherNotificationService`).
   This is the primary remote-block path. If it fails, the fallback is silent push + BGAppRefresh.
2. **Token key stability** (`ShieldContext.swift` `TokenKey`): the JSON encoding of a token from `selections.json` must equal the
   encoding of the token the OS hands the shield extensions. If not, every shield shows generic copy and never "Unlock".
   Test: block one app, check that the shield title names the group.
3. **S3 — ShieldAction can post a local notification and the tap deep-links** (`NotificationRouter.postPauseNotification`).
   Needs the notification permission requested in `DoneStep`.
4. **S5 — limits**: per-store cap on `shield.applications`/`webDomains` (F10 assumes 50), the 50-domain `blockedByFilter`, and
   coexistence with `shield.webDomains`. Also confirm that 4 extra named stores combine as expected.
5. **S4 — DeviceActivity**: 15-min minimum interval, ≤ 20 activities, restart semantics when re-registering a running
   repeating activity, the `includesPastActivity:` label (F9), and early or late firing of one-shots (F8).
6. **ExtensionKit embedding** of TetherReport (L7), and that `DeviceActivityReport(.totalActivity, …)` renders (same context string).
7. **AuthorizationCenter launch behaviour** (F5/L3) and the `$authorizationStatus` publisher; iOS 18 actor annotations (L12).
8. **Keychain access group** expansion (`$(AppIdentifierPrefix)` in Info.plist) and entitlement in every target (F16 now reports -34018).
9. **S6 — Monitor memory** with TetherKit (+SwiftUI via DeviceActivity) linked (L9).
10. **S1 — `denyAppRemoval`** semantics and Screen Time passcode on revoke.
11. `Label(token)` module (L10); report AsyncSequence shapes; `ManagedSettingsStore.clearAllSettings()` being synchronous.
12. Scheme package test targets (L8); `xcodebuild -list` name `TetherCore-Package`.

## First compile on Mac — expected trouble spots

1. **`xcodegen generate`**: `extensionkit-extension` type and embedding (upgrade XcodeGen ≥ 2.38), and the scheme
   `package:` test targets. Delete that block if rejected.
2. **SwiftUI views** are the only code never type-checked. The most likely errors are result-builder type-inference
   failures in long bodies (HomeView, RuleEditorView, ProtectionView, PauseFlowView); split into `@ViewBuilder`
   helpers. Also `Label(token)` overload resolution in `SelectionSummary`.
3. **Swift 6 compiler in Swift 5 mode**: expect Sendable/isolation *warnings* (non-Sendable `FamilyActivitySelection`,
   `[AnyHashable: Any]`, completion handlers captured in `Task`). Errors are not expected: the known ones (F2, F4) are fixed.
4. **iOS 18 SDK annotations** may differ from iOS 17 (e.g. `@Sendable` added to completion handlers). Implementations
   that take non-`@Sendable` closures still satisfy `@Sendable` requirements; if Xcode flags a near-miss
   `@objc optional` delegate method, match the exact signature it suggests.
5. **Signing / entitlements**: Family Controls (development) must be enabled for all 6 bundle IDs; the App Group and keychain
   group must be registered. Watch for `-34018` (keychain) and the AppGroup `.fault` log (F17).
6. **Simulator**: FamilyControls/ManagedSettings exist in the simulator SDK but do nothing. The app defaults to
   `StubPlatformServices` there (`TETHER_PLATFORM_STUB=0` forces Live).
7. **TetherReport** must be embedded under `Tether.app/Extensions/`; if the report area stays blank, check that first.

## Linux verification (W8)

- `cd ios/Packages/TetherCore && swift build --scratch-path /tmp/w8-build` → Build complete.
- `swift test --scratch-path /tmp/w8-build` → 129 tests, 0 failures.
- `swiftc -parse` on every `.swift` under `ios/` (including all edited files) → no errors.
- Harness `/tmp/w8-check` (fake SDK modules + real TetherCore/TetherAPI): TetherKit, 4 extensions and the 8 non-SwiftUI app
  files compile with 0 errors; 5 behaviour tests pass.
