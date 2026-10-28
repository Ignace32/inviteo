-- Suite : page d'invitation publique (phase 4) — continue la session des fichiers précédents.
-- Utilise les invitations créées par 50_scan_tests.sql (jetons dans test.ctx).

create function test.as_server(q text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role service_role';
  execute q into r;
  execute 'reset role';
  return r;
end $$;
grant execute on function test.as_server(text) to public;

-- ===========================================================================
\echo '--- 16. Page publique : lecture par le jeton du lien'
-- ===========================================================================
do $$
declare
  r jsonb;
  v text := test.get('view_jp');
begin
  r := test.as_server(format('select public.invitation_public_view(%L)', v));
  perform test.ok(r ->> 'state' = 'ok', 'lien valide : état « ok »');
  perform test.ok(r #>> '{guest,full_name}' = 'Jean-Pierre Mukendi', 'le nom exact de l''invité est renvoyé');
  perform test.ok(r #>> '{event,name}' = 'Mariage de David et Sarah', 'le nom de l''événement est renvoyé');
  perform test.ok(r #>> '{template,slug}' = 'mariage-classique' and r #> '{template,config,palette}' is not null,
                  'la configuration du modèle est renvoyée (palette, polices, ouverture)');
  perform test.ok(not (r::text ~* '(email|phone|hash|organizer_id|qr_token|view_token)'),
                  'aucune donnée sensible : ni e-mail, ni téléphone, ni hachage, ni identifiant de l''organisateur');
  perform test.ok(not (r::text like '%' || test.get('qr_jp') || '%') and not (r::text like '%' || v || '%'),
                  'la réponse ne contient aucun jeton');

  r := test.as_server(format('select public.invitation_public_view(%L)', test.get('qr_jp')));
  perform test.ok(r ->> 'state' = 'not_found', 'le jeton du QR code n''ouvre pas la page');
  r := test.as_server($q$select public.invitation_public_view('jeton-inconnu-mais-assez-long-pour-passer')$q$);
  perform test.ok(r ->> 'state' = 'not_found', 'jeton inconnu : « not_found »');
  r := test.as_server($q$select public.invitation_public_view('court')$q$);
  perform test.ok(r ->> 'state' = 'not_found', 'jeton trop court : « not_found »');
  r := test.as_server($q$select public.invitation_public_view(null)$q$);
  perform test.ok(r ->> 'state' = 'not_found', 'jeton absent : « not_found »');

  r := test.as_server(format('select public.invitation_public_view(%L)', test.get('view_rev')));
  perform test.ok(r ->> 'state' = 'revoked' and not (r ? 'event') and not (r ? 'guest'), 'invitation révoquée : état « revoked », rien d''autre');
  r := test.as_server(format('select public.invitation_public_view(%L)', test.get('view_exp')));
  perform test.ok(r ->> 'state' = 'expired' and not (r ? 'event'), 'invitation expirée : état « expired », rien d''autre');
  r := test.as_server(format('select public.invitation_public_view(%L)', test.get('view_drf')));
  perform test.ok(r ->> 'state' = 'not_found', 'événement non publié : jamais révélé');
end $$;

do $$
declare r jsonb;
begin
  update public.events set status = 'cancelled' where id = test.get('e2')::uuid;
  -- Événement annulé : seul son nom est renvoyé (l'invité peut être prévenu).
  r := test.as_server(format('select public.invitation_public_view(%L)', test.get('view_oth')));
  perform test.ok(r ->> 'state' = 'cancelled' and r #>> '{event,name}' = 'Mariage de Paul et Esther' and not (r ? 'guest'),
                  'événement annulé : état « cancelled », seul le nom est renvoyé');
end $$;

-- ===========================================================================
\echo '--- 17. Page publique : droits et confirmation de présence (RSVP)'
-- ===========================================================================
do $$
declare r jsonb; v text := test.get('view_jp'); vf text := test.get('view_fam');
        o1 uuid := '00000000-0000-0000-0000-000000000101';
begin
  -- Droits : réservé au serveur
  perform test.login_anon();
  perform test.fails(format('select public.invitation_public_view(%L)', v), 'permission denied', 'anon ne peut pas lire une invitation directement');
  perform test.fails(format('select public.invitation_submit_rsvp(%L, true)', v), 'permission denied', 'anon ne peut pas répondre directement');
  perform test.logout();
  perform test.login(o1);
  perform test.fails(format('select public.invitation_public_view(%L)', v), 'permission denied', 'un organisateur connecté ne passe pas par cette fonction');
  perform test.logout();

  -- RSVP désactivé par défaut
  r := test.as_server(format('select public.invitation_submit_rsvp(%L, true, 1)', v));
  perform test.ok(r ->> 'error' = 'rsvp_disabled', 'RSVP désactivé : réponse refusée');
  perform test.login(o1);
  update public.events set rsvp_enabled = true where id = test.get('e1')::uuid;
  perform test.logout();

  r := test.as_server(format('select public.invitation_submit_rsvp(%L, true, 1, %L, %L)', v, 'Waka Waka', 'Merci !'));
  perform test.ok((r ->> 'ok')::boolean and (r ->> 'party_count')::int = 1, 'RSVP : présence confirmée pour 1 personne');
  r := test.as_server(format('select public.invitation_submit_rsvp(%L, true, 2)', v));
  perform test.ok(r ->> 'error' = 'invalid_party_count', 'RSVP : plus de personnes que le billet n''en autorise : refusé');
  r := test.as_server(format('select public.invitation_submit_rsvp(%L, true, 0)', v));
  perform test.ok(r ->> 'error' = 'invalid_party_count', 'RSVP : 0 personne en « présent » : refusé');
  r := test.as_server(format('select public.invitation_submit_rsvp(%L, true, 3)', vf));
  perform test.ok((r ->> 'ok')::boolean and (r ->> 'party_count')::int = 3, 'RSVP : billet de 3, 3 personnes acceptées');
  r := test.as_server(format('select public.invitation_submit_rsvp(%L, null)', v));
  perform test.ok(r ->> 'error' = 'invalid_request', 'RSVP : réponse vide refusée');

  -- Une réponse par invitation, modifiable
  r := test.as_server(format('select public.invitation_submit_rsvp(%L, false)', v));
  perform test.ok((r ->> 'ok')::boolean and (r ->> 'party_count')::int = 0, 'RSVP : changement d''avis (absent)');
  perform test.ok((select count(*) from public.rsvp_responses where invitation_id = test.get('inv_jp')::uuid) = 1, 'une seule réponse par invitation');
  perform test.ok((select song from public.rsvp_responses where invitation_id = test.get('inv_jp')::uuid) is null, 'absent : pas de chanson conservée');
  r := test.as_server(format('select public.invitation_public_view(%L)', v));
  perform test.ok((r #>> '{rsvp,attending}')::boolean is false, 'la page affiche la dernière réponse');

  r := test.as_server(format('select public.invitation_submit_rsvp(%L, true, 1, %L)', v, repeat('x', 300)));
  perform test.ok(length((select song from public.rsvp_responses where invitation_id = test.get('inv_jp')::uuid)) = 120, 'la chanson est limitée à 120 caractères');

  -- Refus pour invitations révoquées / inconnues
  r := test.as_server(format('select public.invitation_submit_rsvp(%L, true, 1)', test.get('view_rev')));
  perform test.ok(r ->> 'error' = 'closed', 'RSVP refusé sur une invitation révoquée');
  r := test.as_server($q$select public.invitation_submit_rsvp('jeton-inconnu-mais-assez-long-pour-passer', true, 1)$q$);
  perform test.ok(r ->> 'error' = 'not_found', 'RSVP refusé sur un jeton inconnu');
  r := test.as_server(format('select public.invitation_submit_rsvp(%L, true, 1)', test.get('qr_fam')));
  perform test.ok(r ->> 'error' = 'not_found', 'le jeton du QR ne permet pas de répondre');
  perform test.ok((select count(*) from public.rsvp_responses where invitation_id = test.get('inv_rev')::uuid) = 0, 'aucune réponse enregistrée pour l''invitation révoquée');

  -- Le RSVP n'accorde aucune entrée : le statut d'entrée n'est pas touché
  perform test.ok((select entries_used from public.invitations where id = test.get('inv_una')::uuid) = 0, 'le RSVP ne modifie jamais les entrées');
end $$;
