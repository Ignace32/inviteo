-- Invitéo — créer l'événement d'une commande (à coller dans Supabase > SQL Editor).
-- Modifiez UNIQUEMENT les lignes marquées « À MODIFIER », puis cliquez Run. Une exécution = un événement.
do $$
declare
  -- ===== À MODIFIER ===================================================================================
  v_org_email    text := 'ignacelugoma08@gmail.com';        -- compte organisateur qui gère l'événement (le vôtre)
  v_type         text := 'wedding';                         -- wedding | birthday | baptism | graduation | corporate | other
  v_template     text := 'mariage-classique';               -- voir la liste des modèles ci-dessous
  v_name         text := 'Mariage de Awa et Jean';          -- titre affiché en haut de l'invitation
  v_celebrated   text := 'Awa & Jean';                      -- noms mis en avant (grand titre)
  v_starts       timestamptz := '2027-03-20 15:00+02';      -- date et heure (+02 = heure de Lubumbashi)
  v_venue        text := 'Salle Les Jardins';               -- nom du lieu
  v_address      text := '12 avenue de la Paix, Lubumbashi';
  v_message      text := 'Nous serons heureux de partager ce jour avec vous.';
  v_rsvp         boolean := true;                           -- les invités peuvent répondre (présent / absent)
  v_show_qr      boolean := true;                           -- le billet (QR) s'affiche sur la page de l'invité
  v_agent_emails text[] := array['25kk177si@udbl.ac.cd'];   -- agents de contrôle affectés ('{}' pour aucun)
  -- =====================================================================================================
  -- Modèles : mariage-classique, mariage-moderne (wedding) | anniversaire-elegant (birthday) | bapteme (baptism)
  --           remise-diplome (graduation) | evenement-professionnel (corporate)
  v_org uuid; v_ev uuid; v_tpl uuid; v_agent uuid; v_email text;
begin
  select id into v_org from auth.users where email = v_org_email;
  if v_org is null then raise exception 'organisateur introuvable : %', v_org_email; end if;
  select id into v_tpl from public.templates where slug = v_template and is_active;
  if v_tpl is null then raise exception 'modèle introuvable : %', v_template; end if;

  insert into public.events (organizer_id, event_type, name, celebrated_names, starts_at, venue_name, address,
                             message, rsvp_enabled, show_qr_on_page, template_id)
  values (v_org, v_type, v_name, v_celebrated, v_starts, v_venue, nullif(v_address, ''),
          nullif(v_message, ''), v_rsvp, v_show_qr, v_tpl)
  returning id into v_ev;

  foreach v_email in array v_agent_emails loop
    select p.id into v_agent from auth.users u join public.profiles p on p.id = u.id
     where u.email = v_email and p.role = 'agent' and not p.disabled;
    if v_agent is null then raise exception 'agent introuvable ou non activé : %', v_email; end if;
    insert into public.event_staff (event_id, agent_id) values (v_ev, v_agent);
  end loop;

  update public.events set status = 'published' where id = v_ev;   -- publié : pages d'invitation et scan actifs
  raise notice 'Événement créé et publié : % — ouvrez /organisateur pour importer les invités.', v_ev;
end $$;
