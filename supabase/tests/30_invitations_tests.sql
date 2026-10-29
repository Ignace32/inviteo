-- Suite : invitations, jetons hachés, émission / révocation / réémission, intégrité

-- ===========================================================================
\echo '--- 6. Émission d''une invitation et jetons'
-- ===========================================================================
do $$
declare
  v_a  uuid := test.get('ev_a')::uuid;
  g    uuid := test.get('guest_jp')::uuid;
  r    record;
  n    int;
begin
  perform test.login('00000000-0000-0000-0000-00000000000a');
  select * into r from public.issue_invitation(g);
  perform test.put('inv_jp', r.invitation_id::text);
  perform test.put('tok_view_jp', r.view_token);
  perform test.put('tok_qr_jp', r.qr_token);

  perform test.ok(r.view_token ~ '^[A-Za-z0-9_-]{43}$' and r.qr_token ~ '^[A-Za-z0-9_-]{43}$',
                  'jetons de 43 caractères base64url (256 bits)');
  perform test.ok(r.view_token <> r.qr_token, 'le lien de la page et le QR code ont des jetons différents');
  perform test.ok((select max_entries from public.invitations where id = r.invitation_id) = 2,
                  'entrées autorisées = party_size de l''invité (règle explicite)');
  perform test.ok((select status || entries_used::text from public.invitations where id = r.invitation_id) = 'valid0',
                  'statut initial valid, 0 entrée');
  perform test.logout();

  -- Ce que la base contient réellement
  perform test.ok(exists (select 1 from public.invitation_secrets s
                          where s.invitation_id = r.invitation_id
                            and s.qr_token_hash   = extensions.digest(convert_to(r.qr_token,   'UTF8'), 'sha256')
                            and s.view_token_hash = extensions.digest(convert_to(r.view_token, 'UTF8'), 'sha256')),
                  'la base stocke le SHA-256 des jetons');
  select count(*) into n from public.invitation_secrets s
   where s::text like '%' || r.qr_token || '%' or s::text like '%' || r.view_token || '%';
  perform test.ok(n = 0, 'aucun jeton en clair dans invitation_secrets');
  select count(*) into n from public.invitations i
   where i::text like '%' || r.qr_token || '%' or i::text like '%' || r.view_token || '%';
  perform test.ok(n = 0, 'aucun jeton en clair dans invitations');
  select count(*) into n from public.guests x
   where x::text like '%' || r.qr_token || '%' or x::text like '%' || r.view_token || '%';
  perform test.ok(n = 0, 'aucun jeton en clair dans guests');
  perform test.ok(not exists (select 1 from information_schema.columns
                              where table_schema = 'public' and table_name = 'invitation_secrets'
                                and column_name ~ 'token$' and data_type <> 'bytea'),
                  'les colonnes de jeton sont binaires (hachage), jamais du texte');
  perform test.ok(r.qr_token not like '%' || replace(g::text, '-', '') || '%'
                  and r.qr_token not ilike '%mukendi%',
                  'le jeton ne contient ni identifiant ni nom de l''invité');

  -- Isolation et écriture directe interdite
  perform test.login('00000000-0000-0000-0000-00000000000a');
  perform test.fails(format('select public.issue_invitation(%L)', g), 'already has an active invitation',
                     'un invité ne reçoit pas deux invitations actives');
  perform test.fails('select * from public.invitation_secrets', 'permission denied',
                     'le navigateur ne lit pas invitation_secrets');
  perform test.fails(format($q$insert into public.invitations (event_id, guest_id) values (%L, %L)$q$, v_a, g),
                     'permission denied', 'le navigateur ne crée pas d''invitation directement');
  perform test.fails($q$update public.invitations set status = 'used'$q$,
                     'permission denied', 'le navigateur ne modifie pas le statut d''une invitation');
  perform test.fails($q$update public.invitations set max_entries = 20$q$,
                     'permission denied', 'le navigateur ne modifie pas les entrées autorisées');
  perform test.fails('delete from public.invitations', 'permission denied',
                     'le navigateur ne supprime pas d''invitation');
  perform test.fails(format('select public.issue_invitation(%L, 21)', test.get('guest_jp')), 'already has|between 1 and 20',
                     'max_entries hors bornes refusé');
  perform test.logout();

  perform test.login('00000000-0000-0000-0000-00000000000b');
  perform test.fails(format('select public.issue_invitation(%L)', g), 'access denied',
                     'B ne peut pas émettre pour un invité de A');
  perform test.fails(format('select public.revoke_invitation(%L)', r.invitation_id), 'access denied',
                     'B ne peut pas révoquer l''invitation de A');
  perform test.fails(format('select public.reissue_invitation(%L)', r.invitation_id), 'access denied',
                     'B ne peut pas réémettre l''invitation de A');
  perform test.ok((select count(*) from public.invitations) = 0, 'B ne voit aucune invitation de A');
  perform test.logout();

  perform test.login_anon();
  perform test.fails(format('select public.issue_invitation(%L)', g), 'permission denied', 'anon ne peut pas émettre');
  perform test.fails(format('select public.revoke_invitation(%L)', r.invitation_id), 'permission denied', 'anon ne peut pas révoquer');
  perform test.fails(format('select public.hash_token(%L)', 'x'), 'permission denied', 'hash_token n''est pas exposé');
  perform test.fails('select public._new_token()', 'permission denied', '_new_token n''est pas exposé');
  perform test.logout();
  perform test.login('00000000-0000-0000-0000-00000000000a');
  perform test.fails(format('select * from public._issue_invitation(%L, %L, 1, null)', g, '00000000-0000-0000-0000-00000000000a'),
                     'permission denied', 'le cœur d''émission interne n''est pas appelable directement');
  perform test.logout();
