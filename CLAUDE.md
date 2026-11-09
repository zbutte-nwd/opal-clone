# CLAUDE.md — agent guide for this repo

Tether: an iOS focus/screen-time app (Opal-like) — blocks apps & websites by schedule,
usage, focus sessions, and **remotely from a server**; protection gated by the
**Screen Time passcode**, never Face ID.

## Read in this order
1. `docs/PLATFORM_CONSTRAINTS.md` — what iOS allows (Screen Time API, passcode reality).
2. `docs/ARCHITECTURE.md` — reconcile model, data model, **resolution semantics (§3)**, module interfaces (§8).
3. `docs/BUILD_PLAN.md` — workstreams, ownership, Mac phases, spikes. Update status there.
4. `docs/MAC_HANDOFF.md` — if you are on a Mac, start here.

## Layout
```
contracts/            JSON schemas, golden engine vectors, fixtures, API contract (source of truth)
ios/Packages/TetherCore/   Swift package: TetherCore (pure), TetherAPI (networking), TetherKit (Apple-only)
ios/App/              SwiftUI app target
ios/Extensions/       Monitor, ShieldConfig, ShieldAction, Report, Push (NSE)
ios/project.yml       XcodeGen spec (no .xcodeproj is committed — generate it)
ios/Config/           xcconfigs, Info.plists, entitlements, privacy manifest
server/               Node 22 + TS + Fastify + SQLite API, APNs sender
admin/                React + Vite admin dashboard
scripts/              bootstrap & helper scripts
```

## Commands
- Everything testable on Linux: `make test` (contracts + swift package + server + admin).
- Contracts: `python3 contracts/tools/validate.py && python3 contracts/tools/ref_engine.py contracts/engine-vectors.json`
- Swift package: `cd ios/Packages/TetherCore && swift test`
- Server: `cd server && npm install && npm test && npm run dev`
- Admin: `cd admin && npm install && npm run dev`
- iOS (Mac only): `cd ios && xcodegen generate && open Tether.xcodeproj`

## Rules
- The contract is frozen-by-default: changing JSON shape or semantics means updating
  `contracts/*.schema.json`, `contracts/tools/gen_vectors.py` (regenerate vectors),
  `Models.swift`, and `server/src` in the same commit, with all tests green.
- Engine semantics live in exactly one spec (ARCHITECTURE.md §3) and are proven by
  `contracts/engine-vectors.json` in three implementations (Python ref, Swift, TS).
- All Apple-framework code is wrapped in `#if canImport(ManagedSettings)` (or the relevant
  framework) so the package builds on Linux.
- Never import `LocalAuthentication`; no biometrics anywhere (product requirement).
- Never send app identities / per-app usage off the device.
- Don't commit generated `Tether.xcodeproj`, `node_modules`, `dist`, `.build`, `*.db`, secrets (`*.p8`).
