# Workstation handoff — Tether server + MCP (for the Claude agent on the workstation PC)

**Scope: only `server/` and MCP connections.** Do not touch `ios/`, `admin/`, `contracts/` or
the docs for the iOS build; the iOS app is built and installed from the Mac. Don't run `make test`
(it needs Swift); the server's own tests are enough here.

What runs here: one Node process (`server/`, Fastify + SQLite, ~60 MB RAM) bound to `127.0.0.1:8787`,
published to the tailnet over HTTPS by `tailscale serve`. The iPhone and any agent on the tailnet reach
it at `https://<this-pc>.<tailnet>.ts.net`. Agents use the MCP endpoint `…/mcp`; the phone uses `…/v1`.

## 0. Ask the human for / check

1. **Node 22+** (`node -v`) and **git**. Windows: `winget install OpenJS.NodeJS.LTS Git.Git`.
2. **Tailscale** installed and logged in on this PC (`tailscale status`), same tailnet as the phone.
   HTTPS certificates must be enabled for the tailnet (admin console → DNS → HTTPS Certificates);
   the tailnet already has them on as of setup.
3. Optional now, needed for instant updates: the **APNs key** — `AuthKey_<KEYID>.p8` + Key ID, from
   developer.apple.com → Certificates, IDs & Profiles → Keys → "+" → Apple Push Notifications service.
   Team ID is `W6Y8QLHYZ3`, topic `com.newwestsite.tether` (setup fills both in). Without it the
   phone only picks up changes when Tether is opened. Store the .p8 **outside the repo**
   (e.g. `%USERPROFILE%\.tether\AuthKey_XXXX.p8`); never commit it.

## 1. Install & set up (once)

```powershell
git clone git@github.com:zbutte-nwd/opal-clone.git tether; cd tether\server   # private repo: needs the human's GitHub auth (gh auth login)
npm ci --ignore-scripts        # Windows: plain `npm ci` tries to compile better-sqlite3 (needs Visual Studio);
                               # the package already ships a Windows binary. Linux/macOS: plain `npm ci`.
npm test                       # must be green
npm run setup                  # add: -- --apns-key C:\path\AuthKey_X.p8 --apns-key-id X   (if you have it)
                               # non-default port: -- --url https://<pc>.<tailnet>.ts.net:<httpsPort>, and PORT=<n> in .env
```
`npm run setup` builds, writes `server\.env` (secret, gitignored: random `JWT_SECRET`, `HOST=127.0.0.1`,
`PUBLIC_BASE_URL` auto-detected from Tailscale, APNs vars), creates the admin account, an API key named
`claude`, and a phone pairing code. **The admin password and the API key are printed once** — give
them to the human right away; don't write them into any file in the repo. Re-running `setup` is safe
(it only fills missing `.env` keys and never creates a second admin).

## 2. Keep it running + publish on the tailnet

Windows (elevated PowerShell, in `server\`):
```powershell
powershell -ExecutionPolicy Bypass -File workstation\install-windows.ps1
tailscale serve --bg 8787       # persists across reboots; publishes https://<pc>.<tailnet>.ts.net/
# If 8787 or the root URL is taken, use other ports, e.g. PORT=47787 in .env and:
#   tailscale serve --bg --https=47443 http://127.0.0.1:47787
# then PUBLIC_BASE_URL (in .env) and every URL below carry :47443.
```
The task "Tether Server" starts at boot without a login, restarts if it exits, and logs to
`server\data\server.log`. Restart it with `install-windows.ps1 -Restart` (elevated), not
`Stop-/Start-ScheduledTask`: stopping the task only ends its `cmd.exe` wrapper, the node process keeps
the port and the new start can't bind.

Linux instead: a systemd user unit, then `loginctl enable-linger $USER`:
```ini
# ~/.config/systemd/user/tether.service
[Service]
WorkingDirectory=%h/tether/server
ExecStart=/usr/bin/node dist/index.js
Restart=always
[Install]
WantedBy=default.target
```
`systemctl --user enable --now tether && tailscale serve --bg 8787`

Verify from this PC: `curl https://<this-pc>.<tailnet>.ts.net/healthz` → `{"ok":true,...}`
(`npm run cli -- info` prints the URL).

## 3. Connect agents (MCP)

Endpoint `https://<this-pc>.<tailnet>.ts.net/mcp`, transport **Streamable HTTP**, header
`Authorization: Bearer tk_live_…`. One API key per agent so they can be revoked separately:
```powershell
npm run cli -- apikey grokbot   # prints the key + the exact `claude mcp add` line
```
- **Claude Code** (on this PC, the Mac, anywhere on the tailnet):
  `claude mcp add --transport http --scope user tether https://<pc>.<tailnet>.ts.net/mcp --header "Authorization: Bearer <key>"`
- **Other clients (Grok bot etc.)**: any MCP client that supports remote HTTP servers with a custom
  header. It must run on a machine in the tailnet (the server is not on the public internet).

Tools: `status` (call first), `block` (session now / one-off time block), `allow`, `end`,
`create_group`, `update_group`, `delete_group`, `add_schedule`, `remove_schedule`, `set_mode`,
`update_settings`, `pairing_code`, `unlock_requests`, `approve_unlock`, `deny_unlock`. Times are `HH:mm`, minutes, or ISO 8601, in the phone's time zone.

## 4. Pair the phone

`npm run cli -- pair` → code. On the iPhone: Tether → Settings → Server → enter the code, and under
"Advanced" the server URL `https://<this-pc>.<tailnet>.ts.net`. Then `npm run cli -- info` should list
the device. Groups created by the server show "Choose apps for …" on the phone — app choices stay on
the phone (Apple privacy rule); the server only knows group names and websites.

## 5. Operate

| Task | Command (in `server\`) |
|---|---|
| Health / devices / keys | `npm run cli -- info` |
| New pairing code | `npm run cli -- pair` |
| New agent key | `npm run cli -- apikey <name>` |
| Revoke a key | admin dashboard, or `DELETE /v1/api-keys/:id` with an admin login |
| Add APNs later | `npm run setup -- --apns-key <file.p8> --apns-key-id <id>` then restart |
| Restart | elevated: `powershell -ExecutionPolicy Bypass -File workstation\install-windows.ps1 -Restart` |
| Update | `git pull; npm ci --ignore-scripts; npm test; npm run build;` then restart |
| Logs | `Get-Content data\server.log -Tail 50 -Wait` |
| Backup | copy `server\data\tether.db*` and `server\.env` (elevated `install-windows.ps1 -Stop` first, `-Restart` after) |

Troubleshooting: phone shows device `pending` → it hasn't fetched the latest policy (no push token / no
APNs; open Tether). `401` from MCP → wrong/revoked key. HTTPS URL not answering → `tailscale serve status`
and that the task is running. Port in use → set `PORT` in `.env` and re-run `tailscale serve --bg <port>`.

## Rules (from CLAUDE.md, the parts that apply here)
- Never commit `.env`, `data/`, `*.db`, `*.p8`, `node_modules`, `dist`.
- Changing API JSON shapes means changing `contracts/`, the iOS models and `server/src` together —
  out of scope on this machine. MCP tools live in `server/src/mcp.ts` and only call the REST routes.
- Never send app identities or per-app usage anywhere; the server never stores them.
