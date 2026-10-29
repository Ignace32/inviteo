-- ============================================================================
-- Tests des phases 1 à 3 : isolation entre organisateurs, rôles, invitations,
-- jetons hachés, import d'invités, versions, stockage.
-- Chaque vérification affiche « PASS » ; toute défaillance interrompt le script.
-- Tout est annulé en fin de script (rollback) : la base reste propre.
-- ============================================================================
\set ON_ERROR_STOP on
begin;

create schema test;
grant usage on schema test to public;
create table test.ctx (k text primary key, v text);
grant all on test.ctx to public;

create function test.login(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  execute 'set local role authenticated';
end $$;

create function test.login_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';
end $$;

create function test.logout() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

create function test.ok(c boolean, msg text) returns void language plpgsql as $$
begin
  if c is distinct from true then
    raise exception 'FAIL  %', msg;
  end if;
  raise notice 'PASS  %', msg;
end $$;

-- Vérifie qu'une requête échoue avec un message qui correspond au motif donné.
create function test.fails(q text, pat text, msg text) returns void language plpgsql as $$
declare m text;
begin
  begin
    execute q;
  exception when others then
    m := sqlerrm;
    if m ~* pat then
      raise notice 'PASS  % [%]', msg, left(m, 70);
      return;
    end if;
    raise exception 'FAIL  % : mauvaise erreur "%" (attendu /%/)', msg, m, pat;
  end;
  raise exception 'FAIL  % : aucune erreur levée', msg;
end $$;

create function test.put(k text, v text) returns void language sql as
  $$ insert into test.ctx values (k, v) on conflict (k) do update set v = excluded.v $$;
create function test.get(k text) returns text language sql stable as
  $$ select v from test.ctx where ctx.k = get.k $$;
grant execute on all functions in schema test to public;

-- ---------------------------------------------------------------------------
-- Comptes : A, B organisateurs ; C admin ; D agent de A ; E agent de B
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'a@test'),
  ('00000000-0000-0000-0000-00000000000b', 'b@test'),
  ('00000000-0000-0000-0000-00000000000c', 'c@test'),
  ('00000000-0000-0000-0000-00000000000d', 'd@test'),
  ('00000000-0000-0000-0000-00000000000e', 'e@test');
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-00000000000c';
update public.profiles set role = 'agent', created_by = '00000000-0000-0000-0000-00000000000a'
  where id = '00000000-0000-0000-0000-00000000000d';
update public.profiles set role = 'agent', created_by = '00000000-0000-0000-0000-00000000000b'
  where id = '00000000-0000-0000-0000-00000000000e';

-- ===========================================================================
\echo '--- 1. Profils et rôles'
-- ===========================================================================
do $$
declare n int;
begin
  perform test.ok((select role from public.profiles where id = '00000000-0000-0000-0000-00000000000a') = 'organizer',
                  'inscription : rôle organisateur par défaut');

  -- un client qui glisse role=admin dans ses métadonnées n'obtient rien
  insert into auth.users (id, email, raw_user_meta_data)
  values ('00000000-0000-0000-0000-0000000000f1', 'evil@test', '{"role":"admin","full_name":"Mallory"}');
  perform test.ok((select role from public.profiles where id = '00000000-0000-0000-0000-0000000000f1') = 'organizer',
                  'metadonnées role=admin ignorées à l''inscription');

  perform test.login('00000000-0000-0000-0000-00000000000a');
  perform test.fails($q$update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-00000000000a'$q$,
                     'permission denied', 'un utilisateur ne peut pas se promouvoir admin');
  perform test.fails($q$update public.profiles set disabled = false, created_by = null where id = '00000000-0000-0000-0000-00000000000a'$q$,
                     'permission denied', 'un utilisateur ne peut pas modifier disabled/created_by');
  update public.profiles set full_name = 'Alice' where id = '00000000-0000-0000-0000-00000000000a';
  get diagnostics n = row_count;
  perform test.ok(n = 1, 'un utilisateur modifie son propre nom');
  update public.profiles set full_name = 'Pirate' where id = '00000000-0000-0000-0000-00000000000b';
  get diagnostics n = row_count;
  perform test.ok(n = 0, 'un utilisateur ne modifie pas le profil d''un autre');
  perform test.ok((select count(*) from public.profiles where id = '00000000-0000-0000-0000-00000000000b') = 0,
                  'A ne voit pas le profil de B');
  perform test.ok((select count(*) from public.profiles where id = '00000000-0000-0000-0000-00000000000d') = 1,
                  'A voit son propre agent D');
  perform test.ok((select count(*) from public.profiles where id = '00000000-0000-0000-0000-00000000000e') = 0,
                  'A ne voit pas l''agent E de B');
  perform test.logout();

  perform test.login_anon();
  perform test.fails('select * from public.events', 'permission denied', 'anon ne lit pas events');
  perform test.fails('select * from public.profiles', 'permission denied', 'anon ne lit pas profiles');
  perform test.fails('select * from public.invitations', 'permission denied', 'anon ne lit pas invitations');
  perform test.logout();

  perform test.login('00000000-0000-0000-0000-00000000000c');
  perform test.ok((select count(*) from public.profiles) >= 5, 'admin voit tous les profils');
  perform test.logout();
