# Tether server

Node 22 + TypeScript + Fastify 5 + SQLite (better-sqlite3). Implements `contracts/api.md`
(see `openapi.yaml`), the policy bundle builder, APNs sender, and a TS port of the policy engine.

```bash
cd server
npm install
npm run dev            # http://localhost:8787  (tsx watch)
npm test               # vitest (includes all 61 engine vectors + bundle schema validation)
npm run typecheck
npm run openapi:check  # every route must be in openapi.yaml
npm run seed           # demo@tether.local / tether-demo + groups/rules + a fresh pairing code
npm run build && npm start
```

## Environment

| Var | Default | Notes |
|---|---|---|
| `PORT` | `8787` | |
| `DATABASE_PATH` | `./data/tether.db` | SQLite file (WAL). Put on a volume. |
| `JWT_SECRET` | dev default | **Required when `NODE_ENV=production`.** `openssl rand -base64 48` |
| `PUBLIC_BASE_URL` | request host | Server origin (no `/v1`) used in pairing `qrPayload` and enroll `baseURL`. |
| `APNS_KEY_P8` | unset | `.p8` PEM contents **or** a file path |
| `APNS_KEY_ID`, `APNS_TEAM_ID` | unset | From the Apple developer portal |
| `APNS_TOPIC` | unset | App bundle id (e.g. `com.newwestsite.tether`) |
| `APNS_ENV` | `sandbox` | Fallback environment; each device reports its own via `PUT /devices/me/push-token` |
| `ALLOW_REGISTRATION` | `true` | Set `false` after creating your admin |
| `TRUST_PROXY` | `false` | `true` behind Fly/nginx so rate limits use the real client IP |
| `ADMIN_DIST` | `../admin/dist` | Served at `/` (SPA fallback) when it contains `index.html` |
| `LOG_LEVEL` | `info` | |

Without all four `APNS_*` vars a logging **mock transport** is used (pushes are logged, not sent).

### APNs key
1. Apple Developer, Certificates, Identifiers & Profiles, Keys: create a key with **Apple Push Notifications service (APNs)**; download `AuthKey_<KEYID>.p8` once.
2. `APNS_KEY_ID=<KEYID>`, `APNS_TEAM_ID=<your team id>`, `APNS_TOPIC=<app bundle id>`, `APNS_KEY_P8=/path/AuthKey_<KEYID>.p8` (or paste the PEM). Use `fly secrets set APNS_KEY_P8="$(cat AuthKey_X.p8)"`.
3. Debug builds register sandbox tokens, TestFlight/App Store builds production tokens; the device sends which one.

Every policy change sends an `alert` push (`mutable-content: 1`, for the Notification Service Extension) and a
`background` push (`content-available: 1`, priority 5), both with `apns-collapse-id: policy`, debounced 500 ms per
device, with the bundle inlined when < 3000 bytes. HTTP 410 / `BadDeviceToken` clears the stored token.

## MCP endpoint (agents)

`POST /mcp` — Model Context Protocol, Streamable HTTP, stateless, JSON responses; `Authorization: Bearer tk_live_…`.
Tools (`src/mcp.ts`): `status`, `block`, `allow`, `end`, `create_group`, `update_group`, `delete_group`,
`add_schedule`, `remove_schedule`, `set_mode`, `update_settings`, `pairing_code`, `unlock_requests`, `approve_unlock`, `deny_unlock`. Each calls the REST routes
in-process (`app.inject`), so behavior, audit and pushes match the API exactly. Workstation setup
(`npm run setup`, `npm run cli -- pair|apikey|info`, Windows task, `tailscale serve`): `../docs/WORKSTATION.md`.

## Curl examples

```bash
BASE=http://localhost:8787/v1
# 1. admin
TOKEN=$(curl -s $BASE/auth/login -H 'content-type: application/json' \
  -d '{"email":"demo@tether.local","password":"tether-demo"}' | jq -r .token)
# 2. pair a device (the iOS app scans qrPayload or you type the code)
curl -s -X POST $BASE/pairing-codes -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' -d '{"deviceName":"Kid iPhone"}'
#    what the app does:
curl -s -X POST $BASE/devices/enroll -H 'content-type: application/json' \
  -d '{"pairingCode":"K7Q2-M9XD","name":"Kid iPhone","model":"iPhone15,2","osVersion":"17.5","appVersion":"1.0"}'
#    -> {"deviceId":"dev_…","deviceToken":"td_…"}
curl -si $BASE/devices/me/policy -H "authorization: Bearer $DEVICE_TOKEN"                       # 200 + ETag "1"
curl -si $BASE/devices/me/policy -H "authorization: Bearer $DEVICE_TOKEN" -H 'if-none-match: "1"' # 304
# 3. block a group for an hour
GROUP=$(curl -s $BASE/groups -H "authorization: Bearer $TOKEN" | jq -r '.groups[] | select(.name=="Social") | .id')
curl -s -X POST $BASE/actions/block -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d "{\"groupIds\":[\"$GROUP\"],\"durationMinutes\":60}"
```

### Third-party automation (Home Assistant, Shortcuts, n8n, cron…)
Create an API key once (session login only; the key is shown once), then use it as a bearer token.
Keys have the admin's policy permissions but cannot manage keys.
```bash
curl -s -X POST $BASE/api-keys -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' -d '{"name":"home-assistant"}'
# -> {"id":"key_…","key":"tk_live_…"}
curl -X POST $BASE/actions/block   -H "authorization: Bearer tk_live_…" -H 'content-type: application/json' -d '{"groupIds":["grp_…"],"durationMinutes":45}'
curl -X POST $BASE/actions/unblock -H "authorization: Bearer tk_live_…" -H 'content-type: application/json' -d '{"groupIds":["grp_…"],"durationMinutes":15}'
```
Both create overrides (supreme over rules/sessions) targeting all devices (or `deviceIds`), bump the policy and push.

## Design notes
- **Versioning**: `bumpPolicy(ctx, adminId, deviceIds?)` (`src/policy/service.ts`) is the only path that increments a device's `latest_version`; the bundle `version`/ETag is that integer.
- **Time zone**: bundle `timeZone` = account setting (null = device local). Server-side `currentState` falls back to UTC when null (the server does not know device zones).
- **Privacy**: the server never stores app identities, only group names/domains/ids.
- **Status**: `revoked` > `stale` (>= 24 h) > `pending` (applied < latest for > 5 min) > `online` (< 15 min) / `idle`.
- **Maintenance** (every 5 min): marks stale devices (audit entry + `Notifier`, log impl; email is P1), expires unlock requests (24 h), prunes overrides ended > 1 day.
- **Docker**: `docker build -f server/Dockerfile -t tether .` from the repo root (copies `admin/dist` if you built it). Fly: see `fly.toml`.
- Single SQLite file: run exactly one instance.
