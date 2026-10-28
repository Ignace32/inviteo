# Essai sur de vrais téléphones

Matériel : 1 téléphone Android avec Chrome (agent), 1 autre téléphone (invité), 1 ordinateur (organisateur), une imprimante ou un second écran. Durée : 30 minutes. Cochez chaque ligne ; notez toute anomalie avec une capture d'écran.

## A. Organisateur (ordinateur)
- [ ] `/organisateur` : connexion avec le compte organisateur ; l'événement de démonstration apparaît.
- [ ] Importer un CSV de 5 invités (un avec un numéro WhatsApp réel). Le résultat indique 5 ajoutés.
- [ ] Émettre l'invitation de l'invité qui a un numéro : le PDF se télécharge, le bouton WhatsApp ouvre la conversation avec le message et le lien.
- [ ] Émettre 2 autres invitations (un billet de 1 personne, un billet de 3 personnes : colonne « personnes »).

## B. Invité (autre téléphone)
- [ ] Le lien reçu sur WhatsApp s'ouvre ; l'enveloppe s'ouvre ; noms, date, lieu et programme sont corrects.
- [ ] Le billet (QR) s'affiche sous la page. Il reste lisible en plein soleil (luminosité de l'écran au maximum).
- [ ] Répondre « Je serai présent » avec 2 personnes ; recharger la page : la réponse est conservée.
- [ ] Le tableau de bord de l'organisateur affiche la réponse après actualisation.

## C. PDF imprimé
- [ ] Imprimer un PDF en A5 (ou A4) en noir et blanc : le QR reste lisible à 20 cm et à 40 cm.
- [ ] Le texte accentué (nom de l'invité) s'imprime correctement.

## D. Agent (téléphone Android, Chrome)
- [ ] `/scanner` : connexion avec le compte agent ; l'événement est choisi automatiquement.
- [ ] Le navigateur demande l'accès à la caméra : autoriser. L'image s'affiche.
- [ ] Scanner le QR affiché sur l'autre téléphone : écran **vert**, nom correct, « Entrée 1 sur … ». Délai ressenti : moins de 2 secondes.
- [ ] Scanner le même QR : écran **rouge** « DÉJÀ UTILISÉ » avec l'heure du premier passage.
- [ ] Scanner le QR du billet de 3 personnes 3 fois : 3 entrées vertes, la 4ᵉ rouge.
- [ ] Scanner le QR imprimé (PDF papier) : écran vert.
- [ ] Mode avion, puis scanner un nouveau billet : écran **gris** « CONTRÔLE NON CONFIRMÉ » (jamais vert). Désactiver le mode avion, « Réessayer » : écran vert, **une seule** entrée comptée.
- [ ] Depuis le tableau de bord, révoquer une invitation puis la scanner : écran rouge « RÉVOQUÉE ».
- [ ] Scanner un QR quelconque (un autre site) : « CODE NON RECONNU ».

## E. Deux agents en même temps
- [ ] Deux téléphones agents scannent le même QR au même moment : un seul vert, l'autre rouge.

## F. Après l'essai
- [ ] Tableau de bord : « entrées validées » = nombre de verts obtenus ; « tentatives en double » et « scans refusés » cohérents.
- [ ] Supprimer les données d'essai ou créer un nouvel événement pour le vrai événement.

Safari sur iPhone ne lit pas les QR dans le scanner (limite du navigateur) : prévoir des téléphones Android pour les agents, ou la saisie manuelle du code.
