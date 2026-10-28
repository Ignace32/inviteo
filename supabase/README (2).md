# Invitéo — couche base de données (phases 1 à 3, 6 et 7 côté base)

Schéma PostgreSQL / Supabase du futur système d'invitations personnalisées avec QR code unique.
Ce dossier est **indépendant du site vitrine** : aucun fichier du site existant n'a été modifié ni supprimé.

## État réel

| Phase | Contenu | État |
|---|---|---|
| 1 | Audit, architecture | Fait (voir plus bas) |
| 2 | Schéma, rôles, RLS | **Fait et testé** |
| 3 | Événements, invités, import CSV, modèles, jetons hachés | **Côté base : fait et testé.** Interface organisateur : à faire |
| 4 | Page d'invitation animée `/i/<jeton>`, réponse (RSVP), QR affiché depuis le fragment de l'URL | **Fait et testé** (base réelle + Chromium, voir `tests/web/`). Projet Supabase réel : à brancher |
| 5 | PDF individuel avec QR code | **Fait et testé** (`api/ticket.js`, migration 8). Pas de photos dans le PDF pour l'instant |
| 6 | Validation atomique des scans | **Fait et testé** : base (connexions simultanées réelles) et scanner `/scanner` (`api/auth.js`, `api/my-events.js`, `api/scan.js`). Lecture optique sur de vrais téléphones : non testée |
| 7 | Statistiques et journaux | **Fait et testé** : `event_stats`, tableau de bord et import CSV sur `/organisateur`. Création d'événement par formulaire : à faire |
| 8 | Déploiement, tests sur téléphones | **Guides et vérification prêts** (`DEPLOIEMENT.md`, `ESSAI_TELEPHONES.md`, `tests/smoke.sh`). Mise en ligne réelle et essais sur téléphones : à faire par vous |

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
2. Dans *SQL Editor*, exécutez dans l'ordre les neuf fichiers de `migrations/` (ou `supabase db push` avec la CLI Supabase).
3. **N'exécutez jamais** `tests/00_supabase_stub.sql` sur Supabase : il simule des objets qui y existent déjà.
4. Copiez `.env.example` (à la racine) en `.env` et renseignez les valeurs. La clé `SERVICE_ROLE_KEY` ne doit exister que dans les variables d'environnement Vercel, jamais dans un fichier du site.

## Lancer les tests

Il faut un PostgreSQL 15 ou plus, avec un utilisateur capable de créer des bases :

```bash
cd supabase/tests
PGHOST=localhost PGPORT=5432 PGUSER=postgres ./run.sh
```

Le script recrée la base `inviteo_test`, applique le simulateur Supabase et les migrations, puis rejoue les fichiers de tests 10 à 70 dans **une seule session** (le premier ouvre la transaction, annulée à la fin). Résultat attendu : `284 réussis, 0 échoués`, puis les tests de concurrence (`66 réussis, 0 échoués`).

Ce que les tests couvrent : isolation entre organisateurs, rôles, transitions de statut, versions, import en lot, unicité et indépendance des jetons (808 jetons distincts pour 404 invitations), hachage, révocation et réémission, contraintes d'intégrité, agents, stockage, absence de droits pour `anon`.

## Validation des scans : `scan_invitation(événement, jeton, requête)`

Appelable uniquement par un compte connecté (rôle `authenticated`) ; le résultat est un JSON. Le jeton est celui lu dans le QR code ; `requête` est un UUID généré par le scanner pour chaque scan.

| `result` | Signification | Couleur côté scanner |
|---|---|---|
| `accepted` | Entrée valide, enregistrée (`entries_used` / `max_entries`) | Vert |
| `already_used` | Billet déjà utilisé ; `first_scanned_at` et `first_scanned_by` indiqués | Rouge |
| `revoked`, `expired` | Invitation révoquée ou expirée | Rouge / orange |
| `invalid` | Jeton inconnu, mal formé, ou jeton du lien (qui n'ouvre pas l'entrée) | Orange |
| `wrong_event` | QR code d'un autre événement (aucune donnée de l'invité révélée) | Rouge |
| `forbidden` | Agent non affecté, désactivé, événement non publié ou inconnu (`reason`) | Rouge |

