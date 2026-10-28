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
