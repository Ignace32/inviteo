-- ============================================================================
-- Invitéo — migration 6/6 : contrôle d'entrée (phase 6) et statistiques (phase 7)
--
-- scan_invitation() est LA seule voie pour marquer une invitation comme utilisée.
-- Le navigateur n'a aucun droit d'écriture sur invitations / scan_logs.
--
-- Garanties :
--  * L'agent est authentifié, actif, et affecté à l'événement scanné.
--  * Le jeton reçu est haché (SHA-256) ; seul le hachage du QR code est comparé.
--    Le jeton du lien de la page ne permet PAS d'entrer.
--  * La ligne de l'invitation est verrouillée (FOR UPDATE) : deux scans simultanés
--    du même QR code sont sérialisés, un seul peut passer de « valid » à « used ».
--  * Un QR code valide pour un événement est refusé à l'entrée d'un autre.
--  * Idempotence : le même (agent, request_id) rejoué renvoie le résultat déjà
--    enregistré, sans compter l'entrée deux fois (coupure réseau puis nouvel essai).
--  * Chaque tentative est journalisée (scan_logs). Le jeton, entier ou partiel,
--    n'est jamais écrit dans les journaux.
-- ============================================================================

create function public.scan_invitation(p_event_id uuid, p_token text, p_request_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
#variable_conflict use_column
declare
  v_agent      uuid := auth.uid();
  v_prof       public.profiles;
  v_ev         public.events;
  v_inv        public.invitations;
  v_hash       bytea;
  v_fp         text;
  v_prev       public.scan_logs;
  v_result     text;
  v_reason     text;
  v_resp       jsonb;
  v_guest_name text;
  v_first_by   text;
  v_now        timestamptz := clock_timestamp();
  v_found      boolean := false;
  v_show       boolean := false;
begin
  if v_agent is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if p_request_id is null then
    raise exception 'request id required' using errcode = '22023';
  end if;

  select * into v_prof from public.profiles where id = v_agent;
  if not found then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  -- Empreinte courte du jeton (12 caractères du hachage) : sert à reconnaître un rejeu
  -- sans jamais stocker le jeton. Un jeton absent ou mal formé a aussi une empreinte.
  v_hash := public.hash_token(btrim(coalesce(p_token, '')));
  v_fp   := left(encode(v_hash, 'hex'), 12);

  -- Sérialise les rejeux simultanés d'une même requête.
  perform pg_advisory_xact_lock(hashtextextended(v_agent::text || ':' || p_request_id::text, 0));

  select * into v_prev from public.scan_logs where agent_id = v_agent and request_id = p_request_id;
  if found then
    if v_prev.event_id is distinct from p_event_id or v_prev.details ->> 'token_fp' is distinct from v_fp then
      raise exception 'request id already used for another scan' using errcode = '23505';
    end if;
    return (v_prev.details -> 'response') || jsonb_build_object('replayed', true);
  end if;

  select * into v_ev from public.events where id = p_event_id;
  if not found then
    -- Rien à journaliser : le journal est rattaché à un événement existant.
    return jsonb_build_object('result', 'forbidden', 'reason', 'unknown_event',
                              'replayed', false, 'scanned_at', v_now);
  end if;

  if v_prof.role <> 'agent' or v_prof.disabled then
    v_result := 'forbidden'; v_reason := 'not_an_active_agent';
  elsif not exists (select 1 from public.event_staff where event_id = p_event_id and agent_id = v_agent) then
    v_result := 'forbidden'; v_reason := 'not_assigned';
  elsif v_ev.status <> 'published' then
    v_result := 'forbidden'; v_reason := 'event_not_open';
  elsif btrim(coalesce(p_token, '')) = '' or char_length(btrim(p_token)) > 200 then
    v_result := 'invalid'; v_reason := 'malformed_token';
  else
    -- Seul le hachage du QR code est comparé : le jeton du lien de la page n'ouvre pas l'entrée.
    select i.* into v_inv
      from public.invitations i
      join public.invitation_secrets s on s.invitation_id = i.id
     where s.qr_token_hash = v_hash
       for update of i;
    v_found := found;

    if not v_found then
      v_result := 'invalid'; v_reason := 'unknown_token';
    elsif v_inv.event_id <> p_event_id then
      v_result := 'wrong_event'; v_reason := 'other_event';
    elsif v_inv.status = 'revoked' then
      v_result := 'revoked'; v_reason := 'revoked'; v_show := true;
    elsif v_inv.status = 'expired' or (v_inv.expires_at is not null and v_inv.expires_at <= v_now) then
      v_result := 'expired'; v_reason := 'expired'; v_show := true;
    elsif v_inv.status = 'used' then
      v_result := 'already_used'; v_reason := 'fully_used'; v_show := true;
    else
      -- Transition atomique : ligne verrouillée + condition rejouée dans l'UPDATE.
      update public.invitations
         set entries_used  = entries_used + 1,
             status        = case when entries_used + 1 >= max_entries then 'used' else status end,
             first_used_at = coalesce(first_used_at, v_now),
             first_used_by = coalesce(first_used_by, v_agent),
             last_used_at  = v_now
       where id = v_inv.id and status = 'valid' and entries_used < max_entries
       returning * into v_inv;
      if found then
        v_result := 'accepted'; v_reason := 'ok';
      else
        v_result := 'already_used'; v_reason := 'lost_race';
      end if;
      v_show := true;
    end if;
  end if;

  if v_show then
    select full_name into v_guest_name from public.guests where id = v_inv.guest_id;
  end if;
  if v_result = 'already_used' and v_inv.first_used_by is not null then
    select full_name into v_first_by from public.profiles where id = v_inv.first_used_by;
  end if;

  v_resp := jsonb_strip_nulls(jsonb_build_object(
    'result',           v_result,
    'reason',           case when v_result in ('forbidden') then v_reason end,
    'replayed',         false,
    'scanned_at',       v_now,
    'event_name',       v_ev.name,
    'agent_name',       v_prof.full_name,
    'guest_name',       v_guest_name,
    'entries_used',     case when v_show then v_inv.entries_used end,
    'max_entries',      case when v_show then v_inv.max_entries end,
    'first_scanned_at', case when v_result = 'already_used' then v_inv.first_used_at end,
    'first_scanned_by', v_first_by
  ));

  insert into public.scan_logs (request_id, event_id, invitation_id, agent_id, result, entries_after, scanned_at, details)
  values (p_request_id, p_event_id,
          case when v_result in ('accepted', 'already_used', 'revoked', 'expired') then v_inv.id end,
          v_agent, v_result,
          case when v_result in ('accepted', 'already_used') then v_inv.entries_used end,
          v_now,
          jsonb_build_object('reason', v_reason, 'token_fp', v_fp, 'response', v_resp));

  return v_resp;
end $$;

-- ---------------------------------------------------------------------------
-- Statistiques : calculées à partir des données serveur (invitations + journaux).
-- ---------------------------------------------------------------------------
create function public.event_stats(p_event_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  if not (public.owns_event(p_event_id) or public.is_admin()) then
    raise exception 'event not found or access denied' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'invitations_total',   count(*),
    'valid',               count(*) filter (where status = 'valid'),
    'used',                count(*) filter (where status = 'used'),
    'revoked',             count(*) filter (where status = 'revoked'),
    'expired',             count(*) filter (where status = 'expired'),
    'entries_validated',   coalesce(sum(entries_used), 0),
    'entries_authorized',  coalesce(sum(max_entries) filter (where status in ('valid', 'used')), 0)
  ) into v_out
  from public.invitations where event_id = p_event_id;

  v_out := v_out || jsonb_build_object(
    'duplicate_attempts', (select count(*) from public.scan_logs where event_id = p_event_id and result = 'already_used'),
    'refused_attempts',   (select count(*) from public.scan_logs where event_id = p_event_id
                            and result in ('invalid', 'wrong_event', 'revoked', 'expired', 'forbidden')),
    'last_entries', coalesce((
      select jsonb_agg(e order by (e ->> 'scanned_at') desc) from (
        select jsonb_build_object('guest_name', g.full_name, 'scanned_at', sl.scanned_at,
                                  'agent_name', p.full_name, 'entries_after', sl.entries_after) as e
          from public.scan_logs sl
          join public.invitations i on i.id = sl.invitation_id
          join public.guests g on g.id = i.guest_id
          join public.profiles p on p.id = sl.agent_id
         where sl.event_id = p_event_id and sl.result = 'accepted'
         order by sl.scanned_at desc limit 10) t), '[]'::jsonb)
  );
  return v_out;
end $$;

revoke all on function public.scan_invitation(uuid, text, uuid) from public, anon;
revoke all on function public.event_stats(uuid)                 from public, anon;
grant execute on function public.scan_invitation(uuid, text, uuid) to authenticated;
grant execute on function public.event_stats(uuid)                 to authenticated;
