-- Suite : validation atomique des scans (phase 6)
-- Continue la session de 10_phase1-3_tests.sql (mêmes helpers test.*).
-- Les scans réellement simultanés (plusieurs connexions) sont testés à part, par
-- 60_concurrency.sh : une seule session ne peut pas simuler deux transactions.

create function test.scan(p_agent uuid, p_ev uuid, p_tok text, p_req uuid default gen_random_uuid())
returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform test.login(p_agent);
  r := public.scan_invitation(p_ev, p_tok, p_req);
  perform test.logout();
  return r;
end $$;
grant execute on function test.scan(uuid, uuid, text, uuid) to public;

-- ===========================================================================
\echo '--- 12. Scan : préparation (organisateurs O1 et O2, agents, événements)'
-- ===========================================================================
do $$
declare
  o1  uuid := '00000000-0000-0000-0000-000000000101';
  o2  uuid := '00000000-0000-0000-0000-000000000102';
  ag1 uuid := '00000000-0000-0000-0000-000000000111';
  ag2 uuid := '00000000-0000-0000-0000-000000000112';
  ag4 uuid := '00000000-0000-0000-0000-000000000114';
  ag5 uuid := '00000000-0000-0000-0000-000000000121';
  tpl uuid := (select id from public.templates where slug = 'mariage-classique');
  e1 uuid; e2 uuid; e1d uuid; g uuid; r record; t record;
begin
  insert into auth.users (id, email) values
    (o1, 'o1@test'), (o2, 'o2@test'),
    (ag1, 'ag1@test'), (ag2, 'ag2@test'), ('00000000-0000-0000-0000-000000000113', 'ag3@test'),
    (ag4, 'ag4@test'), (ag5, 'ag5@test'), ('00000000-0000-0000-0000-000000000199', 'adm@test');
  update public.profiles set role = 'agent', created_by = o1, full_name = 'Agent Un'     where id = ag1;
  update public.profiles set role = 'agent', created_by = o1, full_name = 'Agent Deux'   where id = ag2;
  update public.profiles set role = 'agent', created_by = o1, full_name = 'Agent Trois'  where id = '00000000-0000-0000-0000-000000000113';
  update public.profiles set role = 'agent', created_by = o1, full_name = 'Agent Quatre' where id = ag4;
  update public.profiles set role = 'agent', created_by = o2, full_name = 'Agent Cinq'   where id = ag5;
  update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-000000000199';

  -- O1 : un mariage (publié) et un événement brouillon
  perform test.login(o1);
  insert into public.events (organizer_id, event_type, name, starts_at, venue_name, celebrated_names, template_id)
  values (o1, 'wedding', 'Mariage de David et Sarah', now() + interval '30 days', 'Salle Royale', 'David et Sarah', tpl)
  returning id into e1;
  insert into public.events (organizer_id, event_type, name, starts_at, venue_name, celebrated_names, template_id)
  values (o1, 'birthday', 'Anniversaire brouillon', now() + interval '40 days', 'Salon', 'Grâce', tpl)
  returning id into e1d;
  perform test.put('e1', e1::text); perform test.put('e1d', e1d::text);

  for t in
    select * from (values ('jp', 'Jean-Pierre Mukendi', 1), ('fam', 'Famille Kabila', 3), ('rev', 'Invité Révoqué', 1),
                          ('exp', 'Invité Expiré', 1), ('rpl', 'Invité Rejeu', 3), ('una', 'Invité Intact', 1),
                          ('drf', 'Invité Brouillon', 1)) v(k, n, p)
  loop
    insert into public.guests (event_id, full_name, party_size)
      values (case when t.k = 'drf' then e1d else e1 end, t.n, t.p) returning id into g;
    select * into r from public.issue_invitation(g);            -- les jetons ne sont renvoyés qu'une fois
    perform test.put('inv_' || t.k, r.invitation_id::text);
    perform test.put('qr_'  || t.k, r.qr_token);
    perform test.put('view_' || t.k, r.view_token);
  end loop;

  insert into public.event_staff (event_id, agent_id) values (e1, ag1), (e1, ag2), (e1, ag4), (e1d, ag1);
  update public.events set status = 'published' where id = e1;
  perform test.logout();
  update public.profiles set disabled = true where id = ag4;     -- agent désactivé après affectation

  -- O2 : un autre mariage, avec son agent et une invitation
  perform test.login(o2);
  insert into public.events (organizer_id, event_type, name, starts_at, venue_name, celebrated_names, template_id)
  values (o2, 'wedding', 'Mariage de Paul et Esther', now() + interval '20 days', 'Hôtel', 'Paul et Esther', tpl)
  returning id into e2;
  insert into public.guests (event_id, full_name) values (e2, 'Invité Autre Événement') returning id into g;
  select * into r from public.issue_invitation(g);
  perform test.put('e2', e2::text); perform test.put('inv_oth', r.invitation_id::text); perform test.put('qr_oth', r.qr_token); perform test.put('view_oth', r.view_token);
  insert into public.event_staff (event_id, agent_id) values (e2, ag5);
  update public.events set status = 'published' where id = e2;
  perform test.logout();

  perform test.ok((select count(*) from public.invitations where event_id in (e1, e1d, e2)) = 8, '8 invitations émises (7 + 1)');
  perform test.ok((select count(distinct qr_token_hash) from public.invitation_secrets) >= 8, 'chaque invitation a son propre QR');