Règles garanties par la base : ligne d'invitation verrouillée pendant le scan ; une entrée de plus seulement si `entries_used < max_entries` ; un même `requête` rejoué renvoie la réponse déjà enregistrée (`replayed: true`) sans recompter ; réutiliser un `requête` pour un autre scan est refusé ; le journal ne garde qu'une empreinte de 12 caractères du jeton. Si le réseau est coupé, le scanner ne reçoit aucune réponse : il doit alors afficher « contrôle non confirmé » et ne **jamais** afficher un succès sans réponse `accepted` du serveur.

`event_stats(événement)` renvoie, pour l'organisateur (ou l'administrateur) : invitations émises, valides, utilisées, révoquées, expirées, entrées validées, tentatives en double, refus, et les 10 dernières entrées (invité, heure, agent).

### Tests de concurrence

`tests/60_concurrency.sh` ouvre de vraies connexions PostgreSQL simultanées (12 agents, départ synchronisé) sur le même QR code : 5 manches sur un billet individuel (une seule entrée acceptée à chaque fois), 3 manches sur un billet de 3 personnes (exactement 3), 3 manches de rejeu simultané d'une même requête (comptée une fois), puis cohérence statistiques / journal / invitations. Une version volontairement défectueuse de la fonction (sans verrou, mise à jour inconditionnelle) fait échouer ces tests, ce qui prouve qu'ils détectent un scan non atomique.

## Corrections faites en vérifiant cette base

