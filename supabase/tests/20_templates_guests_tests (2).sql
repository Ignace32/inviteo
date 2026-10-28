-- Suite : modèles, invités, import CSV (continue la session de 10_phase1-3_tests.sql)

-- ===========================================================================
\echo '--- 3. Modèles'
-- ===========================================================================
do $$
declare n int;
begin
  perform test.login('00000000-0000-0000-0000-00000000000a');
  perform test.ok((select count(*) from public.templates) = 6, 'les 6 modèles de départ sont visibles');
  perform test.ok((select count(distinct event_type) from public.templates) = 5,
                  'types couverts : mariage, anniversaire, baptême, diplôme, professionnel');
  perform test.fails($q$insert into public.templates (slug, name, event_type) values ('pirate', 'Pirate', 'other')$q$,
                     'row-level security', 'un organisateur ne crée pas de modèle');
  update public.templates set name = 'Piraté';
  get diagnostics n = row_count;
  perform test.ok(n = 0, 'un organisateur ne modifie aucun modèle');
  delete from public.templates;
  get diagnostics n = row_count;
  perform test.ok(n = 0, 'un organisateur ne supprime aucun modèle');
  perform test.logout();

  -- L'admin ajoute un modèle (extensibilité sans toucher au reste) puis le désactive.
  perform test.login('00000000-0000-0000-0000-00000000000c');
  insert into public.templates (slug, name, event_type, config)
  values ('fete-test', 'Fête test', 'other', '{"layout":"clean"}');
  perform test.ok((select count(*) from public.templates) = 7, 'l''admin ajoute un modèle sans modifier le schéma');
  update public.templates set is_active = false where slug = 'fete-test';
  perform test.logout();

  perform test.login('00000000-0000-0000-0000-00000000000a');
  perform test.ok((select count(*) from public.templates) = 6, 'un modèle désactivé disparaît pour les organisateurs');
  perform test.logout();

  -- Les 6 configs sont des objets avec palette et mise en page, et sans dégradé
  perform test.ok((select bool_and(config ? 'palette' and config ? 'layout' and config ? 'cover')
                   from public.templates where slug <> 'fete-test'), 'chaque modèle définit palette, mise en page, ouverture');
  perform test.ok((select count(*) from public.templates where config::text ilike '%gradient%') = 0,
                  'aucun dégradé dans les modèles');
end $$;

-- ===========================================================================
\echo '--- 4. Invités'
-- ===========================================================================
do $$
declare
  v_a uuid := test.get('ev_a')::uuid;
  v_b uuid := test.get('ev_b')::uuid;
  v_done uuid := test.get('ev_done')::uuid;
  g uuid; n int;
begin
  perform test.login('00000000-0000-0000-0000-00000000000a');
  insert into public.guests (event_id, full_name, phone, email, party_size)
  values (v_a, 'Jean-Pierre Mukendi', '+243 990 228 413', 'jp@example.com', 2) returning id into g;
  perform test.put('guest_jp', g::text);
  perform test.ok(g is not null, 'A ajoute un invité à son événement');

  perform test.fails(format($q$insert into public.guests (event_id, full_name) values (%L, 'Intrus')$q$, v_b),
                     'row-level security', 'A n''ajoute pas d''invité à l''événement de B');
  perform test.fails(format($q$insert into public.guests (event_id, full_name) values (%L, '   ')$q$, v_a),
                     'check constraint', 'nom vide refusé');
  perform test.fails(format($q$insert into public.guests (event_id, full_name, party_size) values (%L, 'X', 0)$q$, v_a),
                     'check constraint', 'party_size = 0 refusé');
  perform test.fails(format($q$insert into public.guests (event_id, full_name, party_size) values (%L, 'X', 21)$q$, v_a),
                     'check constraint', 'party_size > 20 refusé');
  perform test.fails(format($q$insert into public.guests (event_id, full_name, email) values (%L, 'X', 'pas-un-email')$q$, v_a),
                     'check constraint', 'e-mail invalide refusé');
  perform test.fails(format($q$insert into public.guests (event_id, full_name, phone) values (%L, 'X', 'abc')$q$, v_a),
                     'check constraint', 'téléphone invalide refusé');
  perform test.fails(format($q$update public.guests set event_id = %L where id = %L$q$, v_b, g),
                     'permission denied', 'un invité ne change pas d''événement');
  perform test.logout();

  perform test.login('00000000-0000-0000-0000-00000000000b');
  perform test.ok((select count(*) from public.guests) = 0, 'B ne voit aucun invité de A');
  -- Une même personne peut figurer dans plusieurs événements
  insert into public.guests (event_id, full_name) values (v_b, 'Jean-Pierre Mukendi');
  perform test.ok((select count(*) from public.guests where full_name = 'Jean-Pierre Mukendi') = 1,
                  'le même nom peut être invité à un autre événement');
  update public.guests set full_name = 'Piraté' where id = g;
  get diagnostics n = row_count;
  perform test.ok(n = 0, 'B ne modifie pas l''invité de A');
  delete from public.guests where id = g;
  get diagnostics n = row_count;
  perform test.ok(n = 0, 'B ne supprime pas l''invité de A');
  perform test.logout();

  perform test.login('00000000-0000-0000-0000-00000000000a');
  perform test.fails(format($q$insert into public.guests (event_id, full_name) values (%L, 'Trop tard')$q$, v_done),
                     'finished', 'pas d''invité ajouté à un événement terminé');
  perform test.logout();

  perform test.login('00000000-0000-0000-0000-00000000000c');
  perform test.ok((select count(*) from public.guests) = 2, 'admin voit les invités (lecture)');
  perform test.logout();