end $$;

-- ===========================================================================
\echo '--- 13. Scan : cas nominaux et refus'
-- ===========================================================================
do $$
declare
  e1 uuid := test.get('e1')::uuid; e2 uuid := test.get('e2')::uuid; e1d uuid := test.get('e1d')::uuid;
  o1  uuid := '00000000-0000-0000-0000-000000000101';
  adm uuid := '00000000-0000-0000-0000-000000000199';
  ag1 uuid := '00000000-0000-0000-0000-000000000111';
  ag2 uuid := '00000000-0000-0000-0000-000000000112';
  ag3 uuid := '00000000-0000-0000-0000-000000000113';
  ag4 uuid := '00000000-0000-0000-0000-000000000114';
  ag5 uuid := '00000000-0000-0000-0000-000000000121';
  r jsonb; r2 jsonb; req uuid; n_logs int;
begin
  -- Entrée valide, puis refus du second passage
  r := test.scan(ag1, e1, test.get('qr_jp'));
  perform test.ok(r ->> 'result' = 'accepted', 'VERT : première entrée acceptée');
  perform test.ok(r ->> 'guest_name' = 'Jean-Pierre Mukendi', 'le nom exact de l''invité est renvoyé');
  perform test.ok(r ->> 'event_name' = 'Mariage de David et Sarah', 'le nom de l''événement est renvoyé');
  perform test.ok((r ->> 'entries_used')::int = 1 and (r ->> 'max_entries')::int = 1, 'entrée 1 sur 1');
  perform test.ok((select status from public.invitations where id = test.get('inv_jp')::uuid) = 'used', 'l''invitation passe à « utilisée » en base');
  perform test.ok((select first_used_by from public.invitations where id = test.get('inv_jp')::uuid) = ag1, 'l''agent qui a validé est enregistré');

  r := test.scan(ag1, e1, test.get('qr_jp'));
  perform test.ok(r ->> 'result' = 'already_used', 'ROUGE : second scan refusé (même agent)');
  perform test.ok(r ->> 'first_scanned_by' = 'Agent Un' and (r ->> 'first_scanned_at') is not null,
                  'le refus indique qui a validé la première entrée, et quand');
  r := test.scan(ag2, e1, test.get('qr_jp'));
  perform test.ok(r ->> 'result' = 'already_used' and r ->> 'first_scanned_by' = 'Agent Un',
                  'ROUGE : second scan refusé (autre agent), la première entrée reste attribuée à Agent Un');
  perform test.ok((select entries_used from public.invitations where id = test.get('inv_jp')::uuid) = 1, 'aucune entrée supplémentaire consommée');
  perform test.ok((select count(*) from public.scan_logs where invitation_id = test.get('inv_jp')::uuid and result = 'accepted') = 1
              and (select count(*) from public.scan_logs where invitation_id = test.get('inv_jp')::uuid and result = 'already_used') = 2,
                  'journal : 1 entrée acceptée, 2 tentatives en double');

  -- Invitation pour 3 personnes : 3 entrées, puis refus
  r := test.scan(ag1, e1, test.get('qr_fam'));
  perform test.ok(r ->> 'result' = 'accepted' and (r ->> 'entries_used')::int = 1 and (r ->> 'max_entries')::int = 3, 'billet de 3 : entrée 1/3');
  r := test.scan(ag2, e1, test.get('qr_fam'));
  perform test.ok(r ->> 'result' = 'accepted' and (r ->> 'entries_used')::int = 2, 'billet de 3 : entrée 2/3');
  perform test.ok((select status from public.invitations where id = test.get('inv_fam')::uuid) = 'valid', 'billet de 3 : encore valide après 2 entrées');
  r := test.scan(ag1, e1, test.get('qr_fam'));
  perform test.ok(r ->> 'result' = 'accepted' and (r ->> 'entries_used')::int = 3, 'billet de 3 : entrée 3/3');
  perform test.ok((select status from public.invitations where id = test.get('inv_fam')::uuid) = 'used', 'billet de 3 : « utilisée » après la 3e entrée');
  r := test.scan(ag1, e1, test.get('qr_fam'));
  perform test.ok(r ->> 'result' = 'already_used', 'billet de 3 : 4e passage refusé');
  perform test.ok((select entries_used from public.invitations where id = test.get('inv_fam')::uuid) = 3, 'billet de 3 : jamais plus de 3 entrées en base');

  -- Invitation révoquée, expirée
  perform test.login(o1);
  perform public.revoke_invitation(test.get('inv_rev')::uuid, 'test de révocation');
  perform test.logout();
  r := test.scan(ag1, e1, test.get('qr_rev'));
  perform test.ok(r ->> 'result' = 'revoked', 'invitation révoquée : refus');
  perform test.ok((select entries_used from public.invitations where id = test.get('inv_rev')::uuid) = 0, 'invitation révoquée : aucune entrée consommée');

  update public.invitations set expires_at = now() - interval '1 day' where id = test.get('inv_exp')::uuid;
  r := test.scan(ag1, e1, test.get('qr_exp'));
  perform test.ok(r ->> 'result' = 'expired', 'invitation expirée : refus');
  perform test.ok((select entries_used from public.invitations where id = test.get('inv_exp')::uuid) = 0, 'invitation expirée : aucune entrée consommée');

  -- Autre événement
  req := gen_random_uuid();
  r := test.scan(ag1, e1, test.get('qr_oth'), req);
  perform test.ok(r ->> 'result' = 'wrong_event', 'un QR d''un autre événement est refusé');
  perform test.ok(not (r ? 'guest_name') and not (r ? 'entries_used'), 'rien n''est révélé sur l''invité de l''autre événement');
  perform test.ok((select entries_used from public.invitations where id = test.get('inv_oth')::uuid) = 0
              and (select status from public.invitations where id = test.get('inv_oth')::uuid) = 'valid', 'l''invitation de l''autre événement est intacte');
  perform test.ok((select invitation_id from public.scan_logs where request_id = req) is null, 'journal : la tentative n''est pas rattachée à l''invitation étrangère');
  r := test.scan(ag5, e2, test.get('qr_jp'));
  perform test.ok(r ->> 'result' = 'wrong_event', 'inversement : un QR de E1 est refusé sur E2');

  -- Agents non autorisés
  r := test.scan(ag3, e1, test.get('qr_una'));
  perform test.ok(r ->> 'result' = 'forbidden' and r ->> 'reason' = 'not_assigned', 'agent non affecté : refus');
  r := test.scan(ag5, e1, test.get('qr_una'));
  perform test.ok(r ->> 'result' = 'forbidden' and r ->> 'reason' = 'not_assigned', 'agent d''un autre organisateur : refus');
  r := test.scan(ag4, e1, test.get('qr_una'));
  perform test.ok(r ->> 'result' = 'forbidden' and r ->> 'reason' = 'not_an_active_agent', 'agent désactivé : refus');
  r := test.scan(o1, e1, test.get('qr_una'));
  perform test.ok(r ->> 'result' = 'forbidden' and r ->> 'reason' = 'not_an_active_agent', 'l''organisateur lui-même ne valide pas d''entrée');
  r := test.scan(adm, e1, test.get('qr_una'));
  perform test.ok(r ->> 'result' = 'forbidden', 'l''administrateur ne valide pas d''entrée');
  r := test.scan(ag1, e1d, test.get('qr_drf'));
  perform test.ok(r ->> 'result' = 'forbidden' and r ->> 'reason' = 'event_not_open', 'événement non publié : refus');
  perform test.ok((select entries_used from public.invitations where id = test.get('inv_una')::uuid) = 0
              and (select status from public.invitations where id = test.get('inv_una')::uuid) = 'valid', 'après tous ces refus, l''invitation intacte est toujours valide');

  -- Événement inconnu : refus, rien à journaliser
  select count(*) into n_logs from public.scan_logs;
  r := test.scan(ag1, gen_random_uuid(), test.get('qr_una'));
  perform test.ok(r ->> 'result' = 'forbidden' and r ->> 'reason' = 'unknown_event', 'événement inconnu : refus');
  perform test.ok((select count(*) from public.scan_logs) = n_logs, 'événement inconnu : aucune ligne ajoutée au journal');

  -- Jetons invalides
  r := test.scan(ag1, e1, translate(rtrim(encode(extensions.gen_random_bytes(32), 'base64'), '='), '+/', '-_'));
  perform test.ok(r ->> 'result' = 'invalid', 'jeton inconnu : refus');
  r := test.scan(ag1, e1, 'abc');
  perform test.ok(r ->> 'result' = 'invalid', 'jeton mal formé : refus');
  r := test.scan(ag1, e1, null);
  perform test.ok(r ->> 'result' = 'invalid', 'jeton absent : refus');
  r := test.scan(ag1, e1, test.get('view_una'));
  perform test.ok(r ->> 'result' = 'invalid', 'le jeton du LIEN n''ouvre pas l''entrée : seul le QR est accepté');
  perform test.ok((select entries_used from public.invitations where id = test.get('inv_una')::uuid) = 0, 'invitation intacte après les jetons invalides');
