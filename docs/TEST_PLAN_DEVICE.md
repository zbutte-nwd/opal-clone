# On-device test plan (phase M3)

Run on a **physical iPhone, iOS 17+** (ideally also iOS 18) with Developer Mode on. FamilyControls
and shielding do not work in the Simulator. Prerequisites: M1 spikes S1–S6 done, app installed from
Xcode with a dev team, a running server (`scripts/dev-server.sh`, reachable from the phone; set
`TETHER_SERVER_URL` in `ios/Config/Local.xcconfig` to `http:/$()/<LAN-IP>:8787` or a deployed URL),
a test iPhone with a Screen Time passcode set, and a second device/laptop with the admin dashboard.
Test apps: pick 2 throwaway apps (A, B) and 1 website (e.g. example.org) per group.

Conventions: "locked" = screen off; "force-quit" = swiped away in app switcher; times are
device-local. Record each case in the results table at the end.

## A. Authorization

| # | Case | Steps | Expected |
|---|---|---|---|
| A1 | Individual authorization | Fresh install; onboarding -> Enable protection; accept the system prompt | Status = approved; no crash; `authorizationStatus` visible in Settings screen; device shows approved on dashboard |
| A2 | Child authorization | Use a child account in Family Sharing (guardian device available); choose Child mode | Guardian approval requested on guardian device; after approval status approved; removal/revoke now needs guardian |
| A3 | Denial path | At the system prompt, cancel / deny | App shows non-blocking explanation + Retry; no shields applied; no crash loops; app still opens |
| A4 | Revoked while running | Approve, then revoke in Settings > Screen Time > Apps with Screen Time Access | App detects on foreground (and Monitor reconcile); UI shows protection off; tamper event queued |

## B. Picker, groups

| # | Case | Steps | Expected |
|---|---|---|---|
| B1 | Picker and mapping | Open group "Social"; pick app A, app B, a category, website | Selection saved; reopen app -> selection persists; group shows counts |
| B2 | Server group mapping | Create group on dashboard; on device the group appears as "unmapped"; map via picker | Mapping stored locally only; server never receives app identities (inspect server DB/log) |
| B3 | Large selection | Pick 30+ apps/categories | No hang; Monitor still fires (watch memory, see N) |
| B4 | Website domains (S5) | Add 50 domains via server group + picker web token | Both apply in Safari; blocked page shows shield |

## C. Schedules

| # | Case | Steps | Expected |
|---|---|---|---|
| C1 | Schedule starts, app closed | Rule 10 min ahead; force-quit Tether; lock phone | At start, app A shows shield without opening Tether (+/- 1 min) |
| C2 | Schedule ends | Wait for end time | Shield removed; A opens |
| C3 | Overnight schedule | 22:00 -> 06:00 weekdays; test with a shortened 23:50 -> 00:10 window | Block spans midnight; correct weekday attribution; ends at 00:10 |
| C4 | DST transition | Set device time zone to one with DST change (or manually set date across the change) with a schedule over the transition | Block starts/ends at wall-clock times; no double or missing block; note actual behavior |
| C5 | Time zone change | Travel simulation: change time zone mid-day | Schedules re-evaluate in new local time after reconcile |
| C6 | Short interval limit (S4) | Create 5, 10, 15, 20 min schedules | Record minimum accepted; app handles failure with a visible error |
| C7 | Activity count (S4) | Create rules until 20+ monitored activities | Record the cap; TransitionPlanner stays within it; no silent drops |

## D. Focus sessions and pause

| # | Case | Steps | Expected |
|---|---|---|---|
| D1 | Normal focus session | Start 15-min session | Selected groups shielded immediately; early end allowed; stats update |
| D2 | Strict focus session | Start strict session | No end-early control; PIN/partner required to cancel per lock mode; session ends on time with app force-quit |
| D3 | Pause | During a block tap shield secondary action / Pause; 5-min pause | Apps usable 5 min; countdown correct |
| D4 | Pause re-block, locked/offline | Pause 5 min, lock phone, enable airplane mode | After 5 min the shield returns without opening Tether or network |
| D5 | Pause budget | Daily pause budget 10 min; take 2 x 5 min pauses; try third | Third denied with budget message; budget resets next day |
| D6 | Pause on strict | Try pause during strict session | Disallowed |

## E. Usage limits

| # | Case | Steps | Expected |
|---|---|---|---|
| E1 | Threshold | Limit 5 min/day on app A; use A for 5 min | `eventDidReachThreshold` -> shield appears while using A; Tether closed |
| E2 | Daily reset | Next day (or change date) | Limit resets, shield removed |
| E3 | Multiple thresholds | Two groups with different limits | Each fires independently |

## F. Shield UI (S3)

| # | Case | Steps | Expected |
|---|---|---|---|
| F1 | Custom copy | Trigger shield for each reason (schedule, session, limit, remote) | Title/subtitle/icon/colors match reason; light/dark OK |
| F2 | Buttons | Tap primary and secondary | Primary closes; secondary "Unlock for N min" -> local notification posted |
| F3 | Notification deep link | Tap that notification | Opens `tether://pause?group=<id>` -> pause screen on correct group (S3 pass criterion) |
| F4 | Fallback | If F2 fails | Secondary says "Open Tether to pause"; document result |

