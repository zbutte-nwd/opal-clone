# M1 — on-device spikes & findings

Device: iPhone 17 Pro, iOS 26.6 (23G71). Xcode 26.5. Team W6Y8QLHYZ3.

## Findings outside the S1–S6 table

### F1 — DeviceActivityCenter called from a Monitor callback deadlocks (fixed)

**Seen:** enabling protection (PIN lock) froze the app; the watchdog killed it (`0x8BADF00D`), and
every relaunch froze again. iOS also wrote `unblock_deadlock_UsageTrackingAgent-*.ips`:

```
Deadlock cycle: TetherMonitor [NSXPCConnection.user.endpoint] -> UsageTrackingAgent [NSManagedObjectContext]
                -> TetherMonitor
Blocked: Tether (main thread, in ActivityScheduler.schedule -> startMonitoring), TetherMonitor, UsageTrackingAgent
```

**Cause:** registering `tether.daily` (00:00–23:59) starts its interval immediately, so the agent
calls `intervalDidStart` while holding its store; the Monitor reconciled and called
`DeviceActivityCenter` synchronously back into the agent.

**Rule:** never call `DeviceActivityCenter` (`activities`, `startMonitoring`, `stopMonitoring`)
synchronously from a DeviceActivityMonitor callback, nor on the app's main thread.

**Fix:** `ActivityScheduler` runs all DeviceActivityCenter work on one process-wide serial queue
(`schedule` / `stopAll` return immediately). Shields still apply synchronously in `reconcile`.
Open question for S6: whether the Monitor process lives long enough to drain the queue after the
callback returns (verify that one-shot transitions keep chaining with the app force-quit).

### F2 — false "revoked" on the dashboard after background launches (fixed)

**Seen:** the server briefly showed the iPhone as `revoked` (ack `authorizationStatus` ≠ approved),
clearing on the next check. Protection was on and Screen Time approved throughout.

**Cause:** acks read `AuthorizationCenter.authorizationStatus` live. Right after a cold/background
launch, and in the push NSE (which syncs from a background launch), it can read `.notDetermined`.
`AuthorizationManager` already ignored that blip for its own events, but the ack sent it.

**Fix:** acks use `AuthorizationManager.reportableStatusValue()`: on `.notDetermined` with a
definite status previously recorded by the app, extensions report the recorded status; the app
re-reads for up to 3 s, then reports what it sees (a lasting revocation still reaches the server).
Open: what a real revocation reads as (`.denied` vs `.notDetermined`) — spike S1.

## S1–S6

Not run yet.
