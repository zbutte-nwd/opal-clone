#!/usr/bin/env bash
# Run everything testable on Linux. Skips parts whose tooling/dirs are missing.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FAIL=0; RAN=0; SKIPPED=()
run() { local name="$1"; shift; echo; echo "==> $name"; RAN=$((RAN+1)); if "$@"; then echo "OK  $name"; else echo "FAIL $name"; FAIL=$((FAIL+1)); fi; }

run contracts-validate python3 contracts/tools/validate.py
run contracts-vectors python3 contracts/tools/ref_engine.py contracts/engine-vectors.json

if command -v swift >/dev/null; then
  run swift-test bash -c 'cd ios/Packages/TetherCore && swift test'
else SKIPPED+=("swift (not installed)"); fi

node_part() {
  local dir="$1"; shift
  if [ -f "$dir/package.json" ] && command -v npm >/dev/null; then
    run "$dir" bash -c "cd $dir && (npm ci || npm install) && $*"
  else SKIPPED+=("$dir (no package.json or npm)"); fi
}
node_part server "npm run typecheck && npm test"
node_part admin "npm run build && npm test"

echo; echo "Ran $RAN, failed $FAIL"
[ ${#SKIPPED[@]} -eq 0 ] || printf 'Skipped: %s\n' "${SKIPPED[@]}"
[ "$FAIL" -eq 0 ]