## G. Server pairing and remote control

| # | Case | Steps | Expected |
|---|---|---|---|
| G1 | Pairing code | `scripts/new-pairing-code.sh`; enter code in app | Device appears on dashboard, status online; policy synced |
| G2 | QR / deep link | Open `tether://pair?code=...&server=...` from Notes | App opens on pairing screen prefilled |
| G3 | Bad/expired/reused code | Use code after 10 min and after use | Clear errors; no pairing |
| G4 | Remote block latency (S2) | Force-quit app; lock phone; dashboard -> block group now | Shield on A within 5 s (NSE path); record seconds over 10 runs |
| G5 | Remote unblock | Same, unblock | Shield removed; dashboard `appliedVersion` = latest |
| G6 | Silent push fallback | Disable NSE path (debug flag) or alert off | Silent push/BG refresh applies within minutes; foreground applies immediately |
| G7 | Timed unblock offline | Dashboard: unblock 10 min; then airplane mode | Re-block after 10 min offline, app force-quit |
| G8 | Offline policy | Airplane mode all day with rules | Schedules/limits keep working from local policy |
| G9 | Unpair | Delete device on dashboard | Device returns to local-only mode with explanation; local rules per design |

## H. Unlock requests

| # | Case | Steps | Expected |
|---|---|---|---|
| H1 | Group unlock request | Request unlock for group with reason | Appears in dashboard list; approve -> unblocked for approved duration, re-block offline at end |
| H2 | Deny | Deny request | Device notified, stays blocked |
| H3 | disableProtection request | Request to disable protection (remoteApproval mode) | Pending until admin approves; then protection off and event logged |
| H4 | Expiry | Leave request pending past TTL | Marked expired both sides |

## I. Protection lock and tamper (S1)

| # | Case | Steps | Expected |
|---|---|---|---|
| I1 | partnerPIN correct | Settings -> Disable protection -> correct PIN | Allowed |
| I2 | Wrong PIN lockout | Enter wrong PIN repeatedly | Escalating lockout after N attempts; survives app relaunch/reboot; attempts not resettable by reinstall of state |
| I3 | remoteApproval mode | Disable attempt | Request sent; no local bypass |
| I4 | osOnly mode | Look for disable control | None in-app |
| I5 | denyAppRemoval (S1) | Long-press app -> Delete | Delete option absent/blocked while protection on |
| I6 | Settings revocation (S1) | With Screen Time passcode set: Settings -> Screen Time -> revoke Tether | Requires Screen Time passcode. Without passcode set -> document |
| I7 | Child-mode revoke | Same as I6 on child device | Needs guardian approval |
| I8 | Tamper reporting | Revoke authorization (use a device without passcode); wait | Dashboard shows `authorizationRevoked` event and device status `revoked`/`stale`; admin notified |
| I9 | Stale device | Power off/airplane >24 h (or lower threshold on test server) | Dashboard flags `stale` |
| I10 | No biometrics | Search UI flows | Face ID/Touch ID never prompted anywhere |

## J. System behavior

| # | Case | Steps | Expected |
|---|---|---|---|
| J1 | Reboot persistence | Active schedule/pause; reboot; do not unlock for a while | Shields persist across reboot; schedules fire; state file readable after first unlock (note any "before first unlock" issue) |
| J2 | Low Power Mode | Enable LPM during schedule boundary | Schedule start/end still fire (may be delayed); record delays |
| J3 | iOS update | Update iOS minor/major on test device | After update protection still active; re-authorize needed? Record. Note any new API behavior |
| J4 | Reinstall/upgrade | Install new build over old | Policy/state preserved via App Group; no duplicate monitors |
| J5 | Date/time manipulation | Change device date manually (Automatic off) | Block not trivially bypassed beyond what iOS allows; document |
| J6 | Notifications permission denied | Deny notifications | Shield/NSE path degraded gracefully; UI explains |
| J7 | Multiple devices | Pair 2 phones | Independent states; dashboard correct per device |

## K. Memory and performance (S6)

| # | Case | Steps | Expected |
|---|---|---|---|
| K1 | Monitor memory | Instruments (Allocations / Activity Monitor) attach to TetherMonitor during `intervalDidStart` with big selection | Peak < 6 MB; no jetsam in Console (`process:TetherMonitor`) |
| K2 | ShieldConfig / ShieldAction memory | Trigger shield repeatedly | Under extension limits; no crash reports |
| K3 | NSE budget | Time TetherPush work | Completes < 30 s limit; target < 5 s |
| K4 | Battery | 24 h run | No abnormal drain (Settings > Battery) |

## Results table template

Copy per run.

```
Device: ______ iOS: ____ Build: ____ (git sha) Server: ____ Tester: ____ Date: ____
```

