#!/usr/bin/env bash
# Test de la page d'invitation : base réelle + point d'accès simulé + Chromium.
# Variables PGHOST / PGPORT / PGUSER comme pour supabase/tests/run.sh. Nécessite Node 18+, psql, Playwright, OpenCV (python).
set -euo pipefail
cd "$(dirname "$0")"
W="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$W"' EXIT
./setup.sh "$W/fx.json"
export SERVICE_KEY="test-service-key-$RANDOM$RANDOM" ANON_KEY="test-anon-key-$RANDOM" SHIM_PORT=54321 PORT=3100
export SUPABASE_URL="http://127.0.0.1:$SHIM_PORT" SUPABASE_SERVICE_ROLE_KEY="$SERVICE_KEY" SUPABASE_ANON_KEY="$ANON_KEY" PUBLIC_SITE_URL="http://127.0.0.1:$PORT"
node shim.js & node server.js &
sleep 1
OUT="${SHOTS:-$W}"; mkdir -p "$OUT"
export NODE_PATH="${NODE_PATH:-$(npm root -g 2>/dev/null || true)}"
node e2e.js "$W/fx.json" "$OUT"
node pdf_e2e.js "$W/fx.json" "$OUT"
node scanner_e2e.js "$W/fx.json" "$OUT"
node organizer_e2e.js "$W/fx.json" "$OUT"

../smoke.sh "http://127.0.0.1:$PORT"