end $$;

-- ===========================================================================
\echo '--- 2. Événements : isolation, statuts, versions'
-- ===========================================================================
do $$
declare
  v_a uuid; v_b uuid; v_tpl uuid; n int; v_ver int;
begin
  select id into v_tpl from public.templates where slug = 'mariage-classique';
  perform test.put('tpl', v_tpl::text);

  perform test.login('00000000-0000-0000-0000-00000000000a');
  insert into public.events (organizer_id, event_type, name, starts_at)
  values ('00000000-0000-0000-0000-00000000000a', 'wedding', 'Mariage de David et Sarah', '2027-01-16 16:00+00')
  returning id into v_a;
  perform test.put('ev_a', v_a::text);
  perform test.ok(v_a is not null, 'A crée un événement');

  perform test.fails($q$insert into public.events (organizer_id, event_type, name, starts_at)
      values ('00000000-0000-0000-0000-00000000000b', 'wedding', 'Faux', now())$q$,
      'row-level security', 'A ne peut pas créer un événement au nom de B');
  perform test.fails($q$insert into public.events (organizer_id, event_type, name, starts_at, status)
      values ('00000000-0000-0000-0000-00000000000a', 'wedding', 'X', now(), 'published')$q$,
      'permission denied', 'on ne crée pas un événement directement publié');
  perform test.fails($q$update public.events set organizer_id = '00000000-0000-0000-0000-00000000000b' where id = '$q$ || v_a || $q$'$q$,
      'permission denied', 'organizer_id n''est pas modifiable');
  perform test.fails($q$update public.events set version = 99 where id = '$q$ || v_a || $q$'$q$,
      'permission denied', 'version n''est pas modifiable à la main');
  perform test.logout();

  perform test.login('00000000-0000-0000-0000-00000000000b');
  insert into public.events (organizer_id, event_type, name, starts_at)
  values ('00000000-0000-0000-0000-00000000000b', 'birthday', 'Anniversaire de Paul', '2027-02-01 16:00+00')
  returning id into v_b;
  perform test.put('ev_b', v_b::text);
  perform test.ok((select count(*) from public.events) = 1, 'B ne voit que son événement');
  perform test.ok((select count(*) from public.events where id = v_a) = 0, 'B ne voit pas l''événement de A');
  update public.events set name = 'Piraté' where id = v_a;
  get diagnostics n = row_count;
  perform test.ok(n = 0, 'B ne modifie pas l''événement de A');
  delete from public.events where id = v_a;
  get diagnostics n = row_count;
  perform test.ok(n = 0, 'B ne supprime pas l''événement de A');
  perform test.ok((select count(*) from public.event_versions where event_id = v_a) = 0, 'B ne voit pas les versions de A');
  perform test.logout();

  perform test.login('00000000-0000-0000-0000-00000000000c');
  perform test.ok((select count(*) from public.events) = 2, 'admin voit tous les événements');
  update public.events set name = 'Admin' where id = v_a;
  get diagnostics n = row_count;
  perform test.ok(n = 0, 'admin n''écrit pas directement (passe par le serveur journalisé)');
  perform test.logout();

  -- Versions
  perform test.login('00000000-0000-0000-0000-00000000000a');
  perform test.ok((select version from public.events where id = v_a) = 1, 'version initiale = 1');
  perform test.ok((select count(*) from public.event_versions where event_id = v_a) = 1, 'instantané initial conservé');
  update public.events set name = 'Mariage de David & Sarah' where id = v_a;
  perform test.ok((select version from public.events where id = v_a) = 2, 'modifier le contenu incrémente la version');
  perform test.ok((select count(*) from public.event_versions where event_id = v_a) = 2, 'un instantané par version');
  perform test.ok((select snapshot ->> 'name' from public.event_versions where event_id = v_a and version = 1) = 'Mariage de David et Sarah',
                  'l''ancien contenu reste consultable dans l''instantané v1');
  update public.events set name = 'Mariage de David & Sarah' where id = v_a;   -- aucun changement réel
  perform test.ok((select version from public.events where id = v_a) = 2, 'une écriture identique ne crée pas de version');
  update public.events set status = 'pending_review' where id = v_a;
  perform test.ok((select version from public.events where id = v_a) = 2, 'un changement de statut ne crée pas de version');

  -- Statuts
  perform test.fails($q$update public.events set status = 'finished' where id = '$q$ || v_a || $q$'$q$,
      'invalid status transition', 'transition interdite pending_review -> finished');
  perform test.fails($q$update public.events set status = 'published' where id = '$q$ || v_a || $q$'$q$,
      'cannot publish', 'publication refusée sans lieu / personnes fêtées / modèle');
  update public.events
     set venue_name = 'Salle des fêtes', celebrated_names = 'David et Sarah', template_id = v_tpl
   where id = v_a;
  perform test.ok((select version from public.events where id = v_a) = 3, 'compléter les infos crée la version 3');
  update public.events set status = 'published' where id = v_a;
  perform test.ok((select status from public.events where id = v_a) = 'published', 'publication OK une fois complet');
  delete from public.events where id = v_a;
  get diagnostics n = row_count;
  perform test.ok(n = 0, 'un événement publié ne se supprime pas');
  perform test.logout();
