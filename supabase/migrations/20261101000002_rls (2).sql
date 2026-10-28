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
