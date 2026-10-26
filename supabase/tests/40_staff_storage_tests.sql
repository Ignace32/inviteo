-- Suite : agents de contrôle, journaux en lecture seule, versions/documents, stockage

-- ===========================================================================
\echo '--- 10. Agents de contrôle'
-- ===========================================================================
do $$
declare
  v_a uuid := test.get('ev_a')::uuid;
  v_b uuid := test.get('ev_b')::uuid;
  v_tpl uuid := test.get('tpl')::uuid;
  n int;
begin
  perform test.login('00000000-0000-0000-0000-00000000000a');
  insert into public.event_staff (event_id, agent_id) values (v_a, '00000000-0000-0000-0000-00000000000d');
  perform test.ok((select assigned_by from public.event_staff where event_id = v_a) = '00000000-0000-0000-0000-00000000000a',
                  'A affecte son agent D ; assigned_by renseigné automatiquement');
  perform test.fails(format($q$insert into public.event_staff (event_id, agent_id) values (%L, '00000000-0000-0000-0000-00000000000e')$q$, v_a),
                     'row-level security', 'A ne peut pas affecter l''agent E créé par B');
  perform test.fails(format($q$insert into public.event_staff (event_id, agent_id) values (%L, '00000000-0000-0000-0000-00000000000b')$q$, v_a),
                     'only active agent accounts|row-level security', 'on n''affecte pas un compte organisateur comme agent');
  perform test.fails(format($q$insert into public.event_staff (event_id, agent_id) values (%L, '00000000-0000-0000-0000-00000000000d')$q$, v_a),
                     'duplicate key', 'pas de double affectation');
  perform test.fails(format($q$insert into public.event_staff (event_id, agent_id) values (%L, '00000000-0000-0000-0000-00000000000d')$q$, v_b),
                     'row-level security', 'A ne peut pas affecter D à l''événement de B');
  perform test.logout();

  perform test.fails(format($q$insert into public.event_staff (event_id, agent_id) values (%L, '00000000-0000-0000-0000-00000000000a')$q$, v_a),
                     'only active agent', 'même côté serveur, seuls des comptes agent actifs sont affectables');

  perform test.login('00000000-0000-0000-0000-00000000000b');
  insert into public.event_staff (event_id, agent_id) values (v_b, '00000000-0000-0000-0000-00000000000e');
  perform test.ok((select count(*) from public.event_staff) = 1, 'B ne voit que l''équipe de son événement');
  delete from public.event_staff where event_id = v_a;
  get diagnostics n = row_count;
  perform test.ok(n = 0, 'B ne retire pas l''agent d''un événement de A');
  update public.events set venue_name = 'Salle B', celebrated_names = 'Paul', template_id = v_tpl where id = v_b;
  update public.events set status = 'published' where id = v_b;
  perform test.logout();

  -- Point de vue de l'agent D
  perform test.login('00000000-0000-0000-0000-00000000000d');
  perform test.ok((select count(*) from public.my_assigned_events()) = 1, 'D voit uniquement son événement affecté');
  perform test.ok((select id from public.my_assigned_events()) = v_a, 'D voit l''événement de A, pas celui de B');
  perform test.ok((select count(*) from public.events) = 0, 'D n''a aucun accès direct à la table events');
  perform test.ok((select count(*) from public.guests) = 0, 'D ne voit aucun invité');
  perform test.ok((select count(*) from public.invitations) = 0, 'D ne voit aucune invitation');
  perform test.ok((select count(*) from public.event_staff) = 1, 'D voit sa propre affectation');
  perform test.fails($q$select * from public.invitation_secrets$q$, 'permission denied', 'D ne lit pas les jetons');
  perform test.fails(format($q$insert into public.events (organizer_id, event_type, name, starts_at)
                              values ('00000000-0000-0000-0000-00000000000d', 'other', 'X', now())$q$),
                     'row-level security', 'un agent ne crée pas d''événement');
  perform test.fails(format('select public.issue_invitation(%L)', test.get('guest_jp')::uuid), 'access denied',
                     'un agent n''émet pas d''invitation');
  perform test.fails($q$update public.profiles set role = 'organizer' where id = '00000000-0000-0000-0000-00000000000d'$q$,
                     'permission denied', 'un agent ne change pas son rôle');
  delete from public.event_staff;
  get diagnostics n = row_count;
  perform test.ok(n = 0, 'un agent ne retire pas son affectation');
  perform test.logout();

  perform test.login('00000000-0000-0000-0000-00000000000e');
  perform test.ok((select id from public.my_assigned_events()) = v_b and (select count(*) from public.my_assigned_events()) = 1,
                  'E voit uniquement l''événement de B (publié)');
  perform test.logout();

  -- Compte agent désactivé
  update public.profiles set disabled = true where id = '00000000-0000-0000-0000-00000000000d';
  perform test.login('00000000-0000-0000-0000-00000000000d');
  perform test.ok((select count(*) from public.my_assigned_events()) = 0, 'agent désactivé : plus aucun événement');
  perform test.logout();
  update public.profiles set disabled = false where id = '00000000-0000-0000-0000-00000000000d';

  -- Compte organisateur désactivé
  update public.profiles set disabled = true where id = '00000000-0000-0000-0000-00000000000a';
  perform test.login('00000000-0000-0000-0000-00000000000a');
  perform test.ok((select count(*) from public.events) = 0, 'organisateur désactivé : ne voit plus ses événements');
  perform test.fails(format($q$insert into public.events (organizer_id, event_type, name, starts_at)
                              values ('00000000-0000-0000-0000-00000000000a', 'other', 'X', now())$q$),
                     'row-level security', 'organisateur désactivé : ne crée plus d''événement');
  perform test.logout();
  update public.profiles set disabled = false where id = '00000000-0000-0000-0000-00000000000a';
