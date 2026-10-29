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
