#!/usr/bin/env bash
# Run the API server (:8787) and admin dev server (:5173) together. Ctrl-C stops both.
# Env: PORT, JWT_SECRET (defaults to a dev value), DATABASE_PATH.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PORT="${PORT:-8787}"
export JWT_SECRET="${JWT_SECRET:-dev-secret-change-me}"
export DATABASE_PATH="${DATABASE_PATH:-$ROOT/server/data/tether.db}"
mkdir -p "$(dirname "$DATABASE_PATH")"

[ -f "$ROOT/server/package.json" ] || { echo "server/package.json missing" >&2; exit 1; }
[ -d "$ROOT/server/node_modules" ] || (cd "$ROOT/server" && npm install)

# Seed demo data if the server provides a seed script (optional).
if grep -q '"seed"' "$ROOT/server/package.json"; then (cd "$ROOT/server" && npm run seed) || echo "seed failed (continuing)"; fi

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT INT TERM

(cd "$ROOT/server" && npm run dev) & PIDS+=($!)
if [ -f "$ROOT/admin/package.json" ]; then
  [ -d "$ROOT/admin/node_modules" ] || (cd "$ROOT/admin" && npm install)
  (cd "$ROOT/admin" && npm run dev) & PIDS+=($!)
fi
echo "server: http://localhost:$PORT   admin: http://localhost:5173"
wait