- `anon` pouvait **exécuter** cinq fonctions d'émission et d'import (PostgreSQL accorde `EXECUTE` à `PUBLIC` par défaut, Supabase aussi à `anon`). Elles refusaient l'accès ensuite, mais ne devaient pas être appelables. Droits retirés dans la migration 3 et 5, y compris pour les fonctions créées plus tard.
- Trois tests étaient faux (mauvais total de jetons, mauvais cas pour la clé étrangère, message d'erreur trop strict) : corrigés, sans affaiblir ce qu'ils vérifient.

## Ce qui reste à construire, et ce dont j'ai besoin

1. **Un projet Supabase** (URL, clé `anon`, clé `service_role`) pour tester le système de bout en bout, avec la vraie authentification.
2. **Fonctions serveur Vercel** restantes : émission des invitations (interface), PDF, appel du scan. `api/i.js` et `api/rsvp.js` (page et réponse) sont écrites ; elles exigent `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` et `PUBLIC_SITE_URL` dans les variables d'environnement Vercel.
3. **Interfaces** : tableau de bord organisateur, import CSV, scanner mobile avec caméra.
4. **Tests sur de vrais téléphones Android** : scan caméra, lecture du QR imprimé sur le PDF, perte de réseau. Impossible depuis cet environnement.

## Page d'invitation (phase 4)

`/i/<jeton de page>` est rendue par `api/i.js` (HTML échappé, CSP sans script en ligne, `no-store`, `noindex`). Le lien à envoyer est `/i/<jeton de page>#<jeton QR>` : le fragment ne part jamais vers le serveur, la page y lit le jeton du QR et le trace dans le navigateur. Sans fragment, la page s'affiche sans billet. `/s/<jeton QR>` (contenu du QR) est une page statique qui n'appelle rien et ne consomme aucune entrée.

Tests : `PGHOST=… PGPORT=… PGUSER=postgres tests/web/run.sh` (43 + 28 + 44 + 46 vérifications : états, échappement, quotas RSVP, origine, QR relu par OpenCV). Le point d'accès Supabase y est un petit relais vers de vraies fonctions SQL ; Storage (photos signées) n'est pas testé ici. Le scanner (phase 6) aura besoin de `Permissions-Policy: camera=(self)` sur sa page.

## Billet PDF individuel (phase 5)

`POST /api/ticket` (organisateur connecté, en-tête `Authorization: Bearer <jeton Supabase>`) avec `{"guest_id": …}` (émission) ou `{"invitation_id": …}` (réémission, l'ancien lien et l'ancien QR sont révoqués) renvoie un PDF A5 : événement, date, lieu, nom de l'invité, nombre de personnes, QR code vectoriel. Les en-têtes `X-Invitation-Link` (`/i/<page>#<QR>`) et `X-Invitation-Id` accompagnent le PDF.

Le jeton du QR n'existe en clair qu'au moment de l'émission : il n'est stocké nulle part, donc **un PDF perdu ne se régénère pas, il se réémet**. Les droits sont ceux de l'utilisateur (la base refuse tout autre organisateur). Le PDF est écrit sans bibliothèque (`api/_lib/pdf.js`, polices standard Helvetica/Times, accents compris).

Tests (`tests/web/pdf_e2e.js`, 28 vérifications) : structure validée par `qpdf --check`, texte extrait avec `pdftotext`, QR du PDF rendu à 300 dpi puis relu par OpenCV, jeton vérifié contre le hachage en base, réémission, refus d'un autre organisateur. Non testé : impression papier et lecture par de vrais téléphones. Variable requise en plus : `SUPABASE_ANON_KEY` (Vercel).

## Scanner d'entrée (phase 6) : `/scanner`

Page mobile pour les agents : connexion (e-mail + mot de passe Supabase), choix de l'événement affecté, caméra, résultat plein écran. Les appels passent par le même site (`/api/auth`, `/api/my-events`, `/api/scan`) avec le jeton de l'agent : la base décide (droits, atomicité, rejeu).

| Écran | Cas |
|---|---|
| Vert « ENTRÉE VALIDÉE » | réponse `accepted` du serveur, et seulement elle |
| Rouge | `already_used` (premier passage, heure et agent), `revoked`, `wrong_event`, `forbidden` |
| Orange | `expired`, `invalid`, code non reconnu (rien n'est envoyé au serveur) |
| Gris « CONTRÔLE NON CONFIRMÉ » | pas de réponse : « Réessayer » renvoie la **même** requête, comptée une seule fois |

Testé avec Chromium (caméra factice) et la vraie base : réseau coupé, réponse perdue après traitement, session expirée (renouvelée), rechargement, déconnexion, agent non affecté. Le détecteur de QR du téléphone y est remplacé par une file de codes.

Limites : la lecture optique repose sur `BarcodeDetector` (Chrome sur Android) ; ailleurs (Safari) il reste la saisie manuelle du code. Si l'agent choisit « Annuler » après une réponse perdue, un nouveau scan recevra « déjà utilisé » : c'est l'état réel de la base. Un seul appareil est supposé par agent. La page `/scanner` autorise la caméra (`Permissions-Policy`) ; le reste du site l'interdit. Variables Vercel : `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `PUBLIC_SITE_URL`.

## Espace organisateur (phase 7) : `/organisateur`

Connexion, liste de ses événements, puis pour chaque événement : statistiques (invités, invitations, entrées validées / autorisées avec barre de progression, réponses, doublons, refus), liste des invités avec recherche et filtres, import CSV, émission / réémission / révocation d'une invitation.

- **Import CSV** : en-tête obligatoire, colonne « nom » obligatoire ; téléphone, e-mail, personnes, billet, notes reconnus ; séparateur `;`, `,` ou tabulation détecté ; 2000 lignes maximum. Les lignes refusées (doublon, téléphone invalide…) sont listées avec leur motif, les autres sont ajoutées.
- **Émission** : ouvre le PDF du billet, le lien à copier et un bouton WhatsApp (message pré-rempli). Le lien et le QR ne sont montrés qu'une fois ; ensuite il faut réémettre.
- **Sécurité** : `api/organizer.js` n'accepte qu'une liste blanche de fonctions, appelées avec le jeton de l'utilisateur (migration 9 : `organizer_events`, `event_guests`, lecture réservée au propriétaire ; aucun jeton ni hachage renvoyé). Tests : 16 vérifications SQL + 46 de bout en bout (statistiques égales à la base, noms à balises affichés en texte, autre organisateur refusé, PDF téléchargé, ancien lien révoqué après réémission).
- **Pas encore fait** : création et publication d'un événement par formulaire (pour l'instant, via Supabase), émission en masse, export des réponses.
