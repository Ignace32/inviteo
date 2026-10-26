-- ============================================================================
-- Invitéo — migration 3/5 : fonctions serveur (phase 3)
--
-- Émission, révocation et réémission des invitations. Ces fonctions sont les
-- SEULS chemins qui créent ou modifient des invitations : le navigateur n'a
-- aucun droit d'écriture sur ces tables (migration 2).
--
-- Les jetons en clair sont renvoyés UNE SEULE FOIS, à l'appelant, au moment de
-- l'émission. La base ne conserve que leur hachage SHA-256 : un lien perdu ne
-- peut pas être « retrouvé », il faut réémettre l'invitation (l'ancienne est
-- alors révoquée).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Jetons : 32 octets aléatoires (256 bits) issus de pgcrypto, encodés en base64url.
-- ---------------------------------------------------------------------------
create function public._new_token() returns text
language sql volatile set search_path = public, extensions as $$
  select translate(rtrim(encode(gen_random_bytes(32), 'base64'), '='), '+/', '-_')
$$;

create function public.hash_token(p_token text) returns bytea
language sql immutable set search_path = public, extensions as $$
  select digest(convert_to(p_token, 'UTF8'), 'sha256')
$$;

-- ---------------------------------------------------------------------------
-- Cœur d'émission (interne, non appelable depuis l'extérieur)
-- ---------------------------------------------------------------------------
create function public._issue_invitation(
  p_guest_id    uuid,
  p_issued_by   uuid,
  p_max_entries int,
  p_expires_at  timestamptz
) returns table (invitation_id uuid, guest_id uuid, view_token text, qr_token text)
language plpgsql security definer set search_path = public, extensions as $$
#variable_conflict use_column
declare
  g        public.guests;
  ev       public.events;
  v_view   text;
  v_qr     text;
  v_id     uuid;
begin
  select * into g from public.guests where id = p_guest_id;
  if not found then
    raise exception 'guest not found' using errcode = 'P0002';
  end if;

  select * into ev from public.events where id = g.event_id for share;
  if ev.status in ('finished', 'cancelled') then
    raise exception 'event is % : no invitation can be issued', ev.status using errcode = '23514';
  end if;

  if exists (select 1 from public.invitations i
             where i.guest_id = g.id and i.status in ('valid', 'used')) then
    raise exception 'guest already has an active invitation: revoke or reissue it'
      using errcode = '23505';
  end if;

  v_view := public._new_token();
  v_qr   := public._new_token();

  insert into public.invitations (event_id, guest_id, max_entries, expires_at, issued_by)
  values (g.event_id, g.id, coalesce(p_max_entries, g.party_size), p_expires_at, p_issued_by)
  returning id into v_id;

  insert into public.invitation_secrets (invitation_id, view_token_hash, qr_token_hash)
  values (v_id, public.hash_token(v_view), public.hash_token(v_qr));

  return query select v_id, g.id, v_view, v_qr;
end $$;

-- ---------------------------------------------------------------------------
-- Émission pour un invité
-- ---------------------------------------------------------------------------
create function public.issue_invitation(
  p_guest_id    uuid,
  p_max_entries int         default null,
  p_expires_at  timestamptz default null
) returns table (invitation_id uuid, guest_id uuid, view_token text, qr_token text)
language plpgsql security definer set search_path = public, extensions as $$
#variable_conflict use_column
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not exists (select 1 from public.guests g
                 where g.id = p_guest_id and public.owns_event(g.event_id)) then
    raise exception 'guest not found or access denied' using errcode = '42501';
  end if;
  if p_max_entries is not null and p_max_entries not between 1 and 20 then
    raise exception 'max_entries must be between 1 and 20' using errcode = '22023';
  end if;
  return query select * from public._issue_invitation(p_guest_id, auth.uid(), p_max_entries, p_expires_at);
end $$;

-- ---------------------------------------------------------------------------
-- Émission en lot : tous les invités de l'événement qui n'ont pas d'invitation active
-- ---------------------------------------------------------------------------
create function public.issue_invitations_for_event(p_event_id uuid)
returns table (invitation_id uuid, guest_id uuid, view_token text, qr_token text)
language plpgsql security definer set search_path = public, extensions as $$
#variable_conflict use_column
declare
  r record;
