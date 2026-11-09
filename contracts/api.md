# Tether REST API v1 (contract)

Base URL: `https://<host>/v1`. JSON, camelCase. Timestamps RFC 3339 UTC (`2026-11-09T17:00:00Z`).
IDs are prefixed random strings: `adm_`, `dev_`, `grp_`, `rule_`, `ovr_`, `evt_`, `unl_`, `key_`.

Errors: `{ "error": { "code": "not_found", "message": "…" } }` with HTTP 400/401/403/404/409/422/429/500.
Codes: `bad_request`, `unauthorized`, `forbidden`, `not_found`, `conflict`, `validation_failed`, `rate_limited`, `internal`.

Auth schemes:
- **Admin**: `Authorization: Bearer <session JWT>` (from login) — dashboard.
- **API key**: `Authorization: Bearer tk_live_…` — automation; same permissions as admin for its account, but can't manage keys/admins.
- **Device**: `Authorization: Bearer td_…` — device endpoints only (`/devices/me/*`).

## Admin auth
| Method | Path | Body → Response |
|---|---|---|
| POST | `/auth/register` | `{email, password, name}` → `201 {admin, token}` |
| POST | `/auth/login` | `{email, password}` → `200 {admin, token}` |
| GET | `/auth/me` | → `{admin}` |

## Pairing & devices (admin)
| Method | Path | Notes |
|---|---|---|
| POST | `/pairing-codes` | `{deviceName?}` → `201 {code: "K7Q2-M9XD", expiresAt, qrPayload: "tether://pair?code=…&server=…"}` (10 min TTL, single use) |
| GET | `/devices` | → `{devices: [DeviceSummary]}` |
| GET | `/devices/:id` | → `DeviceDetail` (incl. `status`, `currentState: GroupState[]` computed server-side, `appliedVersion`, `latestVersion`, `lastSeenAt`, `authorizationStatus`, `local: {receivedAt, snapshot} \| null` — the phone's last read-only snapshot, see below) |
| PATCH | `/devices/:id` | `{name?}` |
| DELETE | `/devices/:id` | unpair |
| POST | `/devices/:id/push` | force a policy push (debug) |
| GET | `/devices/:id/events?limit=` | device events |

`DeviceSummary.status`: `online` (seen < 15 min), `idle` (< 24 h), `stale` (≥ 24 h), `revoked` (last authorizationStatus ≠ approved), `pending` (applied < latest for > 5 min).

## Policy objects (admin / API key) — account-scoped, every mutation bumps device policy versions
| Method | Path | Body |
|---|---|---|
| GET/POST | `/groups` | `{name, colorHex?, webDomains: string[], copiedFrom?: "lgrp_…"}` (`copiedFrom`: server copy of a phone-made group; the phone carries its app selection over once) |
| PATCH/DELETE | `/groups/:id` | |
| GET/POST | `/rules` | `Rule` without `id`/`source` (see policy-bundle.schema.json) |
| PATCH/DELETE | `/rules/:id` | partial `Rule` |
| POST | `/rules/:id/toggle` | `{active: bool}` — manual-trigger rules only |
| GET/POST | `/overrides` | `{groupIds, action: "block"|"unblock", startsAt?, endsAt?, durationMinutes?, reason?, deviceIds?}` (`startsAt` default now; `durationMinutes` sugar for `endsAt`; `deviceIds` default all) |
| DELETE | `/overrides/:id` | cancel (removes from bundles) |
| GET/PATCH | `/settings` | `{protectionLock, allowLocalRules, denyAppRemoval, timeZone?}` |

Convenience (E9 automation): `POST /actions/block {groupIds, durationMinutes?}` and
`POST /actions/unblock {groupIds, durationMinutes?}` → create overrides.

## Unlock requests
| Method | Path | Notes |
|---|---|---|
| GET | `/unlock-requests?status=pending` | admin |
| POST | `/unlock-requests/:id/approve` | `{minutes?}` → for `groups`: creates `unblock` override for that device, `endsAt = now+minutes`; for `disableProtection`: just marks approved + pushes `unlockDecided` |
| POST | `/unlock-requests/:id/deny` | `{note?}` |

## API keys (admin only)
`GET/POST /api-keys` (`{name}` → `{id, name, key}` shown once), `DELETE /api-keys/:id`.

## Device endpoints (device token)
| Method | Path | Body → Response |
|---|---|---|
| POST | `/devices/enroll` *(no auth)* | `{pairingCode, name, model, osVersion, appVersion}` → `201 {deviceId, deviceToken}` |
| PUT | `/devices/me/push-token` | `{token: hex, environment: "sandbox"|"production"}` → `204` |
| GET | `/devices/me/policy` | header `If-None-Match: "<version>"` → `200 PolicyBundle` + `ETag: "<version>"`, or `304` |
| POST | `/devices/me/ack` | `{version, appliedAt, blockedGroupIds: string[], authorizationStatus: "approved"|"denied"|"notDetermined", timeZone?: IANA}` → `204` |
| POST | `/devices/me/events` | `{events: [{id, type, occurredAt, data?}]}` → `202` (idempotent on event id) |
| POST | `/devices/me/unlock-requests` | `{kind: "groups"|"disableProtection", groupIds?, minutes?, reason?}` → `201 UnlockRequest` (`groupIds`+`minutes` required for `groups`) |
| GET | `/devices/me/unlock-requests/:id` | → `UnlockRequest` |
| DELETE | `/devices/me` | device-initiated unpair (only allowed when protection already disabled) |
| PUT | `/devices/me/local` | `DeviceLocalSnapshot` (`device-local.schema.json`) → `204` (stored, or same `hash` as stored: no write), `413` (body > 256 KB), `422` (schema) |

`UnlockRequest`: `{id, deviceId, kind, groupIds, minutes, reason, status: "pending"|"approved"|"denied"|"expired", createdAt, decidedAt?, overrideId?}`

- `kind: "groups"` approval → server creates an `unblock` override (`endsAt = now + minutes`) for that device → bundle bump → push.
- `kind: "disableProtection"` (Protection Lock `remoteApproval`) approval → no policy change; the device polls
  `GET /devices/me/unlock-requests/:id` (and receives a push `{"tether":{"type":"unlockDecided","requestId":…}}`)
  and, once `approved`, disables protection locally. Pending requests expire after 24 h.

## Push (server → APNs)
See ARCHITECTURE.md §7. `apns-push-type: alert` + `mutable-content: 1` (NSE path) for
every policy change; also a `background` push (`apns-priority: 5`). Inline bundle when
the serialized bundle < 3000 bytes.

## Health
`GET /healthz` → `{ok: true, version}`.

## Guarded rules & phone snapshot (app ≥ 0.2.0)
- `Rule.strictness: "guarded"` (block rules only) behaves like `flexible` in the engine; the app locks edits to the rule
  and shrinking of its groups while it is active. The server sends `guarded` only to devices whose `appVersion` is
  ≥ `0.2.0` (numeric semver compare); other devices get `flexible`. Apps < 0.2.0 fail to decode unknown strictness.
- `PUT /devices/me/local`: the app uploads a snapshot of phone-made state (local groups with **counts only**, local
  rules, sessions, pauses, protection settings) after local changes and on sync when its `hash` changed. Display only:
  never evaluated or edited by the server. Replaced, never merged; deleted with the device. Apps treat 404/405 as
  "server not updated yet" and retry on a later sync.
