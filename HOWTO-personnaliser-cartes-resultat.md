# HOWTO — Personnaliser les cartes de résultat par source

Chaque résultat de recherche porte une clé technique de source (`r.source`,
ex. `sharepoint_rh` — distincte du libellé affiché, voir `name` dans
`file_sources_config.py` / `web_sources_config.py` / `sql_sources_config.py`,
dupliqués à l'identique dans `docsearch-api/app/` et
`docsearch-ingestion/app/`). Deux fichiers statiques, servis tels quels,
permettent de personnaliser les cartes source par source **sans toucher au
code central** — donc sans risque de perte à une mise à jour — et **sans
reconstruire l'application** : on les édite dans le conteneur, on recharge
la page.

## Une seule interface désormais

Ce document décrivait les deux interfaces. L'historique (`docsearch-ui`,
HTML/JS, servie sur le port 8082) a été retirée : son dépôt est archivé en
bundle git à la racine, elle n'a ni unité systemd ni service déclaré. La
section qui lui était consacrée est supprimée — son contenu reste dans
l'historique de ce dépôt et dans le bundle, et la procédure de restauration
est dans le [README](README.md), § Architecture multi-dépôts.

Reste [`docsearch-ui-vue`](../docsearch-ui-vue/README.md) (Vue + DSFR, port
8080). Si une personnalisation écrite pour l'ancienne interface doit être
reprise, la transposer avec la table de correspondance des sélecteurs
([§ 3](#3-correspondance-des-sélecteurs)) : le principe est le même, les
fichiers et les sélecteurs diffèrent.

## Trouver la clé technique d'une source

Trois façons de la récupérer :

- Inspecteur du navigateur : attribut `data-source` sur la carte.
- Admin des sources (panneau « Toutes les sources », vue unifiée
  fichier/SQL/web) : colonne « nom ».
- Directement dans le registre (`name` du `Source` renvoyé par
  `get_all_sources()`).

---

# Personnalisation (`docsearch-ui-vue`)

Deux fichiers dans `docsearch-ui-vue/public/`, servis tels quels par Nginx :
ils **n'entrent pas dans le bundle**. On peut donc les éditer directement
dans le conteneur, à `/usr/share/nginx/html/`, et recharger la page — sans
reconstruire l'application.

## 1. Personnalisation visuelle (CSS)

Fichier : `custom-sources.css`. Il est référencé **en fin de `<body>`**, donc
après la feuille générée par Vite dans `<head>` : à spécificité égale, ce
qui est écrit ici l'emporte.

```css
.ds-result[data-source='sharepoint_rh'] .ds-result__title {
  color: var(--text-title-blue-france);
}
```

Préférer les **jetons de couleur DSFR** (`var(--text-title-blue-france)`,
`var(--background-alt-grey)`…) aux couleurs en dur : eux seuls tiennent le
contraste en thème clair comme en thème sombre.

## 2. Personnalisation du contenu (registre déclaratif)

Fichier : `custom-sources.js`. Il publie un objet, une entrée par source :

```js
window.docsearchSourceCards = {
  sharepoint_rh: { badge: 'RH', titlePrefix: '[RH] ', accent: '#0c447c' },
}
```

| Clé | Effet |
|---|---|
| `badge` | badge supplémentaire, à côté de l'extension |
| `titlePrefix` | texte inséré devant le titre du document |
| `accent` | couleur du liseré gauche de la carte |

Toutes facultatives. Les textes sont rendus **comme du texte**, donc
échappés : y placer du HTML l'afficherait littéralement. Ce que le registre
ne couvre pas relève de `custom-sources.css`.

### Pourquoi un registre et non un hook

C'est la différence de fond avec l'ancienne interface, qui exposait des
hooks JS (`sourceCardHooks`). Sous Vue, tout ce qu'un hook
écrirait dans le DOM est **écrasé au rendu suivant** — changement de page de
résultats, bascule de la vue compacte, dépli d'une carte. Un registre de
valeurs, lu *pendant* le rendu, est idempotent par construction et survit à
ces trois cas (vérifié).

On y perd l'arbitraire du JS ; on y gagne une personnalisation qui ne
disparaît pas au premier clic — panne difficile à diagnostiquer s'il avait
fallu la subir.

## 3. Correspondance des sélecteurs

Pour transposer une personnalisation écrite pour l'interface historique :

| `docsearch-ui` | `docsearch-ui-vue` |
|---|---|
| `.result-card` | `.ds-result` |
| `.result-title` | `.ds-result__title` |
| `.result-meta` | `.ds-result__meta` |
| `.snippet` | `.ds-result__snippet` |
| `.ext-icon` | `.ds-result .fr-badge` |
| `sourceCardHooks['x'] = fn` | `window.docsearchSourceCards.x = { … }` |

L'attribut `data-source` est le seul élément commun aux deux interfaces.

## 4. Vérifier

Sans reconstruction, sur un conteneur qui tourne déjà :

```bash
sudo podman exec -it docsearch-ui-vue vi /usr/share/nginx/html/custom-sources.css
```

Puis recharger la page (vider le cache du navigateur si le changement ne se
voit pas). Pour rendre le réglage permanent, le reporter dans
`docsearch-ui-vue/public/` et reconstruire :

```bash
cd docsearch-infra
sudo ./manage.sh build ui
sudo systemctl restart docsearch-ui-vue
```

⚠️ Une modification faite uniquement dans le conteneur est **perdue à la
reconstruction suivante**. Le dossier `public/` du dépôt reste la source de
vérité.

