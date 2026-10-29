-- Suite : tableau de bord organisateur (phase 7) — continue la session des fichiers précédents.
\echo '--- 19. Tableau de bord : lecture réservée au propriétaire'
do $$
declare
  inv uuid := test.get('inv_jp')::uuid;
  ev uuid; owner uuid; other uuid; agent uuid; r jsonb; row jsonb; n int;
begin
  select e.id, e.organizer_id into ev, owner from public.invitations i join public.events e on e.id = i.event_id where i.id = inv;
  select e.organizer_id into other from public.invitations i join public.events e on e.id = i.event_id where i.id = test.get('inv_oth')::uuid;
  select s.agent_id into agent from public.event_staff s where s.event_id = ev limit 1;

  perform test.login(owner);
  r := public.organizer_events();
  perform test.ok(jsonb_typeof(r) = 'array' and exists (select 1 from jsonb_array_elements(r) x where x ->> 'id' = ev::text), 'le propriétaire voit son événement dans la liste');
  perform test.ok(not exists (select 1 from jsonb_array_elements(r) x where x ->> 'id' = test.get('e2')), 'il ne voit pas les événements des autres organisateurs');
  select x into row from jsonb_array_elements(r) x where x ->> 'id' = ev::text;
  select count(*) into n from public.guests where event_id = ev;
  perform test.ok((row ->> 'guests_total')::int = n, 'nombre d''invités = table guests (' || n || ')');
  perform test.ok((row ->> 'entries_validated')::int = (select coalesce(sum(entries_used), 0) from public.invitations where event_id = ev), 'entrées validées = somme des invitations');
  perform test.ok((row ->> 'invitations_active')::int = (select count(*) from public.invitations where event_id = ev and status in ('valid','used')), 'invitations actives cohérentes');

  r := public.event_guests(ev);
  perform test.ok(jsonb_array_length(r) = n, 'event_guests : un élément par invité');
  perform test.ok(not (r::text ~* '(token|hash)'), 'aucun jeton ni hachage dans la liste des invités');
  perform test.ok(exists (select 1 from jsonb_array_elements(r) x where x ->> 'full_name' = 'Jean-Pierre Mukendi' and x #>> '{invitation,status}' is not null), 'un invité avec invitation expose son statut');
  perform test.ok((select (jsonb_agg(x ->> 'full_name' order by ord)) = (jsonb_agg(x ->> 'full_name' order by lower(x ->> 'full_name'), ord)) from jsonb_array_elements(r) with ordinality as t(x, ord)), 'liste triée par nom');
  perform test.fails(format('select public.event_guests(%L)', test.get('e2')), 'access denied', 'liste des invités d''un autre événement refusée');
  perform test.logout();

  perform test.login(other);
  perform test.fails(format('select public.event_guests(%L)', ev), 'access denied', 'l''autre organisateur est refusé');
  perform test.ok(not exists (select 1 from jsonb_array_elements(public.organizer_events()) x where x ->> 'id' = ev::text), 'et ne voit pas cet événement dans sa liste');
  perform test.logout();

  perform test.login(agent);
  perform test.fails(format('select public.event_guests(%L)', ev), 'access denied', 'un agent ne lit pas la liste des invités');
  perform test.ok(jsonb_array_length(public.organizer_events()) = 0, 'un agent n''obtient aucun événement de gestion');
  perform test.logout();

  perform test.login_anon();
  perform test.fails('select public.organizer_events()', 'permission denied', 'anon ne peut pas appeler organizer_events');
  perform test.fails(format('select public.event_guests(%L)', ev), 'permission denied', 'anon ne peut pas appeler event_guests');
  perform test.logout();
end $$;
