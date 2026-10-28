-- Invitéo — premier événement de démonstration (à exécuter dans Supabase > SQL Editor, rôle postgres).
-- Prérequis : le compte de l'organisateur existe (Authentication > Users). Remplacez l'e-mail ci-dessous.
-- Rien n'est publié tant que vous n'avez pas passé le statut à 'published' (dernière instruction).
do $$
declare
  v_org uuid;
  v_ev  uuid;
begin
  select id into v_org from auth.users where email = 'ORGANISATEUR@exemple.com';
  if v_org is null then raise exception 'organisateur introuvable : corrigez l''e-mail'; end if;

  insert into public.events (organizer_id, event_type, name, celebrated_names, starts_at, venue_name, address,
                             message, rsvp_enabled, show_qr_on_page, template_id)
  values (v_org, 'wedding', 'Mariage de Awa et Jean', 'Awa & Jean', '2027-03-20 15:00+02', 'Salle Les Jardins',
          '12 avenue de la Paix, Lubumbashi', 'Nous serons heureux de partager ce jour avec vous.', true, true,
          (select id from public.templates where slug = 'mariage-classique'))
  returning id into v_ev;

  update public.events set status = 'published' where id = v_ev;
  raise notice 'Événement créé : %', v_ev;
end $$;
