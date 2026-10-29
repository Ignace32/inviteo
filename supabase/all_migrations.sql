-- Invitéo — toutes les migrations dans l'ordre (généré par supabase/build_all.sh ; ne pas modifier à la main).

-- >>>>>>>> 20261101000001_schema.sql
-- ============================================================================
-- Invitéo — migration 1/5 : schéma de base (phases 1 et 2)
--
-- Principes :
--  * Les jetons secrets (lien d'invitation et QR code) ne sont JAMAIS stockés en
--    clair : seul leur hachage SHA-256 est conservé, dans une table à part
--    (invitation_secrets) inaccessible au navigateur.
--  * Le navigateur ne modifie jamais le statut d'une invitation : tout passe par
--    des fonctions serveur (migration 3) ou, pour les scans, par une RPC dédiée
--    (phase 6).
--  * Une même personne peut être invitée à plusieurs événements : aucune
--    contrainte d'unicité globale sur les noms.
-- ============================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm  with schema extensions;

-- ---------------------------------------------------------------------------
-- Utilitaire : mise à jour automatique de updated_at
-- ---------------------------------------------------------------------------
create function public.set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- profiles : un profil par compte (organisateur, agent de contrôle, admin)
-- Le rôle n'est modifiable que par le serveur (service_role), jamais par
-- l'utilisateur lui-même (voir les GRANT de la migration 2).
-- ---------------------------------------------------------------------------
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  role        text not null default 'organizer' check (role in ('admin', 'organizer', 'agent')),
  full_name   text not null default '' check (char_length(full_name) <= 120),
  phone       text check (phone is null or char_length(phone) <= 30),
  created_by  uuid references public.profiles(id) on delete set null,  -- organisateur qui a créé cet agent
  disabled    boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index profiles_created_by_idx on public.profiles (created_by);
create trigger profiles_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

-- Création automatique du profil à l'inscription. Le rôle est toujours
-- « organizer » : ce que le client met dans raw_user_meta_data est ignoré.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, left(coalesce(new.raw_user_meta_data ->> 'full_name', ''), 120))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- templates : bibliothèque de modèles graphiques réutilisables
-- Un modèle = des données (palette, polices, ornements, mise en page), pas une
-- page codée à la main. Ajouter un modèle = ajouter une ligne.
-- ---------------------------------------------------------------------------
create table public.templates (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name         text not null check (char_length(name) between 1 and 80),
  event_type   text not null check (event_type in ('wedding', 'birthday', 'baptism', 'graduation', 'corporate', 'other')),
  description  text check (description is null or char_length(description) <= 300),
  config       jsonb not null default '{}' check (jsonb_typeof(config) = 'object'),
  version      int not null default 1 check (version >= 1),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create trigger templates_updated_at before update on public.templates
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- events : les événements des organisateurs
-- ---------------------------------------------------------------------------
create table public.events (
  id               uuid primary key default gen_random_uuid(),
  organizer_id     uuid not null references public.profiles(id) on delete restrict,
  event_type       text not null check (event_type in ('wedding', 'birthday', 'baptism', 'graduation', 'corporate', 'other')),
  name             text not null check (char_length(btrim(name)) between 1 and 160),
  celebrated_names text check (celebrated_names is null or char_length(celebrated_names) <= 200),
  starts_at        timestamptz not null,
  ends_at          timestamptz,
  timezone         text not null default 'Africa/Lubumbashi',
  venue_name       text check (venue_name is null or char_length(venue_name) <= 160),
  address          text check (address is null or char_length(address) <= 300),
  maps_url         text check (maps_url is null or (maps_url ~ '^https://' and char_length(maps_url) <= 500)),
  program          jsonb not null default '[]'
                     check (jsonb_typeof(program) = 'array' and jsonb_array_length(program) <= 30),
  message          text check (message is null or char_length(message) <= 1500),
  extra_info       text check (extra_info is null or char_length(extra_info) <= 1500),
  template_id      uuid references public.templates(id),
  theme            jsonb not null default '{}' check (jsonb_typeof(theme) = 'object'),
  rsvp_enabled     boolean not null default false,
  show_qr_on_page  boolean not null default false,
  status           text not null default 'draft'
                     check (status in ('draft', 'pending_review', 'published', 'finished', 'cancelled')),
  version          int not null default 1,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (ends_at is null or ends_at >= starts_at)
);
create index events_organizer_idx on public.events (organizer_id, starts_at desc);
create index events_status_idx on public.events (status);

-- Historique des versions : chaque modification du contenu incrémente
-- events.version et conserve un instantané. Les documents (PDF) générés pour une
-- version plus ancienne sont signalés comme obsolètes (vue outdated_documents).
create table public.event_versions (
  id          bigint generated always as identity primary key,
  event_id    uuid not null references public.events(id) on delete cascade,
  version     int not null,
  snapshot    jsonb not null,
  changed_by  uuid,
  changed_at  timestamptz not null default now(),
  unique (event_id, version)
);

create table public.event_assets (
  id            uuid primary key default gen_random_uuid(),
  event_id      uuid not null references public.events(id) on delete cascade,
  kind          text not null default 'photo' check (kind in ('cover', 'photo', 'logo')),
  storage_path  text not null check (char_length(storage_path) <= 300),
  alt_text      text check (alt_text is null or char_length(alt_text) <= 200),
  width         int check (width is null or width between 1 and 20000),
  height        int check (height is null or height between 1 and 20000),
  sort_order    int not null default 0,
  created_at    timestamptz not null default now(),
  unique (event_id, storage_path)
);
create index event_assets_event_idx on public.event_assets (event_id, sort_order);

-- Affectation des agents de contrôle aux événements
create table public.event_staff (
  event_id     uuid not null references public.events(id) on delete cascade,
  agent_id     uuid not null references public.profiles(id) on delete cascade,
  assigned_by  uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now(),
  primary key (event_id, agent_id)
);
create index event_staff_agent_idx on public.event_staff (agent_id);

-- ---------------------------------------------------------------------------
-- guests : les personnes invitées à UN événement donné
-- ---------------------------------------------------------------------------
create table public.guests (
  id           uuid primary key default gen_random_uuid(),
  event_id     uuid not null references public.events(id) on delete cascade,
  full_name    text not null check (char_length(btrim(full_name)) between 1 and 120),
  phone        text check (phone is null or phone ~ '^[0-9+()\-. ]{5,30}$'),
  email        text check (email is null or (char_length(email) <= 160 and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')),
  party_size   int not null default 1 check (party_size between 1 and 20),  -- personnes autorisées avec CETTE invitation
  ticket_type  text not null default 'standard' check (char_length(ticket_type) between 1 and 40),
  notes        text check (notes is null or char_length(notes) <= 300),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (id, event_id)   -- cible de la clé étrangère composite des invitations
);
create index guests_event_idx on public.guests (event_id, created_at);
create index guests_name_trgm_idx on public.guests using gin (full_name extensions.gin_trgm_ops);
create trigger guests_updated_at before update on public.guests
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- invitations : une invitation = un invité = un QR code unique
-- ---------------------------------------------------------------------------
create table public.invitations (
  id             uuid primary key default gen_random_uuid(),
  event_id       uuid not null,
  guest_id       uuid not null,
  status         text not null default 'valid' check (status in ('valid', 'used', 'revoked', 'expired')),
  -- Règle explicite : nombre d'entrées autorisées avec ce QR code (contrôlé côté serveur au scan).
  max_entries    int not null default 1 check (max_entries between 1 and 20),
  entries_used   int not null default 0,
  expires_at     timestamptz,
  issued_by      uuid references public.profiles(id) on delete set null,
  issued_at      timestamptz not null default now(),
  revoked_at     timestamptz,
  revoked_by     uuid references public.profiles(id) on delete set null,
  revoke_reason  text check (revoke_reason is null or char_length(revoke_reason) <= 300),
  replaced_by    uuid references public.invitations(id),
  first_used_at  timestamptz,
  first_used_by  uuid references public.profiles(id) on delete set null,
  last_used_at   timestamptz,
  -- Un invité appartient forcément au même événement que son invitation.
  foreign key (guest_id, event_id) references public.guests (id, event_id) on delete restrict,
  check (entries_used between 0 and max_entries),
  check (status <> 'used' or entries_used = max_entries),
  check (status <> 'revoked' or revoked_at is not null)
);
create index invitations_event_status_idx on public.invitations (event_id, status);
create index invitations_guest_idx on public.invitations (guest_id);
-- Un invité ne peut avoir qu'UNE invitation active à la fois (réémission = révocation de la précédente).
create unique index invitations_one_active_per_guest
  on public.invitations (guest_id) where status in ('valid', 'used');

-- Jetons hachés. Table isolée : aucun droit pour anon/authenticated, aucune
-- politique RLS. Seules les fonctions SECURITY DEFINER y accèdent.
create table public.invitation_secrets (
  invitation_id    uuid primary key references public.invitations(id) on delete cascade,
  view_token_hash  bytea not null unique check (octet_length(view_token_hash) = 32),  -- lien de la page animée
  qr_token_hash    bytea not null unique check (octet_length(qr_token_hash) = 32),    -- QR code d'entrée
  created_at       timestamptz not null default now(),
  check (view_token_hash <> qr_token_hash)
);

-- Journal des contrôles (rempli uniquement par la RPC de scan, phase 6)
create table public.scan_logs (
  id               bigint generated always as identity primary key,
  request_id       uuid not null,          -- idempotence : même requête rejouée = même résultat
  event_id         uuid not null references public.events(id) on delete cascade,
  invitation_id    uuid references public.invitations(id) on delete set null,
  agent_id         uuid not null references public.profiles(id),
  result           text not null check (result in ('accepted', 'already_used', 'revoked', 'expired', 'invalid', 'wrong_event', 'forbidden')),
  entries_after    int,
  scanned_at       timestamptz not null default now(),
  details          jsonb not null default '{}' check (jsonb_typeof(details) = 'object'),
  unique (agent_id, request_id)
);
create index scan_logs_event_idx on public.scan_logs (event_id, scanned_at desc);
create index scan_logs_invitation_idx on public.scan_logs (invitation_id);

create table public.rsvp_responses (
  id             uuid primary key default gen_random_uuid(),
  invitation_id  uuid not null unique references public.invitations(id) on delete cascade,
  event_id       uuid not null references public.events(id) on delete cascade,
  attending      boolean not null,
  party_count    int check (party_count is null or party_count between 0 and 20),
  song           text check (song is null or char_length(song) <= 120),
  note           text check (note is null or char_length(note) <= 500),
  responded_at   timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index rsvp_event_idx on public.rsvp_responses (event_id);

-- PDF générés (écrits par le serveur, jamais par le navigateur)
create table public.event_documents (
  id               uuid primary key default gen_random_uuid(),
  event_id         uuid not null references public.events(id) on delete cascade,
  guest_id         uuid references public.guests(id) on delete set null,
  invitation_id    uuid references public.invitations(id) on delete set null,
  kind             text not null check (kind in ('invitation_pdf', 'bundle_pdf')),
  storage_path     text not null,
  event_version    int not null,
  template_version int,
  checksum_sha256  text check (checksum_sha256 is null or checksum_sha256 ~ '^[0-9a-f]{64}$'),
  byte_size        int check (byte_size is null or byte_size >= 0),
  created_by       uuid,
  created_at       timestamptz not null default now()
);
create index event_documents_event_idx on public.event_documents (event_id, created_at desc);

-- Journal des actions d'administration (lecture seule pour les admins)
create table public.admin_audit_log (
  id           bigint generated always as identity primary key,
  actor_id     uuid,
  action       text not null,
  target_type  text,
  target_id    text,
  details      jsonb not null default '{}',
  created_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Règles métier des événements : transitions de statut, versions, gel
-- ---------------------------------------------------------------------------
create function public.events_before_update() returns trigger
language plpgsql as $$
declare
  v_changed boolean;
  v_ok      boolean;
begin
  if new.organizer_id is distinct from old.organizer_id then
    raise exception 'organizer_id is immutable' using errcode = '42501';
  end if;

  v_changed := (to_jsonb(new) - array['status', 'version', 'updated_at'])
               is distinct from (to_jsonb(old) - array['status', 'version', 'updated_at']);

  if new.status is distinct from old.status then
    v_ok := (old.status = 'draft'          and new.status in ('pending_review', 'published', 'cancelled'))
         or (old.status = 'pending_review' and new.status in ('draft', 'published', 'cancelled'))
         or (old.status = 'published'      and new.status in ('finished', 'cancelled'));
    if not v_ok then
      raise exception 'invalid status transition: % -> %', old.status, new.status using errcode = '23514';
    end if;
    if new.status = 'published' and (
         coalesce(btrim(new.venue_name), '') = ''
         or coalesce(btrim(new.celebrated_names), '') = ''
         or new.template_id is null) then
      raise exception 'cannot publish: venue_name, celebrated_names and template_id are required'
        using errcode = '23514';
    end if;
  end if;

  if v_changed and old.status in ('finished', 'cancelled') then
    raise exception 'event is % and can no longer be edited', old.status using errcode = '23514';
  end if;

  if v_changed then
    new.version := old.version + 1;
  else
    new.version := old.version;   -- la version ne se modifie jamais à la main
  end if;
  new.updated_at := now();
  return new;
end $$;

create trigger events_before_update before update on public.events
  for each row execute function public.events_before_update();

create function public.events_snapshot() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.event_versions (event_id, version, snapshot, changed_by)
    values (new.id, new.version, to_jsonb(new) - 'organizer_id', auth.uid());
  elsif new.version <> old.version then
    insert into public.event_versions (event_id, version, snapshot, changed_by)
    values (new.id, new.version, to_jsonb(new) - 'organizer_id', auth.uid());
  end if;
  return null;
end $$;

create trigger events_snapshot after insert or update on public.events
  for each row execute function public.events_snapshot();

-- On n'ajoute pas d'invités à un événement terminé ou annulé.
create function public.guests_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_status text;
begin
  select status into v_status from public.events where id = coalesce(new.event_id, old.event_id);
  if v_status in ('finished', 'cancelled') then
    raise exception 'event is % : guests can no longer be changed', v_status using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' and new.event_id is distinct from old.event_id then
    raise exception 'guest cannot be moved to another event' using errcode = '23514';
  end if;
  return coalesce(new, old);
end $$;

create trigger guests_guard before insert or update or delete on public.guests
  for each row execute function public.guests_guard();

-- Seuls de vrais comptes « agent » actifs peuvent être affectés à un événement.
create function public.event_staff_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_role text; v_disabled boolean;
begin
  select role, disabled into v_role, v_disabled from public.profiles where id = new.agent_id;
  if v_role is distinct from 'agent' or v_disabled then
    raise exception 'only active agent accounts can be assigned' using errcode = '23514';
  end if;
  new.assigned_by := coalesce(auth.uid(), new.assigned_by);
  return new;
end $$;

create trigger event_staff_guard before insert on public.event_staff
  for each row execute function public.event_staff_guard();

-- Documents obsolètes : générés pour une version antérieure de l'événement.
create view public.outdated_documents with (security_invoker = true) as
  select d.id, d.event_id, d.guest_id, d.invitation_id, d.kind,
         d.event_version as document_version, e.version as current_version
  from public.event_documents d
  join public.events e on e.id = d.event_id
  where d.event_version < e.version;

-- >>>>>>>> 20261101000002_rls.sql
-- ============================================================================
-- Invitéo — migration 2/5 : droits, rôles et politiques RLS (phase 2)
--
-- Modèle de sécurité :
--  * Par défaut, Supabase donne tous les droits aux rôles anon/authenticated :
--    on les RETIRE d'abord, puis on n'accorde que le strict nécessaire, colonne
--    par colonne quand c'est utile. La RLS fait ensuite le tri ligne par ligne.
--  * Organisateur : voit et gère uniquement SES événements et leurs invités.
--  * Agent de contrôle : AUCUN accès direct à events/guests ; il passe par
--    my_assigned_events() (colonnes limitées) et, en phase 6, par la RPC de scan.
--  * Administrateur : lecture globale ; les écritures d'administration passent
--    par le serveur (service_role) et sont consignées dans admin_audit_log.
--  * invitations / scan_logs / event_documents : lecture seule pour le navigateur.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Fonctions d'aide (SECURITY DEFINER : elles lisent profiles/events sans
-- déclencher récursivement la RLS de ces tables)
-- ---------------------------------------------------------------------------
create function public.app_role() returns text
language sql stable security definer set search_path = public as $$
  select p.role from public.profiles p where p.id = auth.uid() and not p.disabled
$$;

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.app_role() = 'admin', false)
$$;

-- L'utilisateur courant est organisateur actif ET propriétaire de l'événement.
create function public.owns_event(p_event_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.app_role() in ('organizer', 'admin'), false)
     and exists (select 1 from public.events e
                 where e.id = p_event_id and e.organizer_id = auth.uid())
$$;

-- L'agent à affecter doit avoir été créé par l'organisateur courant (ou être
-- affecté par un admin) : un organisateur ne peut pas « emprunter » l'agent d'un autre.
create function public.can_assign_agent(p_agent_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles a
    where a.id = p_agent_id and a.role = 'agent' and not a.disabled
      and (a.created_by = auth.uid() or public.is_admin())
  )
$$;

-- ---------------------------------------------------------------------------
-- Retrait des droits par défaut
-- ---------------------------------------------------------------------------
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from public, anon, authenticated;

grant usage on schema public to anon, authenticated;

-- Les fonctions d'aide sont appelées par les politiques RLS, donc par authenticated.
grant execute on function public.app_role(), public.is_admin(),
  public.owns_event(uuid), public.can_assign_agent(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Droits sur les tables (lecture/écriture minimales)
-- ---------------------------------------------------------------------------
grant select on public.profiles to authenticated;
grant update (full_name, phone) on public.profiles to authenticated;   -- jamais role/disabled/created_by

grant select on public.templates to authenticated;
grant insert, update, delete on public.templates to authenticated;     -- filtré par politique admin

grant select, delete on public.events to authenticated;
grant insert (organizer_id, event_type, name, celebrated_names, starts_at, ends_at, timezone,
              venue_name, address, maps_url, program, message, extra_info, template_id, theme,
              rsvp_enabled, show_qr_on_page)
  on public.events to authenticated;
grant update (event_type, name, celebrated_names, starts_at, ends_at, timezone, venue_name, address,
              maps_url, program, message, extra_info, template_id, theme, rsvp_enabled,
              show_qr_on_page, status)
  on public.events to authenticated;

grant select on public.event_versions to authenticated;

grant select, delete on public.event_assets to authenticated;
grant insert (event_id, kind, storage_path, alt_text, width, height, sort_order)
  on public.event_assets to authenticated;
grant update (kind, alt_text, sort_order) on public.event_assets to authenticated;

grant select, delete on public.event_staff to authenticated;
grant insert (event_id, agent_id) on public.event_staff to authenticated;

grant select, delete on public.guests to authenticated;
grant insert (event_id, full_name, phone, email, party_size, ticket_type, notes) on public.guests to authenticated;
grant update (full_name, phone, email, party_size, ticket_type, notes) on public.guests to authenticated;

-- Lecture seule : les statuts d'invitation, les journaux et les documents
-- ne sont jamais modifiables depuis le navigateur.
grant select on public.invitations      to authenticated;
grant select on public.scan_logs        to authenticated;
grant select on public.rsvp_responses   to authenticated;
grant select on public.event_documents  to authenticated;
grant select on public.outdated_documents to authenticated;
grant select on public.admin_audit_log  to authenticated;
-- invitation_secrets : AUCUN droit.

-- ---------------------------------------------------------------------------
-- Activation de la RLS partout (y compris invitation_secrets, sans aucune politique)
-- ---------------------------------------------------------------------------
alter table public.profiles            enable row level security;
alter table public.templates           enable row level security;
alter table public.events              enable row level security;
alter table public.event_versions      enable row level security;
alter table public.event_assets        enable row level security;
alter table public.event_staff         enable row level security;
alter table public.guests              enable row level security;
alter table public.invitations         enable row level security;
alter table public.invitation_secrets  enable row level security;
alter table public.scan_logs           enable row level security;
alter table public.rsvp_responses      enable row level security;
alter table public.event_documents     enable row level security;
alter table public.admin_audit_log     enable row level security;

-- ---------------------------------------------------------------------------
-- Politiques
-- ---------------------------------------------------------------------------

-- profiles : soi-même, ses propres agents, ou admin. Modification : soi-même.
create policy profiles_select_self   on public.profiles for select to authenticated using (id = auth.uid());
create policy profiles_select_agents on public.profiles for select to authenticated
  using (created_by = auth.uid() and public.app_role() in ('organizer', 'admin'));
create policy profiles_select_admin  on public.profiles for select to authenticated using (public.is_admin());
create policy profiles_update_self   on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- templates : lecture des modèles actifs ; gestion réservée aux admins
create policy templates_select on public.templates for select to authenticated
  using (is_active or public.is_admin());
create policy templates_admin_insert on public.templates for insert to authenticated with check (public.is_admin());
create policy templates_admin_update on public.templates for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy templates_admin_delete on public.templates for delete to authenticated using (public.is_admin());

-- events : propriétaire uniquement (+ lecture admin). Suppression : brouillons seulement.
create policy events_select_owner on public.events for select to authenticated
  using (organizer_id = auth.uid() and public.app_role() in ('organizer', 'admin'));
create policy events_select_admin on public.events for select to authenticated using (public.is_admin());
create policy events_insert_owner on public.events for insert to authenticated
  with check (organizer_id = auth.uid() and public.app_role() in ('organizer', 'admin'));
create policy events_update_owner on public.events for update to authenticated
  using (organizer_id = auth.uid() and public.app_role() in ('organizer', 'admin'))
  with check (organizer_id = auth.uid() and public.app_role() in ('organizer', 'admin'));
create policy events_delete_owner on public.events for delete to authenticated
  using (organizer_id = auth.uid() and public.app_role() in ('organizer', 'admin') and status = 'draft');

create policy event_versions_select on public.event_versions for select to authenticated
  using (public.owns_event(event_id) or public.is_admin());

create policy event_assets_select on public.event_assets for select to authenticated
  using (public.owns_event(event_id) or public.is_admin());
create policy event_assets_insert on public.event_assets for insert to authenticated
  with check (public.owns_event(event_id));
create policy event_assets_update on public.event_assets for update to authenticated
  using (public.owns_event(event_id)) with check (public.owns_event(event_id));
create policy event_assets_delete on public.event_assets for delete to authenticated
  using (public.owns_event(event_id));

-- event_staff : l'organisateur gère l'équipe de SON événement ; l'agent voit ses affectations
create policy event_staff_select on public.event_staff for select to authenticated
  using (public.owns_event(event_id) or agent_id = auth.uid() or public.is_admin());
create policy event_staff_insert on public.event_staff for insert to authenticated
  with check (public.owns_event(event_id) and public.can_assign_agent(agent_id));
create policy event_staff_delete on public.event_staff for delete to authenticated
  using (public.owns_event(event_id));

-- guests : propriétaire de l'événement uniquement
create policy guests_select on public.guests for select to authenticated
  using (public.owns_event(event_id) or public.is_admin());
create policy guests_insert on public.guests for insert to authenticated
  with check (public.owns_event(event_id));
create policy guests_update on public.guests for update to authenticated
  using (public.owns_event(event_id)) with check (public.owns_event(event_id));
create policy guests_delete on public.guests for delete to authenticated
  using (public.owns_event(event_id));

-- Lecture seule
create policy invitations_select on public.invitations for select to authenticated
  using (public.owns_event(event_id) or public.is_admin());
create policy scan_logs_select on public.scan_logs for select to authenticated
  using (public.owns_event(event_id) or agent_id = auth.uid() or public.is_admin());
create policy rsvp_select on public.rsvp_responses for select to authenticated
  using (public.owns_event(event_id) or public.is_admin());
create policy event_documents_select on public.event_documents for select to authenticated
  using (public.owns_event(event_id) or public.is_admin());
create policy admin_audit_select on public.admin_audit_log for select to authenticated
  using (public.is_admin());

-- >>>>>>>> 20261101000003_functions.sql
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

-- >>>>>>>> 20261101000004_seed_templates.sql
-- ============================================================================
-- Invitéo — migration 4/5 : modèles de départ (phase 3)
--
-- Un modèle est une ligne de données. La page animée (phase 4) et le PDF
-- (phase 5) lisent cette configuration : aucun modèle n'est codé « en dur » pour
-- un invité. Pour ajouter un modèle plus tard : INSERT d'une nouvelle ligne
-- (ou un nouveau fichier de migration), sans toucher au reste de l'architecture.
--
-- Clés de config :
--   palette   : couleurs (bg, paper, text, muted, accent)
--   fonts     : polices (display, body)
--   ornament  : décor prévu pour la phase 4 (floral-fine, floral-soft, none, laurel, rule)
--   layout    : structure de page (centered, minimal, photo-hero, academic, clean)
--   cover     : style de l'ouverture animée (envelope, ticket, curtain, seal)
--   photos    : nombre de photos conseillé (min/max)
-- Aucun dégradé décoratif : toutes les couleurs sont des aplats.
-- ============================================================================

insert into public.templates (slug, name, event_type, description, config) values
('mariage-classique', 'Mariage classique', 'wedding',
 'Ivoire, fleurs délicates et détails dorés.',
 '{"palette":{"bg":"#FAF7F1","paper":"#FFFFFF","text":"#25221F","muted":"#6B655E","accent":"#B8915A"},
   "fonts":{"display":"Fraunces","body":"DM Sans"},
   "ornament":"floral-fine","layout":"centered","cover":"envelope","photos":{"min":1,"max":6}}'),

('mariage-moderne', 'Mariage moderne', 'wedding',
 'Noir, doré et typographie minimaliste.',
 '{"palette":{"bg":"#171513","paper":"#25221F","text":"#FAF7F1","muted":"#C9C3BA","accent":"#C9A24D"},
   "fonts":{"display":"DM Sans","body":"DM Sans"},
   "ornament":"none","layout":"minimal","cover":"curtain","photos":{"min":1,"max":6}}'),

('anniversaire-elegant', 'Anniversaire élégant', 'birthday',
 'La photo de la personne fêtée en vedette, couleurs festives.',
 '{"palette":{"bg":"#25221F","paper":"#FAF7F1","text":"#FAF7F1","muted":"#C9C3BA","accent":"#E86D32"},
   "fonts":{"display":"Fraunces","body":"DM Sans"},
   "ornament":"rule","layout":"photo-hero","cover":"ticket","photos":{"min":1,"max":4}}'),

('bapteme', 'Baptême', 'baptism',
 'Blanc, tons doux et éléments floraux.',
 '{"palette":{"bg":"#FFFFFF","paper":"#FAF7F1","text":"#25221F","muted":"#6B655E","accent":"#8FA6BF"},
   "fonts":{"display":"Fraunces","body":"DM Sans"},
   "ornament":"floral-soft","layout":"centered","cover":"envelope","photos":{"min":1,"max":4}}'),

('remise-diplome', 'Remise de diplôme', 'graduation',
 'Bleu marine, doré et présentation académique.',
 '{"palette":{"bg":"#14284B","paper":"#FAF7F1","text":"#FAF7F1","muted":"#C5CCDA","accent":"#C9A24D"},
   "fonts":{"display":"Fraunces","body":"DM Sans"},
   "ornament":"laurel","layout":"academic","cover":"seal","photos":{"min":0,"max":3}}'),

('evenement-professionnel', 'Événement professionnel', 'corporate',
 'Design épuré, moderne et institutionnel.',
 '{"palette":{"bg":"#FAF7F1","paper":"#FFFFFF","text":"#25221F","muted":"#6B655E","accent":"#E86D32"},
   "fonts":{"display":"DM Sans","body":"DM Sans"},
   "ornament":"rule","layout":"clean","cover":"curtain","photos":{"min":0,"max":3}}');

-- >>>>>>>> 20261101000005_storage.sql
-- ============================================================================
-- Invitéo — migration 5/5 : stockage des photos et des PDF
--
-- Deux buckets PRIVÉS (aucun accès public) :
--   event-assets    photos des événements. Chemin : <event_id>/<fichier>
--                   L'organisateur propriétaire peut lire / déposer / supprimer.
--   event-documents PDF générés. Écrits uniquement par le serveur (service_role) ;
--                   l'organisateur propriétaire peut les lire.
-- La page d'invitation publique (phase 4) reçoit des URL signées de courte durée,
-- générées côté serveur : les photos ne sont jamais exposées en accès libre.
-- ============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('event-assets',    'event-assets',    false, 5242880,  array['image/jpeg', 'image/png', 'image/webp']),
  ('event-documents', 'event-documents', false, 10485760, array['application/pdf'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Le premier segment du chemin doit être l'identifiant d'un événement possédé par l'utilisateur.
create function public.storage_event_owner(p_name text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_event uuid;
begin
  begin
    v_event := ((string_to_array(p_name, '/'))[1])::uuid;
  exception when invalid_text_representation then
    return false;
  end;
  return public.owns_event(v_event);
end $$;
revoke all on function public.storage_event_owner(text) from public, anon;
grant execute on function public.storage_event_owner(text) to authenticated;

create policy event_assets_read on storage.objects for select to authenticated
  using (bucket_id = 'event-assets' and public.storage_event_owner(name));
create policy event_assets_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'event-assets' and public.storage_event_owner(name));
create policy event_assets_delete on storage.objects for delete to authenticated
  using (bucket_id = 'event-assets' and public.storage_event_owner(name));

create policy event_documents_read on storage.objects for select to authenticated
  using (bucket_id = 'event-documents' and public.storage_event_owner(name));
-- Aucune politique d'écriture sur event-documents : seul service_role (qui contourne la RLS) écrit.

-- >>>>>>>> 20261101000006_scan.sql
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

-- >>>>>>>> 20261101000007_public_page.sql
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

-- >>>>>>>> 20261101000008_ticket_context.sql
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

-- >>>>>>>> 20261101000009_dashboard.sql
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

-- >>>>>>>> 20261101000010_create_event.sql
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

-- >>>>>>>> 20261101000011_designs_photos.sql
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