end $$;

-- ===========================================================================
\echo '--- 7. Émission en lot et unicité'
-- ===========================================================================
do $$
declare
  v_a uuid := test.get('ev_a')::uuid;
  n int;
begin
  perform test.login('00000000-0000-0000-0000-00000000000a');
  create temp table issued_1 on commit drop as
    select * from public.issue_invitations_for_event(v_a);
  select count(*) into n from issued_1;
  perform test.ok(n = 3, 'lot : 3 invités sans invitation ont reçu la leur (Marie, Paul, Grâce)');
  select count(*) into n from public.issue_invitations_for_event(v_a);
  perform test.ok(n = 0, 'lot : relancer ne réémet rien');

  insert into public.guests (event_id, full_name, party_size)
  select v_a, 'Invité ' || g, 1 + (g % 3) from generate_series(1, 400) g;
  create temp table issued_2 on commit drop as
    select * from public.issue_invitations_for_event(v_a);
  select count(*) into n from issued_2;
  perform test.ok(n = 400, 'lot : 400 invitations générées en une opération');
  perform test.ok((select count(distinct qr_token) from issued_2) = 400, 'lot : 400 QR codes tous différents');
  perform test.ok((select count(distinct view_token) from issued_2) = 400, 'lot : 400 liens tous différents');
  perform test.ok((select count(*) from (select qr_token from issued_1 union select qr_token from issued_2
                                         union select view_token from issued_1 union select view_token from issued_2
                                         union select test.get('tok_qr_jp') union select test.get('tok_view_jp')) u) = 808,
                  'aucun jeton partagé entre invités, liens et QR confondus (808 jetons distincts : 404 invitations x 2)');
  perform test.ok((select count(*) from public.invitations i join public.guests g on g.id = i.guest_id
                   where i.event_id = v_a and g.event_id = v_a) = 404, '404 invitations, chacune liée à son invité');
  perform test.ok((select count(*) from public.invitations where max_entries <> (select party_size from public.guests g where g.id = invitations.guest_id)) = 0,
                  'entrées autorisées alignées sur le type de billet de chaque invité');
  perform test.logout();

  perform test.ok((select count(distinct qr_token_hash) from public.invitation_secrets) = (select count(*) from public.invitation_secrets),
                  'hachages QR tous distincts en base');

  perform test.login('00000000-0000-0000-0000-00000000000b');
  perform test.fails(format('select * from public.issue_invitations_for_event(%L)', v_a), 'access denied',
                     'B ne peut pas lancer une émission en lot sur l''événement de A');
  perform test.logout();
end $$;

-- ===========================================================================
\echo '--- 8. Révocation et réémission'
-- ===========================================================================
do $$
declare
  v_a uuid := test.get('ev_a')::uuid;
  v_paul uuid; v_marie uuid;
  inv_paul uuid; inv_marie uuid;
  n record; old_qr bytea; new_qr bytea;
