-- Suite : création d'un événement (migration 10) — continue la session des fichiers précédents.
\echo '--- 20. Création d''événement, modèles, agents'
do $$
declare
  owner uuid; other uuid; agent uuid; foreign_agent uuid; r jsonb; ev uuid; n_before int; base jsonb;
begin
  select e.organizer_id into owner from public.invitations i join public.events e on e.id = i.event_id where i.id = test.get('inv_jp')::uuid;
  select e.organizer_id into other from public.invitations i join public.events e on e.id = i.event_id where i.id = test.get('inv_oth')::uuid;
  select s.agent_id into agent from public.event_staff s join public.events e on e.id = s.event_id where e.organizer_id = owner limit 1;
  select p.id into foreign_agent from public.profiles p where p.role = 'agent' and p.created_by = other limit 1;

  base := jsonb_build_object('event_type', 'wedding', 'template', 'mariage-classique', 'name', 'Mariage Test Création',
            'celebrated_names', 'Léa & Marc', 'starts_at', '2027-05-01T15:00:00+02:00', 'venue_name', 'Salle Test',
            'rsvp_enabled', true, 'show_qr_on_page', true, 'publish', true,
            'program', jsonb_build_array(jsonb_build_object('time', '15h00', 'title', 'Cérémonie'), jsonb_build_object('time', '', 'title', ''), jsonb_build_object('time', '18h', 'title', 'Cocktail')));

  perform test.login(owner);
  r := public.list_templates();
  perform test.ok(jsonb_array_length(r) = 14 and r::text like '%mariage-moderne%', 'list_templates : les 14 modèles actifs');
  perform test.ok(jsonb_array_length(public.my_agents()) >= 1 and not (public.my_agents()::text like '%' || coalesce(foreign_agent::text, 'none') || '%'), 'my_agents : mes agents seulement');

  r := public.create_event(base || jsonb_build_object('agent_ids', jsonb_build_array(agent)));
  perform test.ok((r ->> 'ok')::boolean and r ->> 'status' = 'published', 'création + affectation + publication en une fois');
  ev := (r ->> 'id')::uuid;
  perform test.ok((select count(*) from public.event_staff where event_id = ev and agent_id = agent) = 1, 'agent affecté');
  perform test.ok((select jsonb_array_length(program) from public.events where id = ev) = 2, 'ligne de programme vide ignorée (2 lignes gardées)');
  perform test.ok((select organizer_id from public.events where id = ev) = owner, 'organisateur = utilisateur connecté (non modifiable par les données)');
  perform test.ok((select template_id from public.events where id = ev) = (select id from public.templates where slug = 'mariage-classique'), 'modèle enregistré');

  r := public.create_event(base || '{"publish": false, "name": "Brouillon Test"}'::jsonb || '{"venue_name": "", "celebrated_names": ""}'::jsonb);
  perform test.ok((r ->> 'ok')::boolean and r ->> 'status' = 'draft', 'brouillon sans lieu ni noms accepté');
  r := public.create_event(base || '{"venue_name": ""}'::jsonb);
  perform test.ok(r ->> 'error' = 'publish_requires_venue_and_names', 'publication sans lieu refusée avec un message clair');
  r := public.create_event(base - 'name'); perform test.ok(r ->> 'error' = 'name_required', 'nom obligatoire');
  r := public.create_event(base || '{"template": "inconnu"}'); perform test.ok(r ->> 'error' = 'template_invalid', 'modèle inconnu refusé');
  r := public.create_event(base || '{"event_type": "fete"}'); perform test.ok(r ->> 'error' = 'type_invalid', 'type inconnu refusé');
  r := public.create_event(base || '{"starts_at": "pas une date"}'); perform test.ok(r ->> 'error' = 'date_invalid', 'date invalide refusée');
  r := public.create_event(base || '{"maps_url": "http://exemple.com"}'); perform test.ok(r ->> 'error' = 'invalid_field', 'lien carte non https refusé');
  r := public.create_event(base || ('{"name": "' || repeat('x', 200) || '"}')::jsonb); perform test.ok(r ->> 'error' = 'invalid_field', 'nom de plus de 160 caractères refusé');
  r := public.create_event(base || jsonb_build_object('organizer_id', other));
  perform test.ok((select organizer_id from public.events where id = (r ->> 'id')::uuid) = owner, 'organizer_id fourni dans les données : ignoré');

  select count(*) into n_before from public.events where name = 'Mariage Test Création';
  r := public.create_event(base || jsonb_build_object('agent_ids', jsonb_build_array(foreign_agent)));
  perform test.ok(r ->> 'error' = 'agent_not_allowed', 'agent d''un autre organisateur refusé');
  perform test.ok((select count(*) from public.events where name = 'Mariage Test Création') = n_before, 'atomique : aucun événement créé quand l''affectation échoue');
  r := public.create_event(base || jsonb_build_object('agent_ids', jsonb_build_array('00000000-0000-0000-0000-0000000000aa')));
  perform test.ok(r ->> 'error' = 'agent_not_allowed' and (select count(*) from public.events where name = 'Mariage Test Création') = n_before, 'agent inexistant refusé, rien créé ' || r::text || ' n=' || (select count(*) from public.events where name = 'Mariage Test Création') || '/' || n_before);
  r := public.create_event(base || jsonb_build_object('agent_ids', jsonb_build_array(agent, agent)));
  perform test.ok(r ->> 'error' = 'agent_duplicated' and (select count(*) from public.events where name = 'Mariage Test Création') = n_before, 'même agent deux fois : refusé, rien créé');
  perform test.logout();

  perform test.login(agent);
  perform test.fails(format('select public.create_event(%L::jsonb)', base), 'access denied', 'un agent ne peut pas créer d''événement');
  perform test.fails('select public.my_agents()', 'access denied', 'un agent n''obtient pas la liste des agents');
  perform test.logout();

  perform test.login_anon();
  perform test.fails(format('select public.create_event(%L::jsonb)', base), 'permission denied', 'anon ne peut pas créer');
  perform test.fails('select public.list_templates()', 'permission denied', 'anon ne peut pas lister les modèles (la page publique passe par le serveur)');
  perform test.logout();
end $$;
