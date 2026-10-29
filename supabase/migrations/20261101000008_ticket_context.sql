-- ============================================================================
-- Invitéo — migration 8 : données nécessaires à l'édition du PDF individuel (phase 5)
--
-- Le PDF est fabriqué par le serveur (Vercel) juste après l'émission ou la réémission
-- d'une invitation, car c'est le seul moment où le jeton du QR code existe en clair
-- (la base n'en garde que le hachage). Cette fonction renvoie à l'organisateur de
-- l'événement (ou à un administrateur) uniquement les champs imprimés sur le billet.
-- ============================================================================
create function public.ticket_context(p_invitation_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  select jsonb_build_object(
           'guest_name',       g.full_name,
           'party_size',       g.party_size,
           'max_entries',      i.max_entries,
           'ticket_type',      g.ticket_type,
           'status',           i.status,
           'event_name',       e.name,
           'celebrated_names', e.celebrated_names,
           'starts_at',        e.starts_at,
           'timezone',         e.timezone,
           'venue_name',       e.venue_name,
           'address',          e.address)
    into v
    from public.invitations i
    join public.guests g on g.id = i.guest_id
    join public.events e on e.id = i.event_id
   where i.id = p_invitation_id
     and auth.uid() is not null
     and (public.owns_event(e.id) or public.is_admin());
  if v is null then
    raise exception 'invitation not found or access denied' using errcode = '42501';
  end if;
  return v;
end $$;

revoke all on function public.ticket_context(uuid) from public, anon;
grant execute on function public.ticket_context(uuid) to authenticated;
