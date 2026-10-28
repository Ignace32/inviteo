# Invitéo — mise en ligne de la plateforme (phase 8)

Durée : environ 45 minutes la première fois. Le site vitrine reste en ligne pendant toute l'opération : tant que Supabase n'est pas branché, `/i/…`, `/scanner` et `/organisateur` affichent simplement « service indisponible ».

## 0. Ce qu'il vous faut
- Le dépôt GitHub du site (déjà relié à Vercel).
- Un compte gratuit sur supabase.com.
- 3 adresses e-mail de test : un organisateur, un agent de contrôle, et vous (administrateur).

## 1. Créer le projet Supabase
1. supabase.com → **New project**. Nom : `inviteo`. Choisissez la région la plus proche (Europe ou Afrique du Sud si proposée). Notez le mot de passe de la base (il ne sert pas au site).
2. Attendez la fin de la création (1 à 2 minutes).

## 2. Appliquer la base de données
1. **SQL Editor** → *New query*.
2. Ouvrez le fichier `supabase/all_migrations.sql` du projet, copiez tout, collez, **Run**.
3. Résultat attendu : « Success. No rows returned ». Vérifiez dans **Table Editor** : 13 tables (`events`, `guests`, `invitations`…) et, dans **Storage**, deux buckets privés (`event-assets`, `event-documents`).
4. Si une erreur apparaît : copiez-la telle quelle et envoyez-la-moi. Ces migrations ont été testées sur un vrai PostgreSQL 16 mais **pas encore** sur Supabase lui-même ; une différence de version est possible.

## 3. Fermer les inscriptions publiques (important)
**Authentication → Sign In / Providers → Email** : désactivez **Allow new users to sign up**. Sinon n'importe qui pourrait se créer un compte organisateur. Les comptes se créent uniquement par vous, à l'étape suivante.

## 4. Créer les comptes
1. **Authentication → Users → Add user → Create new user** : e-mail + mot de passe, cochez **Auto Confirm User**. Faites-le pour l'organisateur, l'agent et vous.
2. Tout compte est « organisateur » par défaut. Dans **SQL Editor**, ouvrez `supabase/accounts_example.sql`, remplacez les e-mails et exécutez les blocs voulus (agent, administrateur).
3. Ouvrez `supabase/first_event_example.sql`, remplacez l'e-mail de l'organisateur, exécutez : un événement de démonstration est créé **et publié**. Notez l'identifiant affiché (message « Événement créé »).
4. Retournez dans `accounts_example.sql`, bloc « Affectation de l'agent », mettez cet identifiant et exécutez : l'agent peut maintenant contrôler cet événement.

## 5. Récupérer les clés
**Project Settings → API** :
- *Project URL* → `SUPABASE_URL`
- *anon public* → `SUPABASE_ANON_KEY`
- *service_role* (secrète, cliquez « Reveal ») → `SUPABASE_SERVICE_ROLE_KEY`

## 6. Variables d'environnement sur Vercel
Vercel → votre projet → **Settings → Environment Variables**, ajoutez pour *Production* (et *Preview* si vous voulez) :

| Nom | Valeur |
|---|---|
| `SUPABASE_URL` | Project URL |
| `SUPABASE_ANON_KEY` | clé anon |
| `SUPABASE_SERVICE_ROLE_KEY` | clé service_role |
| `PUBLIC_SITE_URL` | `https://inviteo-dun.vercel.app` (sans `/` final) |

La clé `service_role` ne doit apparaître **nulle part ailleurs** : ni dans GitHub, ni dans un fichier du site, ni dans une conversation.

## 7. Publier le code
Poussez le dossier du projet sur GitHub (la branche reliée à Vercel). Vercel redéploie seul. Si vous avez ajouté les variables **après** le dernier déploiement : *Deployments → … → Redeploy*, sinon elles ne sont pas prises en compte.

## 8. Vérification automatique
Depuis un ordinateur avec Node 20 ou plus :

```bash
tests/smoke.sh https://inviteo-dun.vercel.app --headers
```

Le script contrôle les pages, les en-têtes de sécurité et que les fonctions serveur répondent (une réponse « 503 » sur la connexion signale des variables manquantes). Avec `SMOKE_EMAIL` et `SMOKE_PASSWORD` (compte agent), il teste aussi une vraie connexion.

## 9. Essai complet avec de vrais téléphones
Suivez `ESSAI_TELEPHONES.md`. C'est la seule façon de valider la caméra, l'impression et WhatsApp ; je ne peux pas le faire depuis mon environnement.

## 10. Avant de vendre
- Remplacez dans `mentions-legales.html` et `confidentialite.html` les informations d'identification (RCCM, Id. Nat., NIF) et faites relire ces textes par un professionnel : ils décrivent désormais un traitement de données d'invités (noms, téléphones).
- Le plan gratuit de Supabase met un projet en pause après une semaine sans activité. Pour un événement réel, passez au plan payant ou gardez le projet actif.
- Faites une sauvegarde avant chaque événement (Supabase → Database → Backups, ou export CSV des invités depuis le tableau de bord).
