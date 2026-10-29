-- ============================================================================
-- Invitéo — migration 11 : huit modèles « design », photos remplaçables, modification d'un événement
--
--  * 8 nouveaux modèles (config.design = nom de la composition dessinée par le serveur).
--    Chaque modèle déclare ses zones photo (config.slots) : proportions du recadrage et libellé.
--  * set_event_photo / remove_event_photo : enregistrent ou retirent une photo (fichier dans le bucket privé
--    « event-assets », référence ici). Security invoker : la RLS du propriétaire s'applique.
--  * event_for_edit / update_event : relire et modifier un événement (champs, modèle, couleurs).
--  * event_preview_data : lecture serveur pour l'aperçu d'un événement (service_role uniquement).
-- Aucun modèle ni aucune politique existants ne sont modifiés.
-- ============================================================================

insert into public.templates (slug, name, event_type, description, config) values
('monogramme-sable', 'Monogramme sable', 'wedding',
 'Initiales des mariés, date en rubrique et photo à bord pinceau. Sobre et éditorial.',
 '{"layout":"design","design":"monogramme","palette":{"bg":"#ECE8E3","paper":"#FFFFFF","text":"#1F1B18","muted":"#6E6760","accent":"#8C6B4F"},
   "fonts":{"display":"Cormorant Garamond","body":"Cormorant Garamond","script":"Pinyon Script"},
   "labels":{"kicker":"Ensemble pour la vie","script":"nous disons oui.","invited":"Vous êtes invités","hour":"Heure"},
   "cover":"envelope","photos":{"min":0,"max":5},"slots":{"hero":{"ratio":0.371,"label":"Photo du couple (bande verticale)"}}}'),

('arche-doree', 'Arche dorée', 'wedding',
 'Photo en arche, branches dorées au trait et date sur trois colonnes.',
 '{"layout":"design","design":"arche-doree","palette":{"bg":"#EDE5D6","paper":"#FBF8F1","text":"#2A241D","muted":"#6E6558","accent":"#B8935A"},
   "fonts":{"display":"Playfair Display","body":"Cormorant Garamond","script":"Great Vibes"},
   "labels":{"kicker":"Le mariage de","invited":"Vous invitent à célébrer leur union"},
   "cover":"envelope","photos":{"min":0,"max":5},"slots":{"hero":{"ratio":0.974,"label":"Photo du couple (arche)"}}}'),

('sauge-programme', 'Sauge et programme', 'wedding',
 'Aquarelle sauge, photo en arche et frise du programme avec icônes.',
 '{"layout":"design","design":"sauge","palette":{"bg":"#F4F0E6","paper":"#FFFFFF","text":"#4F5B3C","muted":"#7A8465","accent":"#7C8A67"},
   "fonts":{"display":"Cormorant Garamond","body":"Cormorant Garamond","script":"Pinyon Script"},
   "labels":{"kicker":"Invitation à notre mariage"},
   "cover":"seal","photos":{"min":0,"max":5},"slots":{"hero":{"ratio":0.534,"label":"Photo du couple (arche)"}}}'),

('save-the-date-photo', 'Save the date photo', 'wedding',
 'Photo plein cadre et titre centré pour annoncer la date.',
 '{"layout":"design","design":"save-the-date","palette":{"bg":"#CFE0EE","paper":"#FFFFFF","text":"#3B2A22","muted":"#6B5A50","accent":"#3B2A22"},
   "fonts":{"display":"Cinzel","body":"Cormorant Garamond","script":"Great Vibes"},
   "labels":{"kicker":"Notez","script":"la date"},
   "cover":"seal","photos":{"min":0,"max":5},"slots":{"hero":{"ratio":0.5625,"label":"Photo plein cadre (vertical)"}}}'),