| Case | Result (PASS/FAIL/N-A) | Measured value | Notes / bug link |
|---|---|---|---|
| A1 | | | |
| A2 | | | |
| A3 | | | |
| A4 | | | |
| B1 | | | |
| B2 | | | |
| B3 | | | |
| B4 | | | |
| C1 | | | |
| C2 | | | |
| C3 | | | |
| C4 | | | |
| C5 | | | |
| C6 | | | |
| C7 | | | |
| D1 | | | |
| D2 | | | |
| D3 | | | |
| D4 | | | |
| D5 | | | |
| D6 | | | |
| E1 | | | |
| E2 | | | |
| E3 | | | |
| F1 | | | |
| F2 | | | |
| F3 | | | |
| F4 | | | |
| G1 | | | |
| G2 | | | |
| G3 | | | |
| G4 | | | |
| G5 | | | |
| G6 | | | |
| G7 | | | |
| G8 | | | |
| G9 | | | |
| H1 | | | |
| H2 | | | |
| H3 | | | |
| H4 | | | |
| I1 | | | |
| I2 | | | |
| I3 | | | |
| I4 | | | |
| I5 | | | |
| I6 | | | |
| I7 | | | |
| I8 | | | |
| I9 | | | |
| I10 | | | |
| J1 | | | |
| J2 | | | |
| J3 | | | |
| J4 | | | |
| J5 | | | |
| J6 | | | |
| J7 | | | |
| K1 | | | |
| K2 | | | |
| K3 | | | |
| K4 | | | |

## Results

### Run 1 — 2026-11-09 (partial: server/remote path)

```
Device: iPhone 17 Pro  iOS: 26.6 (23G71)  Build: 4a68044..80bf0b7 (Debug, Family Controls Development)
Server: workstation (Windows, Node 24) via tailscale serve :47443, APNs sandbox  Tester: Zakir + agents  Date: 2026-11-09
```

| Case | Result | Measured value | Notes / bug link |
|---|---|---|---|
| G1 | PASS (after fix) | | First attempt failed: field left empty → build-default URL pointed at another service (401). Fixed by setting `TETHER_SERVER_URL` in Local.xcconfig; pairing errors now name the URL tried + likely cause. |
| G4 | PASS (web) | applied in ≤ 2 s | Override on a website-only group (example.com) blocked it in Safari, 00:58–01:02 PT, ended on time. Also blocked in Chrome for iOS. Apps in server groups not yet tested (none picked). |
| G5 | PASS | immediate | Ending a block early via MCP `end` cleared it on the phone immediately. |
| G6 | PASS (push) | ~1–2 s | Changes applied within seconds; device acked latest version. Cold background launch by push (Tether + NSE not running) ×3: applied in ~1 s, ack status `approved` each time (verifies M1 F2 fix). |
| H3 | PASS | | remoteApproval: phone request → server approve → `protectionDisabled` (method remoteApproval). Phone sent two identical requests ~90 s apart (screen reopened while waiting) — fixed: pending request id now persists and polling resumes. |
| I1 | PASS | | partnerPIN disable and re-enable. |
| — | NOT TESTED | | Apps chosen in a server-created group; usage limits (E); schedules (C); S1 passcode gate. |

Bugs found and fixed this run: false `revoked` on server after background launch (M1 F2); generic pairing
error text; duplicate disable-protection requests.

### Run 2 — 2026-11-09 (guarded schedules + phone visibility/copy, plan Task 11)

```
Device: iPhone 17 Pro  iOS: 26.6  Build: app 0.2.0 (feature/guarded-and-visibility)
Server: workstation, deployed 75a1901 (feature branch)  Effective lock: remoteApproval  Tester: Zakir + Mac agent  Date: 2026-11-09 ~05:05 PT
```

| Check | Result | Notes |
|---|---|---|
| (4) phone-made section in MCP status | PASS | Within a minute of the app being opened: groups with counts only (Socials: 3 apps, 1 site), local schedules incl. two guarded. Server picked up appVersion 0.2.0 from the User-Agent without re-pairing. |
| (5) copy_from_phone group | PASS | Server copy "Socials" applied by the phone within seconds (app closed, NSE path); it showed the 3 apps + site without re-picking; the original under "Yours" was untouched. |
| (3) shrink a group of an active **server** guarded schedule | PASS | Temporary server rule "Task 11 test" (guarded, Mon 05:00–06:00) on the copy; removing an app from its mapping was refused. Rule removed after the test. |
| (2) active **local** guarded schedule locked | PASS | "Mornings" (05:00–10:00, active): disable/edit/delete refused with the remoteApproval message. |
| (2) after hours it's free | PASS | "Nights" (22:00–05:00, inactive) edited normally. |
| (1) guarded still pauses | PASS | Paused Socials under "Mornings" (1 pause/day). |
| (6) app < 0.2.0 with a guarded rule | N/A | No 0.1.0 device left; covered by server tests (bundle downgrades guarded→flexible for appVersion < 0.2.0). |
| partnerPIN prompt path | NOT TESTED | Effective lock is remoteApproval (server setting); the PIN sheet needs partnerPIN. |

All suites green on the branch: contracts + 63 vectors, Swift 169, server 119, admin 22.
