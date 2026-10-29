-- Invitéo — rôles des comptes (à exécuter dans Supabase > SQL Editor, rôle postgres).
-- 1) Créez d'abord chaque personne dans Authentication > Users (e-mail + mot de passe, « Auto Confirm User »).
-- 2) Tout compte créé est « organizer » par défaut. Promouvez ici les agents et l'administrateur.

-- Agent de contrôle, rattaché à un organisateur (remplacez les e-mails) :
update public.profiles
   set role = 'agent',
       full_name = 'Nom de l''agent',
       created_by = (select id from auth.users where email = 'ORGANISATEUR@exemple.com')
 where id = (select id from auth.users where email = 'AGENT1@exemple.com');

-- Affectation de l'agent à un événement (remplacez l'identifiant de l'événement) :
insert into public.event_staff (event_id, agent_id)
values ('00000000-0000-0000-0000-000000000000',
        (select id from auth.users where email = 'AGENT1@exemple.com'));

-- Administrateur (lecture globale ; à réserver à vous) :
-- update public.profiles set role = 'admin' where id = (select id from auth.users where email = 'VOTRE@exemple.com');