begin
  if auth.uid() is null or not public.owns_event(p_event_id) then
    raise exception 'event not found or access denied' using errcode = '42501';
  end if;

  for r in
    select g.id
    from public.guests g
    where g.event_id = p_event_id
      and not exists (select 1 from public.invitations i
                      where i.guest_id = g.id and i.status in ('valid', 'used'))
    order by g.created_at, g.id
    limit 2000
  loop
    return query select * from public._issue_invitation(r.id, auth.uid(), null, null);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Révocation (idempotente)
-- ---------------------------------------------------------------------------
create function public.revoke_invitation(p_invitation_id uuid, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  inv public.invitations;
begin
  select * into inv from public.invitations where id = p_invitation_id for update;
  if not found or auth.uid() is null or not public.owns_event(inv.event_id) then
    raise exception 'invitation not found or access denied' using errcode = '42501';
  end if;
  if inv.status = 'revoked' then
    return;
  end if;
  update public.invitations
     set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(),
         revoke_reason = left(p_reason, 300)
   where id = inv.id;
end $$;

-- ---------------------------------------------------------------------------
-- Réémission : révoque l'ancienne invitation puis en émet une nouvelle (nouveaux
-- jetons, nouveau QR code) pour le même invité.
-- ---------------------------------------------------------------------------
create function public.reissue_invitation(p_invitation_id uuid, p_reason text default null)
returns table (invitation_id uuid, guest_id uuid, view_token text, qr_token text)
language plpgsql security definer set search_path = public, extensions as $$
#variable_conflict use_column
declare
  inv public.invitations;
  n   record;
begin
  select * into inv from public.invitations where id = p_invitation_id for update;
  if not found or auth.uid() is null or not public.owns_event(inv.event_id) then
    raise exception 'invitation not found or access denied' using errcode = '42501';
  end if;
  if inv.replaced_by is not null then
    raise exception 'invitation was already reissued' using errcode = '23505';
  end if;

  if inv.status in ('valid', 'used') then
    update public.invitations
       set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(),
           revoke_reason = coalesce(left(p_reason, 300), 'reissued')
     where id = inv.id;
  end if;

  select * into n from public._issue_invitation(inv.guest_id, auth.uid(), inv.max_entries, inv.expires_at);
  update public.invitations set replaced_by = n.invitation_id where id = inv.id;

  return query select n.invitation_id, n.guest_id, n.view_token, n.qr_token;
end $$;

-- ---------------------------------------------------------------------------
-- Import d'invités en lot (SECURITY INVOKER : la RLS s'applique)
-- p_rows : tableau JSON [{full_name, phone?, email?, party_size?, ticket_type?, notes?}, ...]
-- Retourne {inserted, rejected:[{row, reason}]}. Les doublons (même nom + même
-- téléphone dans cet événement) sont ignorés, ce qui rend un ré-import sans danger.
-- ---------------------------------------------------------------------------
create function public.import_guests(p_event_id uuid, p_rows jsonb)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  r        jsonb;
  i        int := 0;
  n        int := 0;
  rej      jsonb := '[]'::jsonb;
  v_name   text;
  v_phone  text;
  v_email  text;
  v_party  int;
  v_ticket text;
  v_notes  text;