('fiancailles-plein-ecran', 'Fiançailles plein écran', 'wedding',
 'Format vertical type story : photo plein cadre et texte blanc.',
 '{"layout":"design","design":"fiancailles","palette":{"bg":"#8C8378","paper":"#FFFFFF","text":"#FFFFFF","muted":"#E9E4DC","accent":"#FFFFFF"},
   "fonts":{"display":"Bodoni Moda","body":"Cormorant Garamond","script":"Great Vibes"},
   "labels":{"kicker":"Vous êtes invités aux fiançailles de","closing":"Nous avons hâte de célébrer avec vous !","save":"Notez la date"},
   "cover":"curtain","photos":{"min":0,"max":5},"slots":{"hero":{"ratio":0.5625,"label":"Photo plein cadre (vertical)"}}}'),

('romance-doree', 'Romance dorée', 'wedding',
 'Photo lumineuse, écriture dorée, pétales qui tombent doucement et informations avec icônes.',
 '{"layout":"design","design":"romance","palette":{"bg":"#F3EEE4","paper":"#FFFFFF","text":"#4A3B2A","muted":"#7A6A55","accent":"#B8893C"},
   "fonts":{"display":"Cinzel","body":"Cormorant Garamond","script":"Great Vibes"},
   "labels":{"kicker":"Avec beaucoup d''amour, nous vous invitons à célébrer notre","title":"Mariage","at":"À"},
   "cover":"envelope","photos":{"min":0,"max":5},"slots":{"hero":{"ratio":0.714,"label":"Photo plein cadre"}}}'),

('aquarelle-bleu', 'Aquarelle bleue', 'wedding',
 'Cadre doré, fleurs bleues et blanches, aquarelle légère et médaillon d''initiales.',
 '{"layout":"design","design":"aquarelle-bleu","palette":{"bg":"#F5F7FA","paper":"#FFFFFF","text":"#1E3358","muted":"#5A6B88","accent":"#B8953E","wash":"#A9C0DC"},
   "fonts":{"display":"Cormorant Garamond","body":"Cormorant Garamond","script":"Pinyon Script"},
   "labels":{"kicker":"Avec leurs familles","invited":"Vous invitent à célébrer leur mariage"},
   "cover":"envelope","photos":{"min":0,"max":5},"slots":{"hero":{"ratio":0.677,"label":"Portrait du couple (médaillon)"}}}'),

('arche-creme', 'Arche crème', 'wedding',
 'Fleurs en relief ton sur ton, panneau en arche et format vertical.',
 '{"layout":"design","design":"arche-creme","palette":{"bg":"#E7DFD2","paper":"#F8F5EE","text":"#5C4A3A","muted":"#8A7A68","accent":"#8A6F52"},
   "fonts":{"display":"Cormorant Garamond","body":"Cormorant Garamond","script":"Great Vibes"},
   "labels":{"script":"Jour de mariage","kicker":"Invitation de mariage","invited":"Nous serons heureux de partager avec vous ce moment de joie."},
   "cover":"curtain","photos":{"min":0,"max":5},"slots":{"hero":{"ratio":1.177,"label":"Photo du couple (arche)"}}}');

-- ---------------------------------------------------------------------------
-- Photos d'un événement
-- ---------------------------------------------------------------------------
create function public.set_event_photo(
  p_event_id uuid, p_kind text, p_path text, p_width int, p_height int, p_alt text default null
) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  v_status text;
  v_old    text[];
  v_id     uuid;
  v_order  int;