end $$;

-- ===========================================================================
\echo '--- 14. Scan : identité, rejeu et coupure réseau'
-- ===========================================================================
do $$
declare
  e1 uuid := test.get('e1')::uuid;
  ag1 uuid := '00000000-0000-0000-0000-000000000111';
  ag2 uuid := '00000000-0000-0000-0000-000000000112';
  req uuid := gen_random_uuid();
  r1 jsonb; r2 jsonb; r3 jsonb;
begin
  -- Rejeu d'une même requête (coupure réseau) : une seule entrée consommée
  r1 := test.scan(ag1, e1, test.get('qr_rpl'), req);
  r2 := test.scan(ag1, e1, test.get('qr_rpl'), req);
  perform test.ok(r1 ->> 'result' = 'accepted' and (r1 ->> 'entries_used')::int = 1, 'requête : première réponse = entrée 1/3');
  perform test.ok((r2 ->> 'replayed')::boolean and (r1 - 'replayed') = (r2 - 'replayed'), 'rejeu : même réponse, marquée « replayed »');
  perform test.ok((select entries_used from public.invitations where id = test.get('inv_rpl')::uuid) = 1, 'rejeu : l''entrée n''est PAS comptée deux fois');
  perform test.ok((select count(*) from public.scan_logs where request_id = req) = 1, 'rejeu : une seule ligne de journal');

  r3 := test.scan(ag1, e1, test.get('qr_rpl'));   -- nouvelle requête = nouveau passage
  perform test.ok(r3 ->> 'result' = 'accepted' and (r3 ->> 'entries_used')::int = 2, 'nouvelle requête : entrée 2/3 comptée normalement');

  perform test.login(ag1);
  perform test.fails(format($q$select public.scan_invitation(%L, %L, %L)$q$, e1, test.get('qr_jp'), req),
                     'already used for another scan', 'un identifiant de requête ne peut pas servir à un autre scan');
  perform test.logout();

  -- Droits : anon, sans identité, accès direct aux tables
  perform test.login_anon();
  perform test.fails(format($q$select public.scan_invitation(%L, %L, gen_random_uuid())$q$, e1, test.get('qr_una')),
                     'permission denied', 'anon ne peut pas appeler le scan');
  perform test.logout();

  perform set_config('request.jwt.claim.sub', '', true);
  set local role authenticated;
  perform test.fails(format($q$select public.scan_invitation(%L, %L, gen_random_uuid())$q$, e1, test.get('qr_una')),
                     'not authenticated', 'sans identité : refus');
  perform test.logout();

  perform test.login(ag2);
  perform test.fails(format($q$update public.invitations set status = 'valid', entries_used = 0 where id = %L$q$, test.get('inv_jp')),
                     'permission denied', 'un agent ne peut pas modifier une invitation directement');
  perform test.fails($q$select * from public.invitation_secrets$q$, 'permission denied', 'un agent ne lit pas les jetons');
  perform test.fails(format($q$insert into public.scan_logs (request_id, event_id, agent_id, result) values (gen_random_uuid(), %L, %L, 'accepted')$q$, e1, ag2),
                     'permission denied', 'un agent n''écrit pas dans le journal');
  perform test.logout();

  -- Confidentialité des journaux
  perform test.ok((select count(*) from public.scan_logs where details::text like '%' || test.get('qr_jp') || '%') = 0
              and (select count(*) from public.scan_logs where details::text like '%' || test.get('view_una') || '%') = 0,
                  'les jetons secrets n''apparaissent jamais en clair dans le journal');
  perform test.ok((select count(*) from public.scan_logs where details ? 'token_fp' and details ->> 'token_fp' !~ '^[0-9a-f]{12}$') = 0,
                  'le journal ne garde qu''une empreinte de 12 caractères');

  -- Cohérence compteurs / journal sur l'événement E1
  perform test.ok((select count(*) from public.scan_logs where event_id = e1 and result = 'accepted')
                = (select sum(entries_used) from public.invitations where event_id = e1),
                  'cohérence : entrées acceptées au journal = entrées comptées sur les invitations');
