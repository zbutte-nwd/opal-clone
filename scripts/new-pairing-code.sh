#!/usr/bin/env bash
# Create a device pairing code on a running server.
# Env: TETHER_ADMIN_TOKEN (admin JWT or tk_live_ API key, required), TETHER_SERVER (default http://localhost:8787)
# Usage: new-pairing-code.sh [deviceName]
set -euo pipefail
: "${TETHER_ADMIN_TOKEN:?set TETHER_ADMIN_TOKEN (login via POST /v1/auth/login, or an API key)}"
SERVER="${TETHER_SERVER:-http://localhost:8787}"
NAME="${1:-}"
BODY="{}"; [ -z "$NAME" ] || BODY="$(printf '{"deviceName":"%s"}' "${NAME//\"/}")"
RES="$(curl -fsS -X POST "$SERVER/v1/pairing-codes" \
  -H "Authorization: Bearer $TETHER_ADMIN_TOKEN" -H 'Content-Type: application/json' -d "$BODY")"
echo "$RES"
if command -v python3 >/dev/null; then
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print("\nCode:   ",d.get("code")); print("Expires:",d.get("expiresAt")); print("Link:   ",d.get("qrPayload"))' "$RES" || true
fi
