# FlashBox CRM

Application web de gestion pour l'activité de location de photobooth FlashBox.
Un seul fichier `index.html` (HTML + CSS + JavaScript), une base Supabase, aucun serveur à maintenir.

## Ce que fait l'application

| Module | Contenu |
|---|---|
| Clients | Fiches particuliers, entreprises et associations, alertes sur les infos manquantes, doublons, appel / SMS / WhatsApp / mail en un clic |
| Devis | Catalogue, modèles, numérotation `DV-0026-014-A`, indices en lettres, PDF partageable, relances |
| Planning | Prestations, rôles de chacun, indisponibilités, calendrier, détection des conflits, export vers l'agenda |
| Factures | Acompte et solde depuis un devis, suivi des paiements, relances, PDF |
| Matériel | Stock des consommables calculé automatiquement, commandes, inventaire, dépenses |
| Répartition | Partage de chaque prestation (compte, parts égales, rôles) et suivi du fonds de commerce |
| Journal | Toutes les actions de l'équipe, tracées côté base de données |

## Installation

### 1. Base de données (Supabase)

1. Créer un projet sur [supabase.com](https://supabase.com) (offre gratuite).
2. Ouvrir **SQL Editor > New query**, puis exécuter les six scripts du dossier `supabase/`, **dans l'ordre** :
   `lot1_socle.sql`, `lot2_devis.sql`, `lot3_planning.sql`, `lot4_facturation.sql`, `lot5_materiel.sql`, `lot6_repartition.sql`.
   Les scripts peuvent être relancés sans risque : ils n'effacent aucune donnée.
3. Dans **Authentication > Providers**, désactiver les inscriptions libres.
4. Dans **Authentication > Users**, créer un compte (mail + mot de passe) pour chaque associé.
5. Dans **Project Settings > API**, relever l'URL du projet et la clé `anon public`.

### 2. Configuration

Renseigner `config.js` :

```js
window.CRM_CONFIG = {
  supabaseUrl: "https://xxxxx.supabase.co",
  supabaseKey: "eyJhbGciOi...",
};
```

La clé `anon` est prévue pour être publique : la sécurité repose sur les règles RLS des scripts SQL et sur la connexion par mot de passe.

### 3. Mise en ligne (GitHub Pages)

1. Créer un dépôt et y pousser ces fichiers.
2. **Settings > Pages > Source : Deploy from a branch**, branche `main`, dossier `/ (root)`.
3. Ouvrir l'adresse fournie, se connecter, puis **installer l'application** sur le téléphone (« Ajouter à l'écran d'accueil »).

## Mode démo

Sans configuration (`config.js` laissé vide), l'application démarre en **mode démo** avec des données fictives enregistrées uniquement dans le navigateur. Pratique pour tester : il suffit d'ouvrir `index.html`.
Pour repartir des exemples : **Paramètres > Remettre les données d'exemple**.

## Fichiers

```
index.html              application complète
config.js               adresse et clé Supabase
manifest.webmanifest    installation sur téléphone
sw.js                   cache hors ligne (changer la version à chaque mise à jour)
icons/                  icônes de l'application
supabase/               les six scripts SQL, à exécuter dans l'ordre
```

## Mise à jour

Remplacer `index.html`, puis incrémenter le numéro de version dans `sw.js`
(`const CACHE = 'flashbox-crm-v8'` → `v9`) pour que les téléphones récupèrent bien la nouvelle version.