begin
  perform test.login('00000000-0000-0000-0000-00000000000a');
  select id into v_paul  from public.guests where event_id = v_a and full_name = 'Paul Ilunga';
  select id into v_marie from public.guests where event_id = v_a and full_name = 'Marie Kalala';
  select id into inv_paul  from public.invitations where guest_id = v_paul;
  select id into inv_marie from public.invitations where guest_id = v_marie;

  perform public.revoke_invitation(inv_paul, 'invité retiré de la liste');
  perform test.ok((select status from public.invitations where id = inv_paul) = 'revoked', 'révocation : statut revoked');
  perform test.ok((select revoked_by from public.invitations where id = inv_paul) = '00000000-0000-0000-0000-00000000000a'
                  and (select revoke_reason from public.invitations where id = inv_paul) = 'invité retiré de la liste'
                  and (select revoked_at from public.invitations where id = inv_paul) is not null,
                  'révocation : auteur, motif et date consignés');
  perform public.revoke_invitation(inv_paul);
  perform test.ok(true, 'révoquer deux fois ne provoque pas d''erreur (idempotent)');

  select * into n from public.issue_invitation(v_paul);
  perform test.ok(n.invitation_id <> inv_paul, 'après révocation, une nouvelle invitation peut être émise pour l''invité');
  perform test.fails(format('select * from public.reissue_invitation(%L)', inv_paul), 'already has an active invitation',
                     'on ne réémet pas une ancienne invitation si l''invité en a déjà une active');

  -- Réémission d'une invitation active
  perform test.logout();
  select qr_token_hash into old_qr from public.invitation_secrets where invitation_id = inv_marie;
  perform test.login('00000000-0000-0000-0000-00000000000a');
  select * into n from public.reissue_invitation(inv_marie, 'lien perdu');
  perform test.logout();
  select qr_token_hash into new_qr from public.invitation_secrets where invitation_id = n.invitation_id;
  perform test.ok(old_qr <> new_qr, 'réémission : nouveau QR code, différent de l''ancien');
  perform test.ok((select status from public.invitations where id = inv_marie) = 'revoked'
                  and (select replaced_by from public.invitations where id = inv_marie) = n.invitation_id,
                  'réémission : l''ancienne est révoquée et pointe vers la nouvelle');
  perform test.ok((select status from public.invitations where id = n.invitation_id) = 'valid', 'réémission : la nouvelle est valide');
  perform test.ok(not exists (select 1 from public.invitation_secrets s
                              where s.qr_token_hash = extensions.digest(convert_to(n.qr_token, 'UTF8'), 'sha256')
                                and s.invitation_id = inv_marie),
                  'le nouveau jeton n''ouvre pas l''ancienne invitation');
  perform test.login('00000000-0000-0000-0000-00000000000a');
  perform test.fails(format('select * from public.reissue_invitation(%L)', inv_marie), 'already reissued',
                     'une invitation ne peut être réémise qu''une fois');
  perform test.ok((select count(*) from public.invitations where guest_id = v_marie and status in ('valid','used')) = 1,
                  'toujours une seule invitation active par invité');
  perform test.logout();
end $$;

-- ===========================================================================
\echo '--- 9. Intégrité imposée par la base (même en cas de bug applicatif)'
-- ===========================================================================
do $$
declare
  v_a uuid := test.get('ev_a')::uuid;
  v_b uuid := test.get('ev_b')::uuid;
  g_jp uuid := test.get('guest_jp')::uuid;
  inv uuid := test.get('inv_jp')::uuid;
  v_fin uuid; g_fin uuid; g_free uuid;
begin
  -- Invité de l'événement A SANS invitation : sinon l'index « une seule invitation active »
  -- se déclencherait avant la clé étrangère et le test ne vérifierait pas la bonne règle.
  insert into public.guests (event_id, full_name) values (v_a, 'Invité sans invitation') returning id into g_free;
  perform test.fails(format($q$insert into public.invitations (event_id, guest_id) values (%L, %L)$q$, v_b, g_free),
                     'foreign key', 'une invitation ne peut pas lier un invité à un autre événement');
  delete from public.guests where id = g_free;
  perform test.fails(format($q$insert into public.invitations (event_id, guest_id) values (%L, %L)$q$, v_a, g_jp),
                     'invitations_one_active_per_guest|duplicate key', 'index unique : une seule invitation active par invité');
  perform test.fails(format($q$update public.invitations set status = 'used' where id = %L$q$, inv),
                     'check constraint', 'used exige entries_used = max_entries');
  perform test.fails(format($q$update public.invitations set entries_used = 99 where id = %L$q$, inv),
                     'check constraint', 'entries_used ne dépasse jamais max_entries');
  perform test.fails(format($q$update public.invitations set status = 'revoked' where id = %L$q$, inv),
                     'check constraint', 'revoked exige une date de révocation');
  perform test.fails(format($q$insert into public.invitation_secrets (invitation_id, view_token_hash, qr_token_hash)
                              values (%L, '\x0102', '\x0304')$q$, inv),
                     'check constraint|duplicate key', 'un hachage doit faire 32 octets');
  perform test.fails(format($q$insert into public.invitation_secrets (invitation_id, view_token_hash, qr_token_hash)
                              select %L, qr_token_hash, qr_token_hash from public.invitation_secrets limit 1$q$, inv),
                     'check constraint|duplicate key', 'lien et QR ne peuvent pas partager le même jeton');
  perform test.fails(format('delete from public.guests where id = %L', g_jp),
                     'foreign key', 'on ne supprime pas un invité qui a une invitation (traçabilité)');

  -- Événement terminé : plus d'émission
  perform test.login('00000000-0000-0000-0000-00000000000a');
  insert into public.events (organizer_id, event_type, name, starts_at, venue_name, celebrated_names, template_id)
  values ('00000000-0000-0000-0000-00000000000a', 'corporate', 'Conférence passée', now() + interval '5 days', 'Hôtel', 'Équipe',
          (select id from public.templates where slug = 'evenement-professionnel'))
  returning id into v_fin;
  insert into public.guests (event_id, full_name) values (v_fin, 'Retardataire') returning id into g_fin;
  update public.events set status = 'published' where id = v_fin;
  update public.events set status = 'finished'  where id = v_fin;
  perform test.fails(format('select public.issue_invitation(%L)', g_fin), 'no invitation can be issued',
                     'aucune émission pour un événement terminé');
  perform test.logout();
end $$;