end $$;

-- ===========================================================================
\echo '--- 15. Statistiques de l''événement'
-- ===========================================================================
do $$
declare
  e1 uuid := test.get('e1')::uuid;
  o1  uuid := '00000000-0000-0000-0000-000000000101';
  o2  uuid := '00000000-0000-0000-0000-000000000102';
  adm uuid := '00000000-0000-0000-0000-000000000199';
  ag1 uuid := '00000000-0000-0000-0000-000000000111';
  s jsonb;
begin
  perform test.login(o1);
  s := public.event_stats(e1);
  perform test.ok((s ->> 'invitations_total')::int = (select count(*) from public.invitations where event_id = e1), 'stats : total = invitations en base');
  perform test.ok((s ->> 'entries_validated')::int = (select count(*) from public.scan_logs where event_id = e1 and result = 'accepted'),
                  'stats : entrées validées = entrées acceptées au journal');
  perform test.ok((s ->> 'duplicate_attempts')::int = (select count(*) from public.scan_logs where event_id = e1 and result = 'already_used'),
                  'stats : tentatives en double = journal');
  perform test.ok((s ->> 'revoked')::int = 1, 'stats : 1 invitation révoquée');
  perform test.ok((s ->> 'refused_attempts')::int = (select count(*) from public.scan_logs where event_id = e1
                    and result in ('invalid', 'wrong_event', 'revoked', 'expired', 'forbidden')), 'stats : refus = journal');
  perform test.ok(jsonb_array_length(s -> 'last_entries') between 1 and 10 and s -> 'last_entries' -> 0 ? 'agent_name',
                  'stats : dernières entrées avec heure et agent');
  perform test.logout();

  perform test.login(o2);
  perform test.fails(format('select public.event_stats(%L)', e1), 'access denied', 'un autre organisateur ne voit pas les statistiques');
  perform test.logout();
  perform test.login(ag1);
  perform test.fails(format('select public.event_stats(%L)', e1), 'access denied', 'un agent n''a pas accès aux statistiques');
  perform test.logout();
  perform test.login(adm);
  perform test.ok((public.event_stats(e1) ->> 'invitations_total')::int > 0, 'l''administrateur peut consulter les statistiques');
  perform test.logout();
  perform test.login_anon();
  perform test.fails(format('select public.event_stats(%L)', e1), 'permission denied', 'anon ne peut pas appeler les statistiques');
  perform test.logout();
end $$;
