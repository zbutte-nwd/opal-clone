# Platform Constraints — what iOS actually allows

This document is the "physics" of the project. Every feature in `FEATURE_MAP.md` is
designed around these limits. Items marked **[VERIFY]** must be confirmed on a real
device by the Mac agent (see `BUILD_PLAN.md`, Phase M1 "spikes") before the dependent
feature is considered done.

## 1. The only way to block apps on iOS: Apple's Screen Time API

Third-party apps cannot kill, hide, or intercept other apps. The only sanctioned
mechanism (and what Opal, one sec, Freedom etc. use) is the Screen Time API, iOS 16+:

| Framework | What we use it for |
|---|---|
| `FamilyControls` | `AuthorizationCenter` (permission), `FamilyActivityPicker` (user picks apps/sites/categories), `FamilyActivitySelection` (opaque tokens) |
| `ManagedSettings` | `ManagedSettingsStore` — applying shields (`shield.applications`, `shield.applicationCategories`, `shield.webDomains`, `shield.webDomainCategories`), `webContent.blockedByFilter`, `application.denyAppRemoval` |
| `ManagedSettingsUI` | `ShieldConfigurationDataSource` — custom look of the "this app is blocked" screen |
| `DeviceActivity` | `DeviceActivityCenter` / `DeviceActivitySchedule` / `DeviceActivityEvent` — OS wakes our **Monitor extension** at schedule boundaries and usage thresholds, even when the app is not running |
| `DeviceActivity` (report) | `DeviceActivityReport` extension — renders usage stats (sandboxed, no network, data can't leave it) |

Consequences:

- **Minimum iOS: 16.0** (individual authorization). We target **iOS 17.0** for
  better extension stability and `@Observable`.
- **Physical device only.** FamilyControls authorization and shielding do not work in
  the Simulator. UI can be previewed in the Simulator with the platform layer stubbed.
- **Entitlement `com.apple.developer.family-controls`** is required on the app *and every
  extension*. Development builds can use it immediately. **Distribution (TestFlight /
  App Store) requires Apple's approval**, requested per bundle ID at
  <https://developer.apple.com/contact/request/family-controls-distribution>. Request
  it early — approval can take weeks. Six bundle IDs need it (app + 5 extensions).

## 2. Apps are opaque tokens — the server can never name an app

`FamilyActivityPicker` returns `ApplicationToken`, `ActivityCategoryToken`,
`WebDomainToken`. They are opaque, device-specific and cannot be created from a bundle ID
in individual mode. The server therefore **cannot** say "block com.zhiliaoapp.musically".

**Design consequence — Groups:** the server defines *groups* by ID and name ("Social",
"Games"). On each device, the user (or a guardian holding the phone) maps each group to a
local `FamilyActivitySelection` using the picker. The server then blocks/unblocks
*groups*. Server policy never contains app identities.

**Websites are the exception:** `webContent.blockedByFilter = .specific(Set<WebDomain>)`
accepts plain domain strings, so the server **can** push website domains directly
(`group.webDomains`). Limit: **50 domains** for the specific filter **[VERIFY]**. Picker
web tokens and server domain strings are combined.

## 3. The Screen Time passcode requirement (the user's key ask)

> "The app should be enabled or disabled with the Screen Time passcode, not Face ID."

**There is no API for a third-party app to prompt for, read, or verify the Screen Time
passcode.** What *is* achievable — and gets the same practical result:

### 3a. Make the Screen Time passcode the gatekeeper at the OS level

1. When the app requests `.individual` authorization, iOS shows its own prompt
   (Apple-ID / device auth — we don't control it). This happens **once**, at enable time.
2. The app sets `ManagedSettingsStore().application.denyAppRemoval = true` (the
   "tamper-lock" store). The app (and every app) can no longer be deleted while protection
   is on.
3. Onboarding walks the user through setting a **Screen Time passcode** in
   Settings → Screen Time (ideally entered by an accountability partner/guardian so the
   user doesn't know it) and turning on Content & Privacy Restrictions →
   **Account Changes: Don't Allow** and **Passcode Changes: Don't Allow** (prevents
   signing out of iCloud, which would revoke authorization).
4. With a Screen Time passcode set, revoking our app's Screen Time access in
   Settings → Screen Time requires that passcode **[VERIFY — spike S1]**. Turning
   Screen Time off entirely also requires it.

Result: **disabling protection at the OS level requires the Screen Time passcode.** Face
ID is never used by our app.

### 3b. Disabling from inside the app

Because we cannot check the Screen Time passcode in-app, in-app "Disable protection"
(and loosening any rule) is gated by one of these, chosen at setup (`ProtectionLock`):

| Mode | How in-app disable works | Who it's for |
|---|---|---|
| `partnerPIN` (default) | A 6–8 digit **Tether PIN** set by the partner at setup (hashed with PBKDF2 in Keychain). Recommended: partner uses the **same number as the Screen Time passcode** so there is one secret. | Self-improvers with a partner |
| `remoteApproval` | Request goes to the server; admin approves in dashboard / push. | Parent/employer managed devices |
| `osOnly` | No in-app disable at all; user must revoke in Settings (Screen Time passcode). | Maximum strictness |

None of these use Face ID / biometrics. (`LAContext` is never used.)

### 3c. Strongest option: `.child` authorization (Family Sharing)

If the device user is a **child member of a Family Sharing group** (under 18),
`requestAuthorization(for: .child)` makes a guardian approve on *their* device; the app
then **cannot be deleted or have access revoked without the guardian's Screen Time
passcode/approval**, enforced by iOS. Adults cannot use `.child`. We support both modes.

### 3d. Tamper detection

Whatever iOS lets through, we detect and report: the app observes
`AuthorizationCenter.shared.authorizationStatus`, and the Monitor extension
reconciles state periodically. If authorization goes away (or the device stops
checking in), the device reports `authorizationRevoked` / the server flags
`stale` and notifies the admin.

## 4. Running code in the background

| Need | Mechanism | Notes |
|---|---|---|
| Time-based block/unblock with app closed | `DeviceActivitySchedule` → Monitor extension `intervalDidStart/End` | Reliable. Schedules must be **≥ 15 min** long **[VERIFY]**. Max ~**20 monitored activities** at once **[VERIFY]**. Monitor extension memory limit **~6 MB** — keep it lean (no big deps). |
| Usage-limit triggers ("30 min of Social/day") | `DeviceActivityEvent(applications:categories:webDomains:threshold:)` → `eventDidReachThreshold` | Needs tokens, so only works for picker-mapped groups. |
| Server-initiated block/unblock *now* | APNs push. Primary: **alert push with `mutable-content` → Notification Service Extension applies policy** **[VERIFY — spike S2: ManagedSettingsStore writable from NSE with entitlement]**. Secondary: silent background push (`content-available`) → app. Tertiary: BGAppRefresh + every foreground. | Silent pushes are throttled and are not delivered if the user force-quit the app. That's why NSE is the primary path. |
| Timed server commands ("unblock for 30 min") | Delivered *ahead of time* with `endsAt`; device registers a DeviceActivity schedule for `endsAt` so re-block happens **offline** | Never depend on a second push to restore a block. |

**Rule: every block must be restorable without the network.** The device always holds the
full policy and computes state locally (`TetherCore` engine). The server only edits policy.

## 5. Shield screen limits

- `ShieldConfigurationDataSource` customizes title/subtitle/icon/colors/two buttons. No
  arbitrary SwiftUI.
- `ShieldActionDelegate` handles button taps: can only return `.close`, `.defer`, `.none`.
  It **cannot open our app**. Pattern for "Unlock for 5 min": shield action posts a
  **local notification**; tapping it opens the app to the pause flow (deep link
  `tether://pause?group=...`). **[VERIFY — spike S3: notification posting from
  ShieldAction extension]**.

## 6. Data sharing between app and extensions

- One **App Group** (`group.$(BUNDLE_ID_PREFIX).tether`) container holds
  `state.json` (see ARCHITECTURE.md §4). All targets read/write it through
  `TetherCore.StateStore` with file coordination.
- `FamilyActivitySelection` is `Codable` → stored in the same container.
- Keychain access group shared for the device API token.
- `DeviceActivityReport` extension can read the App Group, but data it computes from
  usage **cannot be sent out** (Apple sandbox). So usage numbers on the server dashboard
  are limited to what the app itself can know (focus-session minutes, block counts,
  pause counts) — not per-app screen time. This is an Apple privacy rule, not a choice.

## 7. Things we explicitly will NOT do

- No VPN / DNS-proxy based blocking (different entitlement, App Review risk). Possible
  future add-on (`NEFilterDataProvider` requires supervised devices for full effect).
- No MDM. (MDM could enforce more, but requires supervised devices — out of scope.)
- No private APIs, no jailbreak detection theater.
