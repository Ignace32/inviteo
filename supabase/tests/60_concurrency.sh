#!/usr/bin/env bash
# Scans réellement simultanés : plusieurs connexions PostgreSQL distinctes, lancées
# au même instant (barrière horaire), qui scannent le MÊME QR code.
#
# Une seule session ne peut pas simuler cela : il faut de vraies transactions
# concurrentes validées (COMMIT). Ce script utilise donc une base à part,
# « inviteo_conc », recréée à chaque exécution.
#
# Usage :  PGHOST=... PGPORT=... PGUSER=postgres ./60_concurrency.sh
# NE JAMAIS l'utiliser sur une base de production (il crée des rôles et un faux schéma auth).
set -uo pipefail
cd "$(dirname "$0")"

DB="${CONC_DB:-inviteo_conc}"
Q=(psql -X -q -At -v ON_ERROR_STOP=1)
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() {  # check "description" "attendu" "obtenu"
  if [ "$2" == "$3" ]; then PASS=$((PASS+1)); echo "PASS  $1 ($3)"
  else FAIL=$((FAIL+1)); echo "FAIL  $1 : attendu $2, obtenu $3"; fi
}

echo "== Base de test dédiée ($DB)"
"${Q[@]}" -d postgres -c "drop database if exists ${DB}" -c "create database ${DB}" >/dev/null 2>&1
"${Q[@]}" -d "$DB" -f 00_supabase_stub.sql >/dev/null 2>&1
for f in ../migrations/*.sql; do "${Q[@]}" -d "$DB" -f "$f" >/dev/null 2>&1 || { echo "ÉCHEC migration $f"; exit 1; }; done

ORG='00000000-0000-0000-0000-00000000c001'
NAGENTS=12
agent_id() { printf '00000000-0000-0000-0000-00000000c1%02d' "$1"; }

# --- Fixtures validées (COMMIT) : un organisateur, 12 agents, un événement publié ---
"${Q[@]}" -d "$DB" >/dev/null <<EOF
insert into auth.users (id, email) values ('$ORG', 'org@conc');
$(for i in $(seq 1 $NAGENTS); do echo "insert into auth.users (id, email) values ('$(agent_id $i)', 'ag$i@conc');"; done)
update public.profiles set role = 'agent', created_by = '$ORG', full_name = 'Agent ' || right(id::text, 2)
 where id in ($(for i in $(seq 1 $NAGENTS); do printf "'%s'," "$(agent_id $i)"; done | sed 's/,$//'));
EOF

# L'organisateur crée son événement (l'identifiant est généré par la base, il ne se choisit pas).
EV=$("${Q[@]}" -d "$DB" <<EOF | tail -1
begin;
select set_config('request.jwt.claim.sub', '$ORG', true);
set local role authenticated;
insert into public.events (organizer_id, event_type, name, starts_at, venue_name, celebrated_names, template_id)
values ('$ORG', 'wedding', 'Mariage concurrence', now() + interval '10 days',
        'Salle', 'Test', (select id from public.templates where slug = 'mariage-classique'))
returning id;
commit;
EOF
)
[ -n "$EV" ] || { echo "ÉCHEC : événement non créé"; exit 1; }

"${Q[@]}" -d "$DB" >/dev/null <<EOF
begin;
select set_config('request.jwt.claim.sub', '$ORG', true);
set local role authenticated;
$(for i in $(seq 1 $NAGENTS); do echo "insert into public.event_staff (event_id, agent_id) values ('$EV', '$(agent_id $i)');"; done)
update public.events set status = 'published' where id = '$EV';
commit;
EOF

# Émet une invitation (invité + jetons) et affiche « id_invitation|jeton_qr ».
new_invitation() {  # new_invitation "Nom" party_size
  "${Q[@]}" -d "$DB" <<EOF | tail -1
begin;
select set_config('request.jwt.claim.sub', '$ORG', true);
set local role authenticated;
with g as (insert into public.guests (event_id, full_name, party_size) values ('$EV', '$1', $2) returning id)
select invitation_id || '|' || qr_token from g, lateral public.issue_invitation(g.id);
commit;
EOF
}

# Lance N scans simultanés (une connexion par agent) ; chaque résultat va dans $WORK/<tag>.<i>.json
# $1 tag  $2 jeton  $3 nombre de scans  $4 mode : "distinct" (un request_id par scan) ou "same" (même agent, même request_id)
race() {
  local tag="$1" tok="$2" n="$3" mode="$4" start req i ag
  start=$(python3 -c 'import time; print(time.time() + 1.5)')
  req=$(python3 -c 'import uuid; print(uuid.uuid4())')
  for i in $(seq 1 "$n"); do
    if [ "$mode" == "same" ]; then ag=$(agent_id 1); else ag=$(agent_id "$i"); fi
    [ "$mode" == "same" ] || req=$(python3 -c 'import uuid; print(uuid.uuid4())')
    (
      "${Q[@]}" -d "$DB" > "$WORK/$tag.$i.json" 2>"$WORK/$tag.$i.err" <<EOF
select pg_sleep(greatest(0, $start - extract(epoch from clock_timestamp())));
begin;
select set_config('request.jwt.claim.sub', '$ag', true);
set local role authenticated;
select public.scan_invitation('$EV', '$tok', '$req');
commit;
EOF
    ) &
  done
  wait
}
count_result() {  # count_result tag résultat
  cat "$WORK/$1".*.json 2>/dev/null | python3 -c "
import sys, json
n = 0
for l in sys.stdin:
    l = l.strip()
    if l.startswith('{'):
        try:
            if json.loads(l).get('result') == '$2': n += 1
        except Exception: pass
print(n)"
}
errors_in() { cat "$WORK/$1".*.err 2>/dev/null | grep -c . || true; }
sql1() { "${Q[@]}" -d "$DB" -c "$1"; }

echo
echo "== A. 12 agents scannent en même temps le MÊME billet individuel (5 manches)"
for round in 1 2 3 4 5; do
  inv=$(new_invitation "Invité A$round" 1); id=${inv%%|*}; tok=${inv#*|}
  race "A$round" "$tok" $NAGENTS distinct
  check "A$round : une seule entrée acceptée"       1 "$(count_result "A$round" accepted)"
  check "A$round : 11 refus « déjà utilisée »"      11 "$(count_result "A$round" already_used)"
  check "A$round : aucune erreur SQL"               0 "$(errors_in "A$round")"
  check "A$round : entries_used en base"            1 "$(sql1 "select entries_used from public.invitations where id = '$id'")"
  check "A$round : statut en base"                  used "$(sql1 "select status from public.invitations where id = '$id'")"
  check "A$round : journal = 1 acceptée, 11 doublons" "1|11" "$(sql1 "select count(*) filter (where result='accepted') || '|' || count(*) filter (where result='already_used') from public.scan_logs where invitation_id = '$id'")"
done

echo
echo "== B. Billet de 3 personnes, 12 scans simultanés : exactement 3 entrées (3 manches)"
for round in 1 2 3; do
  inv=$(new_invitation "Famille B$round" 3); id=${inv%%|*}; tok=${inv#*|}
  race "B$round" "$tok" $NAGENTS distinct
  check "B$round : 3 entrées acceptées"             3 "$(count_result "B$round" accepted)"
  check "B$round : 9 refus"                         9 "$(count_result "B$round" already_used)"
  check "B$round : entries_used jamais > 3"         3 "$(sql1 "select entries_used from public.invitations where id = '$id'")"
  check "B$round : aucune erreur SQL"               0 "$(errors_in "B$round")"
done

echo
echo "== C. Même requête rejouée 8 fois en parallèle (coupure réseau) : comptée une seule fois (3 manches)"
for round in 1 2 3; do
  inv=$(new_invitation "Rejeu C$round" 3); id=${inv%%|*}; tok=${inv#*|}
  race "C$round" "$tok" 8 same
  check "C$round : 8 réponses « acceptée » (même résultat rejoué)" 8 "$(count_result "C$round" accepted)"
  check "C$round : dont 1 seule « première fois » (replayed=false)" 1 "$(cat "$WORK/C$round".*.json | grep '"result": "accepted"' | grep -c '"replayed": false' || true)"
  check "C$round : entries_used = 1"                1 "$(sql1 "select entries_used from public.invitations where id = '$id'")"
  check "C$round : une seule ligne de journal"      1 "$(sql1 "select count(*) from public.scan_logs where invitation_id = '$id'")"
  check "C$round : 7 réponses marquées « replayed »" 7 "$(cat "$WORK/C$round".*.json | grep -c '"replayed": true' || true)"
  check "C$round : aucune erreur SQL"               0 "$(errors_in "C$round")"
done

echo
echo "== D. Cohérence globale : statistiques = journaux = invitations"
STATS=$("${Q[@]}" -d "$DB" <<EOF | tail -1
begin;
select set_config('request.jwt.claim.sub', '$ORG', true);
set local role authenticated;
select public.event_stats('$EV');
commit;
EOF
)
get() { echo "$STATS" | python3 -c "import sys,json; print(json.load(sys.stdin)['$1'])"; }
LOG_ACC=$(sql1 "select count(*) from public.scan_logs where event_id = '$EV' and result = 'accepted'")
LOG_DUP=$(sql1 "select count(*) from public.scan_logs where event_id = '$EV' and result = 'already_used'")
SUM_USED=$(sql1 "select sum(entries_used) from public.invitations where event_id = '$EV'")
check "entrées validées (stats) = entrées acceptées (journal)" "$LOG_ACC" "$(get entries_validated)"
check "entrées validées (stats) = somme des entries_used"      "$SUM_USED" "$(get entries_validated)"
check "tentatives en double (stats) = journal"                 "$LOG_DUP" "$(get duplicate_attempts)"
check "invitations émises"                                     11 "$(get invitations_total)"
check "aucune invitation ne dépasse son quota"                 0 "$(sql1 "select count(*) from public.invitations where entries_used > max_entries")"
check "attendu : 5 + 9 + 3 entrées acceptées au total"         17 "$(get entries_validated)"

echo
echo "Résultat concurrence : ${PASS} réussis, ${FAIL} échoués"
[ "$FAIL" -eq 0 ]
