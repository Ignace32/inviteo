-- ============================================================================
-- Invitéo — migration 7 : page d'invitation publique (phase 4)
--
-- La page /i/<jeton> est servie par une fonction serveur (Vercel) qui appelle ces
-- deux fonctions avec la clé service_role. Elles ne sont PAS appelables depuis le
-- navigateur (ni par anon, ni par authenticated) : le public n'a donc aucun accès
-- direct aux tables, seulement à ce que le serveur choisit de renvoyer.
--
--  * Le jeton du LIEN (view_token) est haché puis comparé. Le jeton du QR code
--    (qr_token) ne donne accès à rien ici.
--  * Aucune donnée personnelle superflue : ni e-mail ni téléphone de l'invité,
--    ni hachage, ni identifiants internes d'autres invités.
--  * Un événement non publié n'est jamais révélé (réponse « not_found »).
--  * Les états sont renvoyés en JSON ({state: ...}) : le serveur choisit le code HTTP.
-- ============================================================================

create function public.invitation_public_view(p_view_token text)
returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_token text := btrim(coalesce(p_view_token, ''));
  v_inv   public.invitations;
  v_ev    public.events;
  v_g     public.guests;
  v_t     public.templates;
  v_rsvp  public.rsvp_responses;
begin
  if char_length(v_token) not between 20 and 200 then
    return jsonb_build_object('state', 'not_found');
  end if;

  select i.* into v_inv
    from public.invitations i
    join public.invitation_secrets s on s.invitation_id = i.id
   where s.view_token_hash = public.hash_token(v_token);
  if not found then
    return jsonb_build_object('state', 'not_found');
  end if;

  select * into v_ev from public.events where id = v_inv.event_id;

  -- Brouillon ou en attente de validation : l'événement n'existe pas encore pour le public.
  if v_ev.status in ('draft', 'pending_review') then
    return jsonb_build_object('state', 'not_found');
  end if;
  if v_inv.status = 'revoked' then
    return jsonb_build_object('state', 'revoked');
  end if;
  if v_ev.status = 'cancelled' then
    return jsonb_build_object('state', 'cancelled', 'event', jsonb_build_object('name', v_ev.name));
  end if;
  if v_ev.status = 'finished' then
    return jsonb_build_object('state', 'event_closed', 'event', jsonb_build_object('name', v_ev.name));
  end if;
  if v_inv.status = 'expired' or (v_inv.expires_at is not null and v_inv.expires_at <= now()) then
    return jsonb_build_object('state', 'expired');
  end if;

  select * into v_g from public.guests where id = v_inv.guest_id;
  select * into v_t from public.templates where id = v_ev.template_id;
  select * into v_rsvp from public.rsvp_responses where invitation_id = v_inv.id;

  return jsonb_build_object(
    'state', 'ok',
    'event', jsonb_build_object(
      'name', v_ev.name, 'type', v_ev.event_type, 'celebrated_names', v_ev.celebrated_names,
      'starts_at', v_ev.starts_at, 'ends_at', v_ev.ends_at, 'timezone', v_ev.timezone,
      'venue_name', v_ev.venue_name, 'address', v_ev.address, 'maps_url', v_ev.maps_url,
      'program', v_ev.program, 'message', v_ev.message, 'extra_info', v_ev.extra_info,
      'theme', v_ev.theme, 'rsvp_enabled', v_ev.rsvp_enabled, 'show_qr', v_ev.show_qr_on_page,
      'version', v_ev.version),
    'template', case when v_t.id is null then null else jsonb_build_object(
      'slug', v_t.slug, 'name', v_t.name, 'version', v_t.version, 'config', v_t.config) end,
    'guest', jsonb_build_object('full_name', v_g.full_name, 'party_size', v_g.party_size, 'ticket_type', v_g.ticket_type),
    'invitation', jsonb_build_object('max_entries', v_inv.max_entries, 'entries_used', v_inv.entries_used),
    'rsvp', case when v_rsvp.id is null then null else jsonb_build_object(
      'attending', v_rsvp.attending, 'party_count', v_rsvp.party_count, 'song', v_rsvp.song,
      'note', v_rsvp.note, 'responded_at', v_rsvp.responded_at) end,
    'assets', coalesce((
      select jsonb_agg(jsonb_build_object('kind', a.kind, 'path', a.storage_path, 'alt', a.alt_text,
                                          'width', a.width, 'height', a.height) order by a.sort_order, a.created_at)
        from public.event_assets a where a.event_id = v_ev.id), '[]'::jsonb)
  );
end $$;

create function public.invitation_submit_rsvp(
  p_view_token  text,
  p_attending   boolean,
  p_party_count int  default null,
  p_song        text default null,
  p_note        text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_token text := btrim(coalesce(p_view_token, ''));
  v_inv   public.invitations;
  v_ev    public.events;
  v_g     public.guests;
  v_count int;
  v_song  text := nullif(left(btrim(coalesce(p_song, '')), 120), '');
  v_note  text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
begin
  if p_attending is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;
  if char_length(v_token) not between 20 and 200 then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select i.* into v_inv
    from public.invitations i
    join public.invitation_secrets s on s.invitation_id = i.id
   where s.view_token_hash = public.hash_token(v_token)
     for update of i;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select * into v_ev from public.events where id = v_inv.event_id;
  if v_ev.status <> 'published' or v_inv.status in ('revoked', 'expired')
     or (v_inv.expires_at is not null and v_inv.expires_at <= now()) then
    return jsonb_build_object('ok', false, 'error', 'closed');
  end if;
  if not v_ev.rsvp_enabled then
    return jsonb_build_object('ok', false, 'error', 'rsvp_disabled');
  end if;

  select * into v_g from public.guests where id = v_inv.guest_id;
  if p_attending then
    v_count := coalesce(p_party_count, v_g.party_size);
    if v_count < 1 or v_count > v_inv.max_entries then
      return jsonb_build_object('ok', false, 'error', 'invalid_party_count', 'max', v_inv.max_entries);
    end if;
  else
    v_count := 0;
    v_song := null;
  end if;

  insert into public.rsvp_responses (invitation_id, event_id, attending, party_count, song, note)
  values (v_inv.id, v_inv.event_id, p_attending, v_count, v_song, v_note)
  on conflict (invitation_id) do update
    set attending = excluded.attending, party_count = excluded.party_count,
        song = excluded.song, note = excluded.note,
        responded_at = now(), updated_at = now();

  return jsonb_build_object('ok', true, 'attending', p_attending, 'party_count', v_count);
end $$;

-- Réservées au serveur : ni le public (anon), ni un compte connecté ne peuvent les appeler.
revoke all on function public.invitation_public_view(text)                          from public, anon, authenticated;
revoke all on function public.invitation_submit_rsvp(text, boolean, int, text, text) from public, anon, authenticated;
grant execute on function public.invitation_public_view(text)                          to service_role;
grant execute on function public.invitation_submit_rsvp(text, boolean, int, text, text) to service_role;