begin
  if auth.uid() is null or public.app_role() not in ('organizer', 'admin') then
    raise exception 'access denied' using errcode = '42501';
  end if;
  if p_kind not in ('cover', 'photo') then return jsonb_build_object('ok', false, 'error', 'invalid_kind'); end if;
  if p_path is null or p_path !~ ('^' || p_event_id::text || '/[A-Za-z0-9._-]{1,120}\.(jpg|png|webp)$') then
    return jsonb_build_object('ok', false, 'error', 'invalid_path');
  end if;
  if coalesce(p_width, 0) not between 1 and 20000 or coalesce(p_height, 0) not between 1 and 20000 then
    return jsonb_build_object('ok', false, 'error', 'invalid_size');
  end if;
  select status into v_status from public.events where id = p_event_id;   -- la RLS limite aux événements du propriétaire
  if v_status is null then raise exception 'event not found or access denied' using errcode = '42501'; end if;
  if v_status in ('finished', 'cancelled') then return jsonb_build_object('ok', false, 'error', 'event_locked'); end if;

  if p_kind = 'cover' then
    select coalesce(array_agg(storage_path), '{}') into v_old from public.event_assets where event_id = p_event_id and kind = 'cover';
    delete from public.event_assets where event_id = p_event_id and kind = 'cover';
    v_order := 0;
  else
    if (select count(*) from public.event_assets where event_id = p_event_id and kind = 'photo') >= 5 then
      return jsonb_build_object('ok', false, 'error', 'too_many_photos');
    end if;
    v_old := '{}';
    select coalesce(max(sort_order), 0) + 1 into v_order from public.event_assets where event_id = p_event_id;
  end if;

  insert into public.event_assets (event_id, kind, storage_path, alt_text, width, height, sort_order)
  values (p_event_id, p_kind, p_path, nullif(left(btrim(coalesce(p_alt, '')), 200), ''), p_width, p_height, v_order)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'replaced', to_jsonb(v_old));
end $$;

create function public.remove_event_photo(p_asset_id uuid)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare v_path text;
begin
  if auth.uid() is null or public.app_role() not in ('organizer', 'admin') then
    raise exception 'access denied' using errcode = '42501';
  end if;
  delete from public.event_assets a
   using public.events e
   where a.id = p_asset_id and e.id = a.event_id and e.status not in ('finished', 'cancelled')
  returning a.storage_path into v_path;
  if v_path is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return jsonb_build_object('ok', true, 'path', v_path);
end $$;

-- ---------------------------------------------------------------------------
-- Relire / modifier un événement
-- ---------------------------------------------------------------------------
create function public.event_for_edit(p_event_id uuid)
returns jsonb
language plpgsql stable security invoker set search_path = public as $$
declare v_ev public.events; v_slug text;
begin
  if auth.uid() is null or public.app_role() not in ('organizer', 'admin') then
    raise exception 'access denied' using errcode = '42501';
  end if;
  select * into v_ev from public.events where id = p_event_id;
  if not found then raise exception 'event not found or access denied' using errcode = '42501'; end if;
  select slug into v_slug from public.templates where id = v_ev.template_id;
  return jsonb_build_object(
    'event', jsonb_build_object(
      'id', v_ev.id, 'status', v_ev.status, 'event_type', v_ev.event_type, 'name', v_ev.name,
      'celebrated_names', v_ev.celebrated_names, 'starts_at', v_ev.starts_at, 'timezone', v_ev.timezone,
      'venue_name', v_ev.venue_name, 'address', v_ev.address, 'maps_url', v_ev.maps_url,
      'program', v_ev.program, 'message', v_ev.message, 'extra_info', v_ev.extra_info,
      'template', v_slug, 'palette', coalesce(v_ev.theme -> 'palette', '{}'::jsonb),
      'rsvp_enabled', v_ev.rsvp_enabled, 'show_qr_on_page', v_ev.show_qr_on_page, 'version', v_ev.version),
    'photos', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'kind', a.kind, 'path', a.storage_path,
                                          'width', a.width, 'height', a.height, 'alt', a.alt_text)
                       order by a.sort_order, a.created_at)
        from public.event_assets a where a.event_id = v_ev.id), '[]'::jsonb));
end $$;

