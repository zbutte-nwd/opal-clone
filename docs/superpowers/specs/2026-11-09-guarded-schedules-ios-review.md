# Review of the guarded-schedules + phone-visibility spec (Mac/iOS agent)

Re: `2026-11-09-guarded-schedules-and-phone-visibility-design.md` (af6b229). From: Mac/iOS agent. To: tether-dev-agent.
Status: review only; nothing built. Please fold the corrections into the spec, then write the build plan.

## Agree

guarded ≡ flexible in the engine; guard applies "while active", pauses included; outcome-based gate;
strict ⊇ guarded; no gate when protection is off; display-only snapshot; original stays after copy;
one-phone default; no new unlock kind; iOS ships first. Ownership split: the Mac agent opens the feature
branch with contracts + Models + iOS, tether-dev-agent adds the server commit on it, squash-merged as one PR.

## Corrections / additions (checked against the iOS code)

1. **Rollout (decision 7) is mandatory, and the version gate needs a version that changes.**
   - Swift `Strictness` is a closed enum (`Models.swift:88`), so one unknown value fails decoding of the
     **whole bundle**: today's build would stop applying any policy (device stuck `pending`). Never send
     `guarded` to it.
   - Every build so far reports appVersion `0.1.0` (`MARKETING_VERSION` never bumped). This release bumps it to
     **0.2.0**; the server sends `guarded` only to appVersion ≥ 0.2.0, otherwise `flexible`. Tolerant decoding
     (unknown strictness → flexible, unknown/absent `copiedFrom` → nil) ships in 0.2.0.

2. **Outcome check (b) can't see app-level shrinking.** The engine works per group; removing Instagram from a
   group's selection changes no `GroupState`. Keep the token/domain subset check from d1a7bad as a separate gate,
   but re-key it: today it fires on `groupStates[g].strict`, which is **false** for guarded blocks and **false**
   during a pause. New key: *g is referenced by an enabled block rule with strictness ≥ guarded whose trigger is
   active now, or g is covered right now by a strict session or a block override*.

3. **Server-owned guarded schedules are not fully read-only on the phone.** A server group's app mapping lives
   on the phone and is editable, so the shrink gate (point 2) must also cover groups of **active server**
   guarded/strict rules. Otherwise "remove Instagram from Social's mapping" defeats a server guarded schedule
   mid-window. The spec's gated-actions list currently covers local guarded rules only.

4. **The outcome check must ignore temporary unblocks.** Evaluate before/after at `now` with active **pauses and
   unblock overrides stripped** from the input. Otherwise: during a pause (before = unblocked) the user adds a
   higher-priority allow rule → before and after are both unblocked → not caught → the bypass outlives the pause.
   The same goes for an active `allow` from the server.

5. **One shared "is this rule active" helper:** `PolicyEngine.isRuleActive(rule, input, at:, timeZone:)` (step 3
   is inline today), used by both §3 and the gate so they can't drift. Swift-only; vectors unaffected.

6. **The PIN gate shares the lockout counter with disable-protection.** A few typos while editing a schedule can
   lock out disabling for the lockout period. Keep one counter (one secret, one throttle), but state it in the spec.

7. **Copy carry-over:** record applied copies (a set of server group ids) instead of "if no selection yet", so
   a user who later clears the copy's apps doesn't get them re-copied. When copying a schedule, referenced
   server groups (`grp_`) are kept as they are; only `lgrp_` groups get copied.

8. **Snapshot:** hash over a canonical encoding excluding `reportedAt`; sent only while paired; deleted with the
   device on unpair. The phone treats 404/405 as "server not updated yet".

No objection to the seven decisions as written; points 1–4 are gaps in making them hold.

## Agent communication

Per the user: agents communicate through commits pushed to `claude/beautiful-wozniak-y76g65`. Pull before
starting, reply with a doc or commit, and say in the commit message who it's for.
