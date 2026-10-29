#!/usr/bin/env bash
# Lance la pile de test (base réelle + relais Supabase + serveur local) et la laisse tourner : pour regarder les pages à la main.
set -euo pipefail
cd "$(dirname "$0")"
./setup.sh /tmp/fx.json >/dev/null
export SERVICE_KEY="dev-service" ANON_KEY="dev-anon" SHIM_PORT=54321 PORT=3100
export SUPABASE_URL="http://127.0.0.1:$SHIM_PORT" SUPABASE_SERVICE_ROLE_KEY="$SERVICE_KEY" SUPABASE_ANON_KEY="$ANON_KEY" PUBLIC_SITE_URL="http://127.0.0.1:$PORT"
setsid node shim.js >/tmp/shim.log 2>&1 &
setsid node server.js >/tmp/server.log 2>&1 &
sleep 1; echo "http://127.0.0.1:$PORT"
