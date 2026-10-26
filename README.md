# Invitéo — site vitrine

Site vitrine d'**Invitéo**, invitations numériques à Lubumbashi (RDC). Commande via WhatsApp.
HTML5 + CSS3 + JavaScript vanilla : aucun framework, aucune étape de build, aucun serveur.

## Structure

```
inviteo/
├── index.html              Page principale (toutes les sections + fenêtre de commande)
├── style.css               Styles (palette Invitéo, responsive, accessibilité)
├── script.js               Prix, calculateur, formulaire, messages WhatsApp
├── modele-anniversaire.html/.css/.js   Page de démonstration d'une invitation complète
├── mentions-legales.html   Mentions légales
├── confidentialite.html    Politique de confidentialité
├── vercel.json             Configuration Vercel (URLs propres, en-têtes de sécurité)
├── README.md
└── assets/
    ├── favicon.svg         Favicon
    ├── og-image.svg        Source de l'image d'aperçu
    └── og-image.png        Image d'aperçu 1200×630 (WhatsApp, réseaux sociaux)
```

Les maquettes d'invitation (hero et galerie) sont dessinées en CSS : aucune image lourde à charger.
Les polices (DM Sans, Fraunces) viennent de Google Fonts, avec des polices de secours système.

## Lancer le site en local

Ouvrez simplement `index.html` dans un navigateur (double-clic). Pour un rendu identique à la production :

```bash
# avec Python
python3 -m http.server 8080
# puis http://localhost:8080

# ou avec Node
npx serve .
```

## Déployer sur Vercel (gratuit)

**Option 1 — interface web**
1. Placez le dossier dans un dépôt GitHub (ou GitLab / Bitbucket).
2. Sur vercel.com : *Add New → Project*, importez le dépôt.
3. *Framework Preset* : **Other**. Laissez *Build Command* et *Output Directory* vides. Cliquez sur *Deploy*.

**Option 2 — ligne de commande**
```bash
npm i -g vercel
cd inviteo
vercel        # premier déploiement (aperçu)
vercel --prod # mise en production
```

**Après le premier déploiement** : dans `index.html`, remplacez `VOTRE-DOMAINE.vercel.app` (balise `og:image`) par l'adresse réelle du site, puis redéployez. Les aperçus de lien WhatsApp et Facebook exigent une URL absolue.

## Page de démonstration : `modele-anniversaire.html`

Une invitation d'anniversaire complète (noms fictifs), liée depuis la carte « Anniversaire » de la galerie : ouverture avec un billet qui se déchire et des confettis, compte à rebours, programme, lieu, tenue, réponse des invités.

- **Prénom personnalisé** : `modele-anniversaire.html?invite=Marie` affiche « Marie » sur le billet (texte brut, caractères filtrés).
- **Date de l'événement** : constante `EVENT_DATE` dans `modele-anniversaire.js` (fuseau de Lubumbashi, UTC+2). Après cette date, le compte à rebours affiche « C'est le grand jour ».
- **Réponse des invités simulée** : le formulaire valide les champs mais n'envoie ni n'enregistre rien. Un vrai RSVP demandera un backend.
- **Accessibilité** : animations désactivées si le visiteur a demandé moins de mouvement ; touche Échap ou bouton pour ouvrir ; le compte à rebours est annoncé une fois par minute aux lecteurs d'écran.

## Système d'invitations personnalisées (en construction)

Le dossier `supabase/` contient la base de données du futur système (événements, invités, QR codes uniques, contrôle d'entrée) : schéma, sécurité, tests. Voir `supabase/README.md` pour l'état exact. Le site vitrine n'en dépend pas et fonctionne comme avant.

## Changer le numéro WhatsApp ou un prix

- **Numéro** : constante `CONFIG.whatsappNumber` en haut de `script.js` (format international, sans `+`). Tous les boutons et liens WhatsApp en dépendent. Le numéro affiché en clair dans `mentions-legales.html` est à modifier à la main.
- **Prix** : objet `PLANS` dans `script.js`. Les montants affichés dans la page (cartes, calculateur, FAQ, formulaire) sont recalculés depuis cet objet au chargement.

## Fonctionnalités opérationnelles

- Navigation sticky avec menu mobile, lien actif selon la section, lien d'évitement clavier.
- Hero, avantages, trois cartes tarifaires (Plus au centre, badge « Offre recommandée »), étapes, galerie de six maquettes, FAQ (9 questions), pied de page.
- **Calculateur** : total de chaque formule calculé en JavaScript, en centimes entiers (aucune erreur d'arrondi). Refuse les quantités vides, nulles, négatives, décimales ou non numériques, et au-delà de 10 000.
- **Formulaire de commande** (fenêtre modale) : champs obligatoires validés avec messages d'erreur clairs, date facultative non passée, récapitulatif, aperçu du message, bouton « Ouvrir WhatsApp », bouton « Copier le message » en secours.
- **Boutons « Commander un modèle similaire »** : ouvrent le formulaire avec le type d'événement prérempli et le modèle ajouté au message.
- **Liens WhatsApp** `https://wa.me/243990228413?text=…` encodés avec `encodeURIComponent()`. Le site n'envoie rien automatiquement : le client relit le message et appuie sur « Envoyer » dans WhatsApp.
- Bouton WhatsApp flottant sur mobile uniquement.
- Respect de `prefers-reduced-motion`, contrastes AA (texte sur orange en charbon, orange foncé `#B4461A` pour le petit texte sur fond clair), cibles tactiles de 44 px minimum.
- Aucun cookie, aucun LocalStorage, aucune donnée envoyée à un serveur, aucune clé secrète.

## Ce qui nécessitera une évolution (hors MVP)

Ces fonctions sont décrites sur le site comme dépendant de la formule et de leur disponibilité effective. Elles ne sont **pas** simulées par le site :

| Fonction | Dépendance nécessaire |
|---|---|
| Génération réelle des QR codes (un par invitation ou par invité) | Générateur de QR côté outil interne ou service tiers |
| Confirmation de présence (RSVP), liste et suivi des réponses | Backend sécurisé + base de données |
| Gestion des tables, des places et des préférences (Premium) | Backend + espace organisateur |
| Contrôle d'accès à l'entrée par scan | Application de scan + base de données |
| Paiement en ligne | Prestataire de paiement (ex. Mobile Money) à configurer |
| Envoi automatique de messages WhatsApp | WhatsApp Business API (compte vérifié, service payant) |
| Espace client | Authentification + backend |

## À compléter avant la mise en ligne publique

1. `og:image` : remplacer `VOTRE-DOMAINE.vercel.app` (voir plus haut).
2. `mentions-legales.html` : ajouter, si applicable, la dénomination sociale, le numéro RCCM / Id. Nat. / NIF et le responsable de publication (un commentaire `TODO` marque l'endroit).
3. Faire relire les mentions légales et la politique de confidentialité par un professionnel : ce sont des textes de base, pas un avis juridique.
4. Confirmer à l'équipe les réponses de la FAQ (format de livraison, délais, modalités de paiement), pour qu'elles correspondent à la pratique réelle.

## Vérifications effectuées

Calculs et liens testés par script (Node) : voir le compte rendu de livraison. Tests à refaire sur appareil avant le lancement : ouverture de WhatsApp depuis un téléphone Android (application installée et non installée) et depuis un ordinateur (WhatsApp Web ou application de bureau).
