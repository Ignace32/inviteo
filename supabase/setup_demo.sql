-- Invitéo — mise en route en UNE fois : événement de démonstration + agent affecté.
-- À coller dans Supabase > SQL Editor. Remplacez seulement les deux e-mails en haut.
do $$
declare
  v_org_email   text := 'ignacelugoma08@gmail.com';   -- organisateur (compte déjà créé dans Authentication > Users)
  v_agent_email text := '25kk177si@udbl.ac.cd';       -- agent de contrôle (compte déjà créé)
  v_org uuid; v_agent uuid; v_ev uuid;
begin
  select id into v_org   from auth.users where email = v_org_email;
  select id into v_agent from auth.users where email = v_agent_email;
  if v_org is null   then raise exception 'organisateur introuvable : % (corrigez l''e-mail)', v_org_email; end if;
  if v_agent is null then raise exception 'agent introuvable : % (corrigez l''e-mail)', v_agent_email; end if;

  update public.profiles set role = 'agent', full_name = 'Agent de contrôle', created_by = v_org where id = v_agent;

  insert into public.events (organizer_id, event_type, name, celebrated_names, starts_at, venue_name, address,
                             message, rsvp_enabled, show_qr_on_page, template_id)
  values (v_org, 'wedding', 'Mariage de Awa et Jean', 'Awa & Jean', '2027-03-20 15:00+02', 'Salle Les Jardins',
          '12 avenue de la Paix, Lubumbashi', 'Nous serons heureux de partager ce jour avec vous.', true, true,
          (select id from public.templates where slug = 'mariage-classique'))
  returning id into v_ev;

  insert into public.event_staff (event_id, agent_id) values (v_ev, v_agent);
  update public.events set status = 'published' where id = v_ev;
  raise notice 'Terminé. Événement % publié, agent affecté.', v_ev;
end $$;