create function public.update_event(p_event_id uuid, p_data jsonb)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  v_ev      public.events;
  v_tpl     uuid;
  v_starts  timestamptz;
  v_program jsonb;
  v_theme   jsonb;
  v_pal     jsonb := '{}'::jsonb;
  v_item    jsonb;
  v_k       text;
  v_name    text;
  v_celeb   text;
  v_venue   text;
  v_publish boolean := coalesce((p_data ->> 'publish')::boolean, false);
begin
  if auth.uid() is null or public.app_role() not in ('organizer', 'admin') then
    raise exception 'access denied' using errcode = '42501';
  end if;
  if jsonb_typeof(p_data) is distinct from 'object' then return jsonb_build_object('ok', false, 'error', 'invalid_request'); end if;

  select * into v_ev from public.events where id = p_event_id;
  if not found then raise exception 'event not found or access denied' using errcode = '42501'; end if;
  if v_ev.status in ('finished', 'cancelled') then return jsonb_build_object('ok', false, 'error', 'event_locked'); end if;

  v_name  := case when p_data ? 'name' then btrim(coalesce(p_data ->> 'name', '')) else v_ev.name end;
  if v_name = '' then return jsonb_build_object('ok', false, 'error', 'name_required'); end if;
  v_celeb := case when p_data ? 'celebrated_names' then nullif(btrim(coalesce(p_data ->> 'celebrated_names', '')), '') else v_ev.celebrated_names end;
  v_venue := case when p_data ? 'venue_name' then nullif(btrim(coalesce(p_data ->> 'venue_name', '')), '') else v_ev.venue_name end;

  v_tpl := v_ev.template_id;
  if p_data ? 'template' then
    select id into v_tpl from public.templates where slug = p_data ->> 'template' and is_active;
    if v_tpl is null then return jsonb_build_object('ok', false, 'error', 'template_invalid'); end if;
  end if;

  v_starts := v_ev.starts_at;
  if p_data ? 'starts_at' then
    begin v_starts := (p_data ->> 'starts_at')::timestamptz; exception when others then v_starts := null; end;
    if v_starts is null then return jsonb_build_object('ok', false, 'error', 'date_invalid'); end if;
  end if;

  v_program := v_ev.program;
  if p_data ? 'program' then
    v_program := '[]'::jsonb;
    if jsonb_typeof(p_data -> 'program') = 'array' then
      if jsonb_array_length(p_data -> 'program') > 30 then return jsonb_build_object('ok', false, 'error', 'program_too_long'); end if;
      for v_item in select value from jsonb_array_elements(p_data -> 'program') loop
        if jsonb_typeof(v_item) = 'object' and btrim(coalesce(v_item ->> 'title', '')) <> '' then
          v_program := v_program || jsonb_build_object('time', left(btrim(coalesce(v_item ->> 'time', '')), 10),
                                                       'title', left(btrim(v_item ->> 'title'), 120));
        end if;
      end loop;
    end if;
  end if;

  v_theme := v_ev.theme;
  if p_data ? 'palette' then
    if jsonb_typeof(p_data -> 'palette') is distinct from 'object' then return jsonb_build_object('ok', false, 'error', 'invalid_field'); end if;
    for v_k in select jsonb_object_keys(p_data -> 'palette') loop
      if v_k not in ('bg', 'paper', 'text', 'muted', 'accent', 'wash') then return jsonb_build_object('ok', false, 'error', 'invalid_field'); end if;
      if coalesce(p_data -> 'palette' ->> v_k, '') !~ '^#[0-9a-fA-F]{6}$' then return jsonb_build_object('ok', false, 'error', 'invalid_field'); end if;
      v_pal := v_pal || jsonb_build_object(v_k, p_data -> 'palette' ->> v_k);
    end loop;
    v_theme := (v_ev.theme - 'palette') || case when v_pal = '{}'::jsonb then '{}'::jsonb else jsonb_build_object('palette', v_pal) end;
  end if;

  if v_publish and v_ev.status = 'draft' and (v_venue is null or v_celeb is null) then
    return jsonb_build_object('ok', false, 'error', 'publish_requires_venue_and_names');
  end if;

  begin
    update public.events set
      name = v_name,
      celebrated_names = v_celeb,
      venue_name = v_venue,
      starts_at = v_starts,
      template_id = v_tpl,
      program = v_program,
      theme = v_theme,
      address    = case when p_data ? 'address'    then nullif(btrim(coalesce(p_data ->> 'address', '')), '')    else address end,
      maps_url   = case when p_data ? 'maps_url'   then nullif(btrim(coalesce(p_data ->> 'maps_url', '')), '')   else maps_url end,
      message    = case when p_data ? 'message'    then nullif(btrim(coalesce(p_data ->> 'message', '')), '')    else message end,
      extra_info = case when p_data ? 'extra_info' then nullif(btrim(coalesce(p_data ->> 'extra_info', '')), '') else extra_info end,
      rsvp_enabled    = case when p_data ? 'rsvp_enabled'     then coalesce((p_data ->> 'rsvp_enabled')::boolean, false)     else rsvp_enabled end,
      show_qr_on_page = case when p_data ? 'show_qr_on_page'  then coalesce((p_data ->> 'show_qr_on_page')::boolean, false)  else show_qr_on_page end
    where id = p_event_id;
    if v_publish and v_ev.status = 'draft' then
      update public.events set status = 'published' where id = p_event_id;
    end if;
  exception
    when check_violation or string_data_right_truncation or invalid_text_representation then
      return jsonb_build_object('ok', false, 'error', 'invalid_field');
  end;
  return jsonb_build_object('ok', true, 'version', (select version from public.events where id = p_event_id),
                            'status', (select status from public.events where id = p_event_id));
