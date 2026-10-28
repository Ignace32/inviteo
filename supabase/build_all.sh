#!/usr/bin/env bash
# Régénère all_migrations.sql (à coller dans Supabase > SQL Editor en une seule fois).
cd "$(dirname "$0")"
{ echo "-- Invitéo — toutes les migrations dans l'ordre (généré par supabase/build_all.sh ; ne pas modifier à la main)."
  for f in migrations/*.sql; do echo; echo "-- >>>>>>>> $(basename "$f")"; cat "$f"; done; } > all_migrations.sql
echo "all_migrations.sql régénéré ($(ls migrations/*.sql | wc -l) migrations)"
