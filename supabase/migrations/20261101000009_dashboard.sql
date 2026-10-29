-- ============================================================================
-- Invitéo — migration 9 : tableau de bord organisateur (phase 7)
--
-- Deux fonctions de lecture, réservées au propriétaire de l'événement (ou à un administrateur).
-- Elles renvoient des agrégats et la liste des invités avec l'état de leur invitation ; jamais de
-- jeton ni de hachage. Les chiffres viennent des tables serveur (invitations, rsvp_responses).
-- ============================================================================
create function public.organizer_events()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(x order by (x ->> 'starts_at') desc) from (
      select jsonb_build_object(
        'id', e.id, 'name', e.name, 'event_type', e.event_type, 'status', e.status,
        'starts_at', e.starts_at, 'venue_name', e.venue_name,
        'guests_total',        (select count(*) from public.guests g where g.event_id = e.id),
        'invitations_active',  (select count(*) from public.invitations i where i.event_id = e.id and i.status in ('valid', 'used')),
        'entries_validated',   (select coalesce(sum(i.entries_used), 0) from public.invitations i where i.event_id = e.id),
        'rsvp_yes',            (select coalesce(sum(r.party_count), 0) from public.rsvp_responses r where r.event_id = e.id and r.attending),
        'rsvp_no',             (select count(*) from public.rsvp_responses r where r.event_id = e.id and not r.attending)
      ) as x
      from public.events e
      where e.organizer_id = auth.uid() or public.is_admin()
    ) t), '[]'::jsonb);
end $$;

create function public.event_guests(p_event_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not (public.owns_event(p_event_id) or public.is_admin()) then
    raise exception 'event not found or access denied' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'id', g.id, 'full_name', g.full_name, 'phone', g.phone, 'email', g.email,
        'party_size', g.party_size, 'ticket_type', g.ticket_type,
        'invitation', case when i.id is null then null else jsonb_build_object(
            'id', i.id, 'status', i.status, 'entries_used', i.entries_used, 'max_entries', i.max_entries,
            'first_used_at', i.first_used_at) end,
        'rsvp', case when r.id is null then null else jsonb_build_object(
            'attending', r.attending, 'party_count', r.party_count, 'responded_at', r.responded_at) end
      ) order by lower(g.full_name), g.created_at)
    from public.guests g
    left join public.invitations i on i.guest_id = g.id and i.status in ('valid', 'used', 'expired')
    left join public.rsvp_responses r on r.invitation_id = i.id
    where g.event_id = p_event_id), '[]'::jsonb);
end $$;

revoke all on function public.organizer_events()      from public, anon;
revoke all on function public.event_guests(uuid)      from public, anon;
grant execute on function public.organizer_events()   to authenticated;
grant execute on function public.event_guests(uuid)   to authenticated;
