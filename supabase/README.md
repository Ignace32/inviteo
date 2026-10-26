# Invitéo — couche base de données (phases 1 à 3)

Schéma PostgreSQL / Supabase du futur système d'invitations personnalisées avec QR code unique.
Ce dossier est **indépendant du site vitrine** : aucun fichier du site existant n'a été modifié ni supprimé.

## État réel

| Phase | Contenu | État |
|---|---|---|
| 1 | Audit, architecture | Fait (voir plus bas) |
| 2 | Schéma, rôles, RLS | **Fait et testé** (161 tests réussis sur PostgreSQL 16) |
| 3 | Événements, invités, import CSV, modèles, jetons hachés | **Côté base : fait et testé.** Interface organisateur : à faire |
| 4 | Page d'invitation animée `/i/<jeton>` | À faire |
| 5 | PDF individuel avec QR code | À faire |
| 6 | Scanner mobile et validation atomique | À faire (schéma et journal prêts) |
| 7 | Statistiques et journaux | À faire (données prêtes) |
| 8 | Déploiement, tests sur téléphones | À faire |

Rien n'est simulé : les tests tournent sur un vrai PostgreSQL. En revanche, **aucun projet Supabase réel n'a été utilisé** (je n'avais ni identifiants ni accès réseau), et les couches web (API, interface, scanner) ne sont pas encore écrites.

## Ce que contient la base

- **Tables (13, RLS activée sur toutes)** : `profiles`, `templates`, `events`, `event_versions`, `event_staff`, `guests`, `invitations`, `invitation_secrets`, `scan_logs`, `event_assets`, `event_documents`, `rsvp_responses`, `admin_audit_log`.
- **Jetons** : deux jetons aléatoires par invitation (lien de la page, QR code), générés côté serveur. Seul leur hachage SHA-256 est stocké, dans `invitation_secrets`, table sans aucun droit pour le navigateur. Le jeton en clair n'est renvoyé qu'une fois, à l'émission.
- **Une invitation = un invité = un QR code.** Le nombre d'entrées autorisées (`max_entries`, issu du type de billet) est une règle explicite et bornée en base. Une clé étrangère composite interdit de lier un invité à un autre événement.
- **Rôles** : `admin`, `organizer`, `agent`. Le rôle ne se modifie que côté serveur. Un organisateur ne voit que ses événements ; un agent ne voit que les événements qui lui sont affectés.
- **Versions** : toute modification de contenu d'un événement incrémente `version` et conserve un instantané (`event_versions`). Un événement terminé n'est plus modifiable ; une publication exige lieu, personnes fêtées et modèle.
- **Fonctions appelables** (par `authenticated` uniquement, jamais `anon`) : `issue_invitation`, `issue_invitations_for_event`, `revoke_invitation`, `reissue_invitation`, `import_guests`, `my_assigned_events`.
- **Modèles** : 6 modèles de départ (mariage classique, mariage moderne, anniversaire élégant, baptême, remise de diplôme, événement professionnel). Un modèle est une ligne de données (`templates.config`) : en ajouter un ne demande aucune modification du code.
- **Stockage** : deux buckets privés, `event-assets` (photos, 5 Mo, JPEG/PNG/WebP) et `event-documents` (PDF, écrits uniquement par le serveur).

## Appliquer les migrations sur un projet Supabase

1. Créez un projet sur supabase.com.
2. Dans *SQL Editor*, exécutez dans l'ordre les cinq fichiers de `migrations/` (ou `supabase db push` avec la CLI Supabase).
3. **N'exécutez jamais** `tests/00_supabase_stub.sql` sur Supabase : il simule des objets qui y existent déjà.
4. Copiez `.env.example` (à la racine) en `.env` et renseignez les valeurs. La clé `SERVICE_ROLE_KEY` ne doit exister que dans les variables d'environnement Vercel, jamais dans un fichier du site.

## Lancer les tests

Il faut un PostgreSQL 15 ou plus, avec un utilisateur capable de créer des bases :

```bash
cd supabase/tests
PGHOST=localhost PGPORT=5432 PGUSER=postgres ./run.sh
```

Le script recrée la base `inviteo_test`, applique le simulateur Supabase et les migrations, puis rejoue les 4 fichiers de tests dans **une seule session** (le premier ouvre la transaction, annulée à la fin). Résultat attendu : `161 réussis, 0 échoués`.

Ce que les tests couvrent : isolation entre organisateurs, rôles, transitions de statut, versions, import en lot, unicité et indépendance des jetons (808 jetons distincts pour 404 invitations), hachage, révocation et réémission, contraintes d'intégrité, agents, stockage, absence de droits pour `anon`.

## Corrections faites en vérifiant cette base

- `anon` pouvait **exécuter** cinq fonctions d'émission et d'import (PostgreSQL accorde `EXECUTE` à `PUBLIC` par défaut, Supabase aussi à `anon`). Elles refusaient l'accès ensuite, mais ne devaient pas être appelables. Droits retirés dans la migration 3 et 5, y compris pour les fonctions créées plus tard.
- Trois tests étaient faux (mauvais total de jetons, mauvais cas pour la clé étrangère, message d'erreur trop strict) : corrigés, sans affaiblir ce qu'ils vérifient.

## Ce qui reste à construire, et ce dont j'ai besoin

1. **Un projet Supabase** (URL, clé `anon`, clé `service_role`) pour tester le système de bout en bout.
2. **Une validation atomique du scan** : une fonction SQL `scan_invitation(token, event_id, request_id)` qui verrouille la ligne (`UPDATE … WHERE status = 'valid'` ou `FOR UPDATE`), journalise dans `scan_logs` (idempotence par `request_id`) et renvoie le résultat. Le test de deux scans simultanés exige deux connexions réelles : il est prévu.
3. **Fonctions serveur Vercel** (`api/`) : émission, page d'invitation, PDF, scan. Elles nécessitent des bibliothèques (client Supabase, génération de QR code, PDF) à installer avec npm.
4. **Interface organisateur et scanner mobile.**
5. **Tests sur de vrais téléphones Android** : scan caméra, lecture du QR imprimé sur le PDF. Cela ne peut pas se faire depuis cet environnement.