end $$;

-- ===========================================================================
\echo '--- 5. Import en lot'
-- ===========================================================================
do $$
declare
  v_a uuid := test.get('ev_a')::uuid;
  v_b uuid := test.get('ev_b')::uuid;
  r jsonb;
begin
  perform test.login('00000000-0000-0000-0000-00000000000a');
  r := public.import_guests(v_a, $j$[
    {"full_name":"Marie Kalala","phone":"+243 81 234 5678","party_size":"2"},
    {"full_name":"  Paul Ilunga  ","email":"paul@example.com"},
    {"full_name":"Grâce Tshibanda","party_size":3},
    {"full_name":""},
    {"full_name":"Email Cassé","email":"pas-un-mail"},
    {"full_name":"Taille Folle","party_size":"abc"},
    {"full_name":"Trop Nombreux","party_size":25},
    {"full_name":"Tel Cassé","phone":"abc"},
    {"full_name":"jean-pierre MUKENDI","phone":"+243 990 228 413"},
    {"full_name":"Marie Kalala","phone":"+243 81 234 5678"}
  ]$j$);
  perform test.ok((r ->> 'inserted')::int = 3, 'import : 3 lignes valides insérées');
  perform test.ok(jsonb_array_length(r -> 'rejected') = 7, 'import : 7 lignes rejetées');
  perform test.ok((select array_agg(x ->> 'reason' order by (x ->> 'row')::int) from jsonb_array_elements(r -> 'rejected') x)
                  = array['name_required','email_invalid','party_size_invalid','party_size_invalid','phone_invalid','duplicate','duplicate'],
                  'import : motifs de rejet précis et numéros de ligne');
  perform test.ok((select party_size from public.guests where event_id = v_a and full_name = 'Marie Kalala') = 2,
                  'import : party_size texte converti');
  perform test.ok((select count(*) from public.guests where event_id = v_a and full_name = 'Paul Ilunga') = 1,
                  'import : espaces superflus retirés');

  r := public.import_guests(v_a, '[{"full_name":"Paul Ilunga","email":"paul@example.com"}]');
  perform test.ok((r ->> 'inserted')::int = 0 and (r -> 'rejected' -> 0 ->> 'reason') = 'duplicate',
                  'ré-importer le même fichier ne crée pas de doublons');

  perform test.fails(format($q$select public.import_guests(%L, '[{"full_name":"Intrus"}]')$q$, v_b),
                     'access denied', 'A n''importe pas dans l''événement de B');
  perform test.fails(format($q$select public.import_guests(%L, '{"full_name":"x"}')$q$, v_a),
                     'must be a JSON array', 'import : un objet à la place du tableau est refusé');
  perform test.fails(format($q$select public.import_guests(%L, (select jsonb_agg(jsonb_build_object('full_name', 'N'||g)) from generate_series(1, 2001) g))$q$, v_a),
                     'too many rows', 'import : plafond de 2000 lignes');
  perform test.logout();

  perform test.login_anon();
  perform test.fails(format($q$select public.import_guests(%L, '[]')$q$, v_a),
                     'permission denied', 'anon ne peut pas appeler import_guests');
  perform test.logout();
end $$;