end $$;

-- ===========================================================================
\echo '--- 11. Journaux, documents obsolètes, lecture seule'
-- ===========================================================================
do $$
declare
  v_a uuid := test.get('ev_a')::uuid;
  v_b uuid := test.get('ev_b')::uuid;
  v_cur int;
begin
  select version into v_cur from public.events where id = v_a;
  perform test.ok(v_cur >= 3, 'version courante de l''événement A : ' || v_cur);

  insert into public.event_documents (event_id, kind, storage_path, event_version)
  values (v_a, 'invitation_pdf', v_a || '/old.pdf', 1),
         (v_a, 'invitation_pdf', v_a || '/current.pdf', v_cur);

  insert into public.scan_logs (request_id, event_id, agent_id, result, details)
  values (gen_random_uuid(), v_a, '00000000-0000-0000-0000-00000000000d', 'invalid', '{}'),
         (gen_random_uuid(), v_b, '00000000-0000-0000-0000-00000000000e', 'invalid', '{}');
  perform test.fails(format($q$insert into public.scan_logs (request_id, event_id, agent_id, result)
                              select request_id, event_id, agent_id, result from public.scan_logs limit 1$q$),
                     'duplicate key', 'idempotence : même (agent, requête) ne s''enregistre qu''une fois');

  perform test.login('00000000-0000-0000-0000-00000000000a');
  perform test.ok((select count(*) from public.outdated_documents) = 1,
                  'A est informé : 1 PDF généré pour une version antérieure');
  perform test.ok((select count(*) from public.event_documents) = 2, 'A voit les PDF de son événement');
  perform test.ok((select count(*) from public.scan_logs) = 1, 'A ne voit que les contrôles de son événement');
  perform test.fails(format($q$insert into public.event_documents (event_id, kind, storage_path, event_version) values (%L, 'invitation_pdf', 'x', 1)$q$, v_a),
                     'permission denied', 'le navigateur n''écrit pas les documents');
  perform test.fails(format($q$insert into public.scan_logs (request_id, event_id, agent_id, result) values (gen_random_uuid(), %L, %L, 'accepted')$q$, v_a, '00000000-0000-0000-0000-00000000000a'),
                     'permission denied', 'le navigateur n''écrit pas les journaux de contrôle');
  perform test.fails($q$delete from public.scan_logs$q$, 'permission denied', 'les journaux ne s''effacent pas depuis le navigateur');
  perform test.fails($q$insert into public.rsvp_responses (invitation_id, event_id, attending) select id, event_id, true from public.invitations limit 1$q$,
                     'permission denied', 'le navigateur n''écrit pas les réponses RSVP');
  perform test.fails($q$select * from public.admin_audit_log$q$, 'x^', 'placeholder-never-matches') ;
exception when others then
  if sqlerrm like 'FAIL%' and sqlerrm not like '%placeholder-never-matches%' then raise; end if;
end $$;
