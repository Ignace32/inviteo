#!/usr/bin/env bash
# Vérification rapide d'un déploiement (aucun secret requis).
#   tests/smoke.sh https://inviteo-dun.vercel.app [--headers]
# Variables facultatives : SMOKE_EMAIL / SMOKE_PASSWORD (compte agent) pour tester une vraie connexion.
set -uo pipefail
BASE="${1:?usage: smoke.sh URL [--headers]}"; BASE="${BASE%/}"; HEADERS="${2:-}"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "PASS  $1"; }
ko() { FAIL=$((FAIL+1)); echo "FAIL  $1"; }
code() { curl -s -o /dev/null -m 20 -w '%{http_code}' "$@"; }
want() { local d="$1" e="$2"; shift 2; local c; c=$(code "$@"); [ "$c" = "$e" ] && ok "$d ($c)" || ko "$d : attendu $e, obtenu $c"; }

want "page d'accueil" 200 "$BASE/"
want "mentions légales" 200 "$BASE/mentions-legales"
want "scanner" 200 "$BASE/scanner"
want "espace organisateur" 200 "$BASE/organisateur"
want "page /s/<jeton> (explicative)" 200 "$BASE/s/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
want "lien d'invitation inconnu" 404 "$BASE/i/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
want "lien d'invitation mal formé" 404 "$BASE/i/court"
want "fichiers du serveur non exposés (supabase/)" 404 "$BASE/supabase/all_migrations.sql"
want "fichiers de test non exposés (tests/)" 404 "$BASE/tests/smoke.sh"
want "README non exposé" 404 "$BASE/README.md"
want "API scan : GET refusé" 405 "$BASE/api/scan"
want "API scan : sans connexion" 401 -X POST -H 'Content-Type: application/json' -d '{}' "$BASE/api/scan"
want "API organisateur : sans connexion" 401 -X POST -H 'Content-Type: application/json' -d '{}' "$BASE/api/organizer"
want "API billet : sans connexion" 401 -X POST -H 'Content-Type: application/json' -d '{}' "$BASE/api/ticket"

c=$(code -X POST -H 'Content-Type: application/json' -d '{"email":"inconnu@exemple.com","password":"x"}' "$BASE/api/auth")
case "$c" in
  401) ok "connexion : Supabase joignable, mauvais identifiants refusés (401)";;
  503) ko "connexion : 503 = variables Supabase manquantes ou projet injoignable (voir DEPLOIEMENT.md, étape 6)";;
  *)   ko "connexion : réponse inattendue $c";;
esac

body=$(curl -s -m 20 "$BASE/i/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"); [ -n "$body" ] && ok "page d'erreur d'invitation rendue" || ko "page d'erreur vide"
if [ -n "${SMOKE_EMAIL:-}" ] && [ -n "${SMOKE_PASSWORD:-}" ]; then
  tok=$(curl -s -m 20 -X POST -H 'Content-Type: application/json' -d "{\"email\":\"$SMOKE_EMAIL\",\"password\":\"$SMOKE_PASSWORD\"}" "$BASE/api/auth" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
  if [ -n "$tok" ]; then ok "connexion réelle du compte de test"
    c=$(code -H "Authorization: Bearer $tok" "$BASE/api/my-events"); [ "$c" = 200 ] && ok "liste des événements de l'agent (200)" || ko "liste des événements : $c"
  else ko "connexion réelle du compte de test refusée"; fi
fi
if [ "$HEADERS" = "--headers" ]; then
  h() { curl -s -I -m 20 "$BASE$1" | tr -d '\r' | grep -i "^$2:" | head -1; }
  [ -n "$(h / x-content-type-options)" ] && ok "en-tête nosniff sur /" || ko "nosniff absent sur /"
  h / permissions-policy | grep -q 'camera=()' && ok "caméra interdite sur le site vitrine" || ko "Permissions-Policy du site vitrine"
  h /scanner permissions-policy | grep -q 'camera=(self)' && ok "caméra autorisée sur /scanner" || ko "Permissions-Policy de /scanner"
  h /scanner content-security-policy | grep -q "script-src 'self'" && ok "CSP du scanner" || ko "CSP du scanner"
  h /organisateur content-security-policy | grep -q "script-src 'self'" && ok "CSP de l'espace organisateur" || ko "CSP organisateur"
  h /i/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA cache-control | grep -qi 'no-store' && ok "pages d'invitation : no-store" || ko "pages d'invitation sans no-store"
  h /i/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA x-robots-tag | grep -qi noindex && ok "pages d'invitation : noindex" || ko "noindex absent"
fi
echo; echo "Résultat : $PASS réussis, $FAIL échoués"; [ "$FAIL" -eq 0 ]