end $$;

do $$
declare v_x uuid; n int;
begin
  perform test.login('00000000-0000-0000-0000-00000000000a');
  insert into public.events (organizer_id, event_type, name, starts_at)
  values ('00000000-0000-0000-0000-00000000000a', 'other', 'Brouillon jetable', now() + interval '30 days')
  returning id into v_x;
  delete from public.events where id = v_x;
  get diagnostics n = row_count;
  perform test.ok(n = 1, 'un brouillon se supprime');

  -- événement terminé : figé
  insert into public.events (organizer_id, event_type, name, starts_at, venue_name, celebrated_names, template_id)
  values ('00000000-0000-0000-0000-00000000000a', 'corporate', 'Séminaire', now() + interval '10 days', 'Hôtel', 'Équipe',
          (select id from public.templates where slug = 'evenement-professionnel'))
  returning id into v_x;
  perform test.put('ev_done', v_x::text);
  update public.events set status = 'published' where id = v_x;
  update public.events set status = 'finished'  where id = v_x;
  perform test.fails($q$update public.events set name = 'Modif tardive' where id = '$q$ || v_x || $q$'$q$,
      'can no longer be edited', 'un événement terminé n''est plus modifiable');
  perform test.fails($q$update public.events set status = 'draft' where id = '$q$ || v_x || $q$'$q$,
      'invalid status transition', 'un événement terminé ne revient pas en brouillon');
  perform test.logout();
end $$;

