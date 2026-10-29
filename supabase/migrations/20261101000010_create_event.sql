-- ============================================================================
-- Invitéo — migration 10 : création d'un événement depuis l'espace organisateur
--
--  * list_templates()  : modèles actifs (nom, type, palette, polices…) pour le choix du modèle
--                        et pour l'aperçu public (serveur). Données de présentation, rien de personnel.
--  * my_agents()       : agents créés par l'organisateur (ou tous pour un administrateur).
--  * create_event()    : crée l'événement, affecte les agents et le publie, en UNE transaction.
--                        Security invoker : les droits et la RLS de l'organisateur s'appliquent.
-- ============================================================================
create function public.list_templates()
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'slug', t.slug, 'name', t.name, 'event_type', t.event_type,
           'description', t.description, 'config', t.config) order by t.event_type, t.name), '[]'::jsonb)
    from public.templates t where t.is_active
$$;

create function public.my_agents()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or public.app_role() not in ('organizer', 'admin') then
    raise exception 'access denied' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', p.id, 'full_name', p.full_name, 'email', u.email) order by lower(p.full_name), u.email)
      from public.profiles p join auth.users u on u.id = p.id
     where p.role = 'agent' and not p.disabled and (p.created_by = auth.uid() or public.is_admin())
  ), '[]'::jsonb);
end $$;

create function public.create_event(p_data jsonb)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  v_id       uuid;
  v_tpl      uuid;
  v_slug     text := btrim(coalesce(p_data ->> 'template', ''));
  v_type     text := btrim(coalesce(p_data ->> 'event_type', ''));
  v_name     text := btrim(coalesce(p_data ->> 'name', ''));
  v_starts   timestamptz;
  v_program  jsonb := '[]'::jsonb;
  v_item     jsonb;
  v_agent    jsonb;
  v_stage    text := 'event';
  v_publish  boolean := coalesce((p_data ->> 'publish')::boolean, false);
  v_celeb    text := nullif(btrim(coalesce(p_data ->> 'celebrated_names', '')), '');
  v_venue    text := nullif(btrim(coalesce(p_data ->> 'venue_name', '')), '');
begin
  if auth.uid() is null or public.app_role() not in ('organizer', 'admin') then
    raise exception 'access denied' using errcode = '42501';
  end if;
  if jsonb_typeof(p_data) is distinct from 'object' then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;
  if v_name = '' then return jsonb_build_object('ok', false, 'error', 'name_required'); end if;
  if v_type not in ('wedding', 'birthday', 'baptism', 'graduation', 'corporate', 'other') then
    return jsonb_build_object('ok', false, 'error', 'type_invalid');
  end if;
  select id into v_tpl from public.templates where slug = v_slug and is_active;
  if v_tpl is null then return jsonb_build_object('ok', false, 'error', 'template_invalid'); end if;

  begin
    v_starts := (p_data ->> 'starts_at')::timestamptz;
  exception when others then v_starts := null;
  end;
  if v_starts is null then return jsonb_build_object('ok', false, 'error', 'date_invalid'); end if;

  if v_publish and (v_venue is null or v_celeb is null) then
    return jsonb_build_object('ok', false, 'error', 'publish_requires_venue_and_names');
  end if;

  if jsonb_typeof(p_data -> 'program') = 'array' then
    if jsonb_array_length(p_data -> 'program') > 30 then
      return jsonb_build_object('ok', false, 'error', 'program_too_long');
    end if;
    for v_item in select value from jsonb_array_elements(p_data -> 'program') loop
      if jsonb_typeof(v_item) = 'object' and btrim(coalesce(v_item ->> 'title', '')) <> '' then
        v_program := v_program || jsonb_build_object('time', left(btrim(coalesce(v_item ->> 'time', '')), 10),
                                                     'title', left(btrim(v_item ->> 'title'), 120));
      end if;
    end loop;
  end if;

  begin
    insert into public.events (organizer_id, event_type, name, celebrated_names, starts_at, venue_name, address,
                               maps_url, program, message, extra_info, template_id, rsvp_enabled, show_qr_on_page)
    values (auth.uid(), v_type, v_name, v_celeb, v_starts, v_venue,
            nullif(btrim(coalesce(p_data ->> 'address', '')), ''),
            nullif(btrim(coalesce(p_data ->> 'maps_url', '')), ''),
            v_program,
            nullif(btrim(coalesce(p_data ->> 'message', '')), ''),
            nullif(btrim(coalesce(p_data ->> 'extra_info', '')), ''),
            v_tpl,
            coalesce((p_data ->> 'rsvp_enabled')::boolean, false),
            coalesce((p_data ->> 'show_qr_on_page')::boolean, false))
    returning id into v_id;

    v_stage := 'agents';
    if jsonb_typeof(p_data -> 'agent_ids') = 'array' then
      for v_agent in select value from jsonb_array_elements(p_data -> 'agent_ids') loop
        insert into public.event_staff (event_id, agent_id) values (v_id, (v_agent #>> '{}')::uuid);
      end loop;
    end if;

    if v_publish then
      update public.events set status = 'published' where id = v_id;
    end if;
  exception
    when check_violation or string_data_right_truncation or invalid_text_representation then
      if v_stage = 'agents' then
        return jsonb_build_object('ok', false, 'error', 'agent_not_allowed');
      end if;
      -- (sous-transaction : l'événement partiellement créé est annulé)
      return jsonb_build_object('ok', false, 'error', 'invalid_field');
    when insufficient_privilege or foreign_key_violation or raise_exception then
      return jsonb_build_object('ok', false, 'error', 'agent_not_allowed');
    when unique_violation then
      return jsonb_build_object('ok', false, 'error', 'agent_duplicated');
  end;

  return jsonb_build_object('ok', true, 'id', v_id, 'status', case when v_publish then 'published' else 'draft' end);
end $$;

revoke all on function public.list_templates()  from public, anon;
revoke all on function public.my_agents()       from public, anon;
revoke all on function public.create_event(jsonb) from public, anon;
grant execute on function public.list_templates()    to authenticated, service_role;
grant execute on function public.my_agents()         to authenticated;
grant execute on function public.create_event(jsonb) to authenticated;