end $$;

-- ---------------------------------------------------------------------------
-- Lecture serveur pour l'aperçu d'un événement (même forme que la page publique)
-- ---------------------------------------------------------------------------
create function public.event_preview_data(p_event_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_ev public.events; v_t public.templates;
begin
  select * into v_ev from public.events where id = p_event_id;
  if not found then return null; end if;
  select * into v_t from public.templates where id = v_ev.template_id;
  return jsonb_build_object(
    'event', jsonb_build_object(
      'name', v_ev.name, 'type', v_ev.event_type, 'celebrated_names', v_ev.celebrated_names,
      'starts_at', v_ev.starts_at, 'timezone', v_ev.timezone, 'venue_name', v_ev.venue_name,
      'address', v_ev.address, 'maps_url', v_ev.maps_url, 'program', v_ev.program, 'message', v_ev.message,
      'extra_info', v_ev.extra_info, 'theme', v_ev.theme, 'rsvp_enabled', v_ev.rsvp_enabled,
      'show_qr', false),
    'template', case when v_t.id is null then null else jsonb_build_object('slug', v_t.slug, 'name', v_t.name, 'config', v_t.config) end,
    'assets', coalesce((
      select jsonb_agg(jsonb_build_object('kind', a.kind, 'path', a.storage_path, 'alt', a.alt_text,
                                          'width', a.width, 'height', a.height) order by a.sort_order, a.created_at)
        from public.event_assets a where a.event_id = v_ev.id), '[]'::jsonb));
end $$;

revoke all on function public.set_event_photo(uuid, text, text, int, int, text) from public, anon;
revoke all on function public.remove_event_photo(uuid) from public, anon;
revoke all on function public.event_for_edit(uuid) from public, anon;
revoke all on function public.update_event(uuid, jsonb) from public, anon;
revoke all on function public.event_preview_data(uuid) from public, anon, authenticated;
grant execute on function public.set_event_photo(uuid, text, text, int, int, text) to authenticated;
grant execute on function public.remove_event_photo(uuid) to authenticated;
grant execute on function public.event_for_edit(uuid) to authenticated;
grant execute on function public.update_event(uuid, jsonb) to authenticated;
grant execute on function public.event_preview_data(uuid) to service_role;