begin
  if auth.uid() is null or not public.owns_event(p_event_id) then
    raise exception 'event not found or access denied' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'p_rows must be a JSON array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) > 2000 then
    raise exception 'too many rows (max 2000 per import)' using errcode = '22023';
  end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    i := i + 1;
    v_name   := btrim(coalesce(r ->> 'full_name', ''));
    v_phone  := nullif(btrim(coalesce(r ->> 'phone', '')), '');
    v_email  := nullif(btrim(coalesce(r ->> 'email', '')), '');
    v_ticket := coalesce(nullif(btrim(coalesce(r ->> 'ticket_type', '')), ''), 'standard');
    v_notes  := nullif(btrim(coalesce(r ->> 'notes', '')), '');

    if v_name = '' then
      rej := rej || jsonb_build_object('row', i, 'reason', 'name_required'); continue;
    end if;
    if char_length(v_name) > 120 then
      rej := rej || jsonb_build_object('row', i, 'reason', 'name_too_long'); continue;
    end if;
    if v_phone is not null and v_phone !~ '^[0-9+()\-. ]{5,30}$' then
      rej := rej || jsonb_build_object('row', i, 'reason', 'phone_invalid'); continue;
    end if;
    if v_email is not null and (char_length(v_email) > 160 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then
      rej := rej || jsonb_build_object('row', i, 'reason', 'email_invalid'); continue;
    end if;
    if char_length(v_ticket) > 40 or char_length(coalesce(v_notes, '')) > 300 then
      rej := rej || jsonb_build_object('row', i, 'reason', 'field_too_long'); continue;
    end if;

    if nullif(btrim(coalesce(r ->> 'party_size', '')), '') is null then
      v_party := 1;
    elsif btrim(r ->> 'party_size') ~ '^\d{1,3}$' then
      v_party := btrim(r ->> 'party_size')::int;
    else
      rej := rej || jsonb_build_object('row', i, 'reason', 'party_size_invalid'); continue;
    end if;
    if v_party not between 1 and 20 then
      rej := rej || jsonb_build_object('row', i, 'reason', 'party_size_invalid'); continue;
    end if;

    if exists (select 1 from public.guests g
               where g.event_id = p_event_id
                 and lower(g.full_name) = lower(v_name)
                 and coalesce(g.phone, '') = coalesce(v_phone, '')) then
      rej := rej || jsonb_build_object('row', i, 'reason', 'duplicate'); continue;
    end if;

    insert into public.guests (event_id, full_name, phone, email, party_size, ticket_type, notes)
    values (p_event_id, v_name, v_phone, v_email, v_party, v_ticket, v_notes);
    n := n + 1;
  end loop;

  return jsonb_build_object('inserted', n, 'rejected', rej);
end $$;

-- ---------------------------------------------------------------------------
-- Agents : liste restreinte des événements qui leur sont affectés
-- (colonnes limitées au strict nécessaire au contrôle ; aucune donnée d'invités)
-- ---------------------------------------------------------------------------
create function public.my_assigned_events()
returns table (id uuid, name text, celebrated_names text, starts_at timestamptz, venue_name text, status text)
language sql stable security definer set search_path = public as $$
  select e.id, e.name, e.celebrated_names, e.starts_at, e.venue_name, e.status
  from public.event_staff es
  join public.events e on e.id = es.event_id
  where es.agent_id = auth.uid()
    and public.app_role() = 'agent'
    and e.status = 'published'
  order by e.starts_at
$$;

-- ---------------------------------------------------------------------------
-- Droits d'exécution : jamais anon ; les fonctions internes ne sont appelables
-- par personne (elles sont invoquées uniquement par les fonctions ci-dessus).
-- ---------------------------------------------------------------------------
-- PostgreSQL accorde EXECUTE à PUBLIC par défaut sur toute nouvelle fonction, et
-- Supabase l'accorde aussi à anon : on retire les deux partout dans le schéma, puis
-- on ne rend appelable que ce qui doit l'être. Les fonctions créées plus tard
-- (migration 5, phases suivantes) héritent de la même règle.
revoke execute on all functions in schema public from public, anon;
alter default privileges in schema public revoke execute on functions from public, anon;

-- (Les aides des politiques RLS gardent leur droit explicite pour « authenticated »,
-- accordé en migration 2 : le revoke ci-dessus ne vise que PUBLIC et anon.)

revoke all on function public._new_token()  from public, anon, authenticated;
revoke all on function public.hash_token(text) from public, anon, authenticated;
revoke all on function public._issue_invitation(uuid, uuid, int, timestamptz) from public, anon, authenticated;

grant execute on function public.issue_invitation(uuid, int, timestamptz)   to authenticated;
grant execute on function public.issue_invitations_for_event(uuid)          to authenticated;
grant execute on function public.revoke_invitation(uuid, text)              to authenticated;
grant execute on function public.reissue_invitation(uuid, text)             to authenticated;
grant execute on function public.import_guests(uuid, jsonb)                 to authenticated;
grant execute on function public.my_assigned_events()                       to authenticated;
