-- Suite : contexte du billet PDF (phase 5) — continue la session des fichiers précédents.
-- Utilise les invitations créées par 50_scan_tests.sql.
\echo '--- 18. Contexte du billet : réservé au propriétaire de l''événement'
do $$
declare
  inv   uuid := test.get('inv_jp')::uuid;
  owner uuid; other uuid; agent uuid; r jsonb;
begin
  select e.organizer_id into owner from public.invitations i join public.events e on e.id = i.event_id where i.id = inv;
  select e.organizer_id into other from public.invitations i join public.events e on e.id = i.event_id where i.id = test.get('inv_oth')::uuid;
  select s.agent_id into agent from public.event_staff s join public.invitations i on i.event_id = s.event_id where i.id = inv limit 1;

  perform test.login(owner);
  r := public.ticket_context(inv);
  perform test.ok(r ->> 'guest_name' = 'Jean-Pierre Mukendi' and r ->> 'event_name' = 'Mariage de David et Sarah', 'le propriétaire obtient le nom et l''événement');
  perform test.ok(not (r::text ~* '(token|hash|email|phone)'), 'aucun jeton, hachage, e-mail ni téléphone dans le contexte');
  perform test.fails(format('select public.ticket_context(%L)', test.get('inv_oth')), 'access denied', 'un organisateur ne lit pas le billet d''un autre événement');
  perform test.fails($q$select public.ticket_context('00000000-0000-0000-0000-0000000000ff')$q$, 'access denied', 'invitation inconnue : refus');
  perform test.logout();

  perform test.login(other);
  perform test.fails(format('select public.ticket_context(%L)', inv), 'access denied', 'l''autre organisateur est refusé');
  perform test.logout();

  perform test.login(agent);
  perform test.fails(format('select public.ticket_context(%L)', inv), 'access denied', 'un agent ne peut pas lire le contexte du billet');
  perform test.logout();

  perform test.login_anon();
  perform test.fails(format('select public.ticket_context(%L)', inv), 'permission denied', 'anon ne peut pas appeler la fonction');
  perform test.logout();
end $$;
