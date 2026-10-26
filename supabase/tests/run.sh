#!/usr/bin/env bash
# Rejoue toutes les migrations puis tous les tests SQL sur une base PostgreSQL vierge.
#
# Usage :
#   PGHOST=localhost PGPORT=5432 PGUSER=postgres ./run.sh
#
# La base de test « inviteo_test » est supprimée et recréée à chaque exécution.
# NE JAMAIS pointer ce script vers une base de production : 00_supabase_stub.sql
# crée des rôles et des schémas qui existent déjà sur un vrai projet Supabase.
set -euo pipefail
cd "$(dirname "$0")"

DB="${TEST_DB:-inviteo_test}"
PSQL=(psql -v ON_ERROR_STOP=1 -q)

"${PSQL[@]}" -d postgres -c "drop database if exists ${DB}" -c "create database ${DB}" 2>&1 | grep -v NOTICE || true

echo "== Environnement Supabase simulé"
"${PSQL[@]}" -d "$DB" -f 00_supabase_stub.sql

for f in ../migrations/*.sql; do
  echo "== Migration $(basename "$f")"
  "${PSQL[@]}" -d "$DB" -f "$f" 2>&1 | grep -v "NOTICE" || true
  [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "ÉCHEC de la migration $f"; exit 1; }
done

echo "== Tests (une seule session : les fichiers se suivent)"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
set +e
"${PSQL[@]}" -d "$DB" > "$OUT" 2>&1 <<'EOF'
\i 10_phase1-3_tests.sql
\i 20_templates_guests_tests.sql
\i 30_invitations_tests.sql
\i 40_staff_storage_tests.sql
EOF
STATUS=$?
set -e

grep -E "^---|FAIL|ERROR" "$OUT" || true
PASS=$(grep -c "PASS" "$OUT" || true)
FAIL=$(grep -c "FAIL" "$OUT" || true)
echo
echo "Résultat : ${PASS} réussis, ${FAIL} échoués (code ${STATUS})"
[ "$STATUS" -eq 0 ] && [ "$FAIL" -eq 0 ]
