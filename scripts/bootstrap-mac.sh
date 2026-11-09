#!/usr/bin/env bash
# Idempotent Mac setup for Tether (phase M0). Safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -t 1 ]; then G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; N=$'\033[0m'; else G=; Y=; R=; B=; N=; fi
ok()   { echo "${G}✔${N} $*"; }
warn() { echo "${Y}!${N} $*"; }
die()  { echo "${R}✘ $*${N}" >&2; exit 1; }
step() { echo; echo "${B}==> $*${N}"; }

step "Checking environment"
[ "$(uname -s)" = "Darwin" ] || die "This script must run on macOS (use scripts/test-linux.sh on Linux)."
command -v xcodebuild >/dev/null || die "Xcode not found. Install Xcode 16+ from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app"
XVER="$(xcodebuild -version | awk '/^Xcode/{print $2}')"
XMAJOR="${XVER%%.*}"
[ "${XMAJOR:-0}" -ge 16 ] || die "Xcode $XVER found; Xcode 16 or newer is required."
ok "macOS + Xcode $XVER"

step "XcodeGen"
if ! command -v xcodegen >/dev/null; then
  command -v brew >/dev/null || die "Homebrew missing. Install from https://brew.sh then re-run."
  brew install xcodegen
fi
ok "xcodegen $(xcodegen --version 2>/dev/null | head -1)"

step "Local.xcconfig"
LOCAL="$ROOT/ios/Config/Local.xcconfig"
if [ -f "$LOCAL" ]; then
  ok "ios/Config/Local.xcconfig exists (not touched)"
else
  TEAM="${DEVELOPMENT_TEAM:-}"
  PREFIX="${BUNDLE_ID_PREFIX:-}"
  if [ -z "$TEAM" ] && [ -t 0 ]; then read -r -p "Apple Developer Team ID (10 chars, blank to set later): " TEAM || true; fi
  if [ -z "$PREFIX" ] && [ -t 0 ]; then read -r -p "Bundle ID prefix [com.newwestsite]: " PREFIX || true; fi
  PREFIX="${PREFIX:-com.newwestsite}"
  cp "$ROOT/ios/Config/Local.xcconfig.example" "$LOCAL"
  # BSD sed: -i '' ; keep portable by rewriting through a temp file.
  TMP="$(mktemp)"
  sed -e "s|^DEVELOPMENT_TEAM = .*|DEVELOPMENT_TEAM = ${TEAM}|" \
      -e "s|^BUNDLE_ID_PREFIX = .*|BUNDLE_ID_PREFIX = ${PREFIX}|" "$LOCAL" > "$TMP" && mv "$TMP" "$LOCAL"
  ok "created ios/Config/Local.xcconfig (team='${TEAM}', prefix='${PREFIX}')"
  [ -n "$TEAM" ] || warn "DEVELOPMENT_TEAM empty: set it in ios/Config/Local.xcconfig or pick a team in Xcode."
fi

step "Generating Xcode project"
( cd "$ROOT/ios" && xcodegen generate )
ok "ios/Tether.xcodeproj generated"

step "Resolving Swift packages"
( cd "$ROOT/ios/Packages/TetherCore" && swift package resolve )
ok "packages resolved"

step "Swift package tests (TetherCore)"
( cd "$ROOT/ios/Packages/TetherCore" && swift test )
ok "swift test passed"

step "Server tests"
if [ -f "$ROOT/server/package.json" ]; then
  command -v npm >/dev/null || die "npm not found: brew install node@22"
  ( cd "$ROOT/server" && npm install && npm test )
  ok "server tests passed"
else
  warn "server/package.json missing; skipped"
fi

cat <<NEXT

${B}Next steps${N}
  1. open ios/Tether.xcodeproj
  2. For all 6 targets: Signing & Capabilities -> select your Team (or set DEVELOPMENT_TEAM in Local.xcconfig and re-run).
     Register App Group group.<prefix>.tether and Family Controls capability if Xcode asks.
  3. Plug in an iPhone (iOS 17+) with Developer Mode on (Settings > Privacy & Security). Family Controls does NOT work in the Simulator.
  4. Run the spikes S1-S6 in docs/BUILD_PLAN.md (M1); record results in docs/reviews/M1-spikes.md.
  5. M2: build every scheme, fix compile errors; then docs/TEST_PLAN_DEVICE.md for M3.
  6. Start the server: scripts/dev-server.sh and pair via scripts/new-pairing-code.sh
NEXT
