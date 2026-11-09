#!/usr/bin/env bash
# End-to-end smoke test across the stack, no iPhone needed:
#   seed server -> admin login -> pairing code -> device enroll -> policy fetch (ETag/304)
#   -> admin blocks "Games" for 30 min via /actions/block -> device refetch gets new version
#   -> the Swift TetherCore engine decodes the server's bundle and must report Games BLOCKED.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; PORT="${PORT:-8799}"; B="http://localhost:$PORT/v1"
export DATABASE_PATH="$TMP/e2e.db" PORT JWT_SECRET=e2e-secret PUBLIC_BASE_URL="http://localhost:$PORT"
cd "$ROOT/server"
[ -d node_modules ] || npm install --silent
npm run --silent seed >/dev/null
npx tsx src/index.ts >"$TMP/server.log" 2>&1 & SERVER=$!
trap 'kill $SERVER 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 30); do curl -sf "localhost:$PORT/healthz" >/dev/null && break; sleep 0.5; done
j() { python3 -c "import sys,json;print(json.load(sys.stdin)$1)"; }
TOK=$(curl -sf -X POST $B/auth/login -H 'content-type: application/json' -d '{"email":"demo@tether.local","password":"tether-demo"}' | j '["token"]')
CODE=$(curl -sf -X POST $B/pairing-codes -H "authorization: Bearer $TOK" -H 'content-type: application/json' -d '{}' | j '["code"]')
DT=$(curl -sf -X POST $B/devices/enroll -H 'content-type: application/json' \
  -d "{\"pairingCode\":\"$CODE\",\"name\":\"Smoke iPhone\",\"model\":\"iPhone\",\"osVersion\":\"18.0\",\"appVersion\":\"0.1.0\"}" | j '["deviceToken"]')
curl -sf "$B/devices/me/policy" -H "authorization: Bearer $DT" -o "$TMP/b1.json"
V=$(j '["version"]' < "$TMP/b1.json")
[ "$(curl -s -o /dev/null -w '%{http_code}' $B/devices/me/policy -H "authorization: Bearer $DT" -H "If-None-Match: \"$V\"")" = 304 ] || { echo "FAIL: expected 304"; exit 1; }
GID=$(python3 -c "import json;print([g['id'] for g in json.load(open('$TMP/b1.json'))['groups'] if g['name']=='Games'][0])")
curl -sf -X POST $B/actions/block -H "authorization: Bearer $TOK" -H 'content-type: application/json' -d "{\"groupIds\":[\"$GID\"],\"durationMinutes\":30}" >/dev/null
curl -sf "$B/devices/me/policy" -H "authorization: Bearer $DT" -H "If-None-Match: \"$V\"" -o "$TMP/b2.json"
OUT=$(cd "$ROOT/scripts/e2e" && swift run --scratch-path "${E2E_BUILD:-/tmp/tether-e2e-build}" -q E2E "$TMP/b2.json")
echo "$OUT"
echo "$OUT" | grep -q "^Games BLOCKED override" && echo "E2E OK" || { echo "FAIL: Games not blocked"; exit 1; }
