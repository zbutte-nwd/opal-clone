# Tether (working name)

An iOS focus / screen-time app in the spirit of Opal:

- **Block apps & websites** in groups ("Social", "Games") using Apple's Screen Time API.
- **Triggers**: weekly schedules, daily usage limits, focus sessions (incl. strict "can't
  end early"), and **remote control from a server** — block/unblock groups now, for a
  set time, or flip named modes like "Homework mode".
- **Protection gated by the Screen Time passcode, not Face ID**: with a Screen Time
  passcode set, the app can't be deleted or have its access revoked without that
  passcode. In-app disabling uses a partner PIN or admin approval. (Details — and what
  iOS does and doesn't allow — in [`docs/PLATFORM_CONSTRAINTS.md`](docs/PLATFORM_CONSTRAINTS.md).)
- **Admin dashboard** for a parent / partner / employer to manage devices, schedules and
  unlock requests.

## Docs

| Doc | What |
|---|---|
| [Feature map](docs/FEATURE_MAP.md) | Every feature, priority (P0/P1/P2), owner |
| [Platform constraints](docs/PLATFORM_CONSTRAINTS.md) | Screen Time API realities, passcode answer, background limits |
| [Architecture](docs/ARCHITECTURE.md) | Reconcile model, data model, blocking semantics, sync protocol, module APIs |
| [Build plan](docs/BUILD_PLAN.md) | Agent workstreams, status, Mac phases, spikes |
| [Mac handoff](docs/MAC_HANDOFF.md) | Start here on a Mac |
| [Device test plan](docs/TEST_PLAN_DEVICE.md) | On-device test matrix |
| [API contract](contracts/api.md) | REST API |

## Repo

```
contracts/   schemas, golden engine vectors, fixtures — the source of truth shared by iOS and server
ios/         Swift package (TetherCore/TetherAPI/TetherKit), SwiftUI app, 5 extensions, XcodeGen spec
server/      Node 22 + TypeScript + Fastify + SQLite; APNs push
admin/       React + Vite dashboard
scripts/     bootstrap-mac.sh, test-linux.sh, dev helpers
```

## Quick start

```bash
make test                 # everything that runs on Linux/macOS without Xcode
make server-dev           # API on :8787 (+ seed data)
./scripts/bootstrap-mac.sh   # on a Mac: generate Xcode project, run tests
```
