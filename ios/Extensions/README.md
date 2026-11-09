# Tether extensions

Swift sources only; Info.plists, entitlements and target wiring are owned by W7 (`ios/Config/`, `ios/project.yml`).
Every extension needs the `com.apple.developer.family-controls` entitlement (Monitor, ShieldConfig, ShieldAction,
Report, Push, and the app), the App Group, and the shared keychain group. All of them link `TetherCore` + `TetherKit`;
`TetherPush` additionally links `TetherAPI` (TetherKit already depends on it, so linking TetherKit transitively pulls it
in — keep TetherMonitor/ShieldConfig/ShieldAction off `TetherAPI` imports to stay lean).

All process logic funnels into `Reconciler.shared.reconcile()` (TetherKit): load `state.json` -> evaluate -> write
ManagedSettings stores -> plan transitions -> register DeviceActivity schedules. It is synchronous, offline, idempotent.

| Extension | Principal class | Trigger | Does | Limits |
|---|---|---|---|---|
| `TetherMonitor` | `TetherMonitorExtension: DeviceActivityMonitor` | OS, at `tether.t.<epochSeconds>` / `tether.daily` boundaries and `tether.usage.<rule>` thresholds | `intervalDidStart/End` -> reconcile (a one-shot that fires early reconciles at its own instant). `eventDidReachThreshold` -> `recordUsageLimitHit` (state.json + `usageLimitReached` event) -> reconcile | **No networking.** ~6 MB memory (S6). Short runtime. |
| `TetherShieldConfig` | `TetherShieldConfigurationExtension: ShieldConfigurationDataSource` | OS, whenever a shield is drawn | Looks the token up in `shieldContext.json` (App Group) -> title/subtitle/buttons ("Close", and "Unlock for 5 min" unless strict). Generic fallback copy if no entry | Very tight memory; no network; must return fast. |
| `TetherShieldAction` | `TetherShieldActionExtension: ShieldActionDelegate` | OS, on shield button tap | Primary -> `.close`. Secondary -> local notification "Tap to pause" (`tether://pause?group=<id>`, category `tether.pause`) then `.defer`. Apps/sites shielded via a *category* resolve through `ShieldContextStore.categoryFallbackEntry()` (empty group id = let the pause flow choose). Cannot open the app | Short; must call `completionHandler` after the notification request is accepted. |
| `TetherReport` | `@main TetherReportExtension: DeviceActivityReportExtension` | App embeds `DeviceActivityReport(.totalActivity, filter:)` | `TotalActivityReport` scene -> `ActivitySummary` -> `TotalActivityView` (total today, top categories, top apps) | Sandboxed: no network, results cannot leave the device. Link TetherKit (shared `Context.totalActivity`). |
| `TetherPush` | `TetherNotificationService: UNNotificationServiceExtension` | APNs alert push with `mutable-content: 1` | `PlatformSync.handlePush` (inline bundle or fetch -> store -> reconcile -> ack) -> reconcile -> rewrite body ("Social is now blocked until 3:00 PM") | ~30 s wall clock, ~24 MB memory. Delivers best attempt on `serviceExtensionTimeWillExpire`. |

## App-side obligations (W6/W7)

- Call `NotificationRouter.registerCategories()` at launch, request notification authorization (extensions cannot),
  and in the `UNUserNotificationCenterDelegate` open `response.notification.request.content.userInfo["url"]`.
- Link TetherKit into the Report extension and the app; embed `DeviceActivityReport(.totalActivity, filter: …)`.
- Call `AuthorizationManager`, `ProtectionController`, `PlatformSync` from the app; keychain group + app group in all targets.

## What the M1 spikes must verify (see BUILD_PLAN)

- **S1** `denyAppRemoval` prevents deletion; revoking Screen Time access needs the passcode.
- **S2** `TetherPush` can write `ManagedSettingsStore` + read the App Group + Keychain within its budget (shield changes <= 5 s after push with app force-quit). Also: Keychain readable from the NSE while locked (AfterFirstUnlock).
- **S3** ShieldAction can post a local notification; tapping it deep-links to the pause flow.
- **S4** Min DeviceActivity interval, max concurrent activities (constants `ActivityScheduler.minIntervalMinutes/maxActivities`); whether re-registering a *running* activity re-fires `intervalDidStart` (we avoid it with `activitySignatures.json`).
- **S5** `webContent.blockedByFilter = .specific` with 50 domains alongside `shield.webDomains`.
- **S6** Monitor memory < 6 MB with TetherCore + TetherKit linked.

## VERIFY list (every `// VERIFY:` in the code)

W8 (docs/reviews/W8-apple-api-audit.md) audited every item below; signature items it is confident about are marked "W8-audited" in code.

1. `ShieldApplier.swift` — `ManagedSettingsStore.Name("tether.block")` initializer form. (W8: matches SDK.)
2. `ShieldApplier.swift` — `ActivityCategoryPolicy.specific(_:except:)` default `except`; assigning to `shield.applicationCategories` and `shield.webDomainCategories`. (W8: matches SDK.)
3. `ShieldApplier.swift` — S5: 50-domain cap, coexistence of `webContent.blockedByFilter` and `shield.webDomains`; **per-store 50-token cap** on `shield.applications`/`shield.webDomains` (W8 shards tokens over `tether.block`, `tether.block.1…3`).
4. `ShieldApplier.swift` (`TamperLock`) — S1: `application.denyAppRemoval` semantics (we set `true` / `nil`).
5. `ShieldContext.swift` — token `JSONEncoder` output is stable across processes (used as lookup key between app and shield extensions).
6. `ActivityScheduler.swift` — S4 limits (20 activities, 15 min). (Signatures: W8-audited.) One-shots are now named `tether.t.<epochSeconds>` and decomposed with the *device* calendar.
7. `ActivityScheduler.swift` — `DeviceActivityEvent(…, threshold:, includesPastActivity: true)` on iOS 17.4+ (label to confirm), old init below 17.4.
8. `NotificationRouter.swift` / `TetherShieldActionExtension.swift` — S3: posting from the extension, deep link.
9. `AuthorizationManager.swift` — `AuthorizationCenter.shared.$authorizationStatus` publisher; `requestAuthorization(for: FamilyControlsMember)`.
10. `Keychain.swift` — keychain access group entitlement in every target (otherwise -34018).
11. `ProtectionController.swift` — `clearAllSettings()` is synchronous.
12. `ReportContexts.swift` — `DeviceActivityReport.Context(_:)` initializer. (W8: matches Apple's template.)
13. `TotalActivityReport.swift` — nested AsyncSequence shape (`activitySegments`, `categories`, `applications`, `localizedDisplayName`, `bundleIdentifier`). (W8: matches SDK; confirm on device.)
14. `TetherShieldConfigurationExtension.swift` — `ShieldConfiguration.init` labels/order; `Label(text:color:)`. (W8: matches SDK.)
15. `TetherNotificationService.swift` — S2.
16. `TetherMonitorExtension.swift` — S6.
