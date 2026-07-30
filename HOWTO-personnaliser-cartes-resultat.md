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

## Repérer son interface

Deux interfaces coexistent le temps de la migration vers le Système de
Design de l'État. Le mécanisme est le même dans son principe, mais **les
fichiers et les sélecteurs diffèrent** : vérifier laquelle est servie avant
de commencer.

| Interface | Port | Statut | Section |
|---|---|---|---|
| `docsearch-ui` (HTML/JS) | 8080 | en service | [§ A](#a--interface-historique-docsearch-ui) |
| [`docsearch-ui-vue`](../docsearch-ui-vue/README.md) (Vue + DSFR) | 8081 | en recette | [§ B](#b--interface-vue-docsearch-ui-vue) |

> À la bascule, la section A deviendra caduque et pourra être retirée avec
> le dépôt `docsearch-ui`. La table de correspondance des sélecteurs, en fin
> de section B, sert précisément à transposer les personnalisations
> existantes à ce moment-là.

## Trouver la clé technique d'une source

Commun aux deux interfaces. Trois façons de la récupérer :

- Inspecteur du navigateur : attribut `data-source` sur la carte.
- Admin des sources (panneau « Toutes les sources », vue unifiée
  fichier/SQL/web) : colonne « nom ».
- Directement dans le registre (`name` du `Source` renvoyé par
  `get_all_sources()`).

---

# A — Interface historique (`docsearch-ui`)

Deux fichiers dédiés dans `docsearch-ui/public/`, hors du code central
(`index.css`, `results.js`).

## A.1 Personnalisation visuelle (CSS)

Fichier : `docsearch-ui/public/css/custom-sources.css`, chargé après
`index.css` (voir `index.html`) — toute règle ici l'emporte sur le style par
défaut.

```css
.result-card[data-source="sharepoint_rh"] {
  border-left: 4px solid #0C447C;
}
.result-card[data-source="sharepoint_rh"] .result-title {
  color: #0C447C;
}
```

N'importe quel sous-élément de la carte peut être ciblé de la même façon
(`.ext-icon`, `.source-badge`, `.result-meta`, `.snippet`, ...).

## A.2 Personnalisation comportementale (JS)

Fichier : `docsearch-ui/public/js/custom-sources.js`. On y enregistre un hook
par source dans l'objet global `sourceCardHooks` (déclaré dans
`constants.js`) :

```js
sourceCardHooks['sharepoint_rh'] = function(cardEl, r) {
  const title = cardEl.querySelector('.result-title');
  if (title) title.textContent = '[RH] ' + title.textContent;
};
```

Le hook reçoit :

- `cardEl` : l'élément DOM `.result-card` déjà inséré dans la page (structure
  détaillée dans `renderCard()`, `results.js`).
- `r` : l'objet résultat brut (`id`, `title`, `source`, `filepath`, `author`,
  `date_modified`, `score`, `highlight`, ...).

Il est appelé par `applySourceCardHooks()` (`results.js`), juste après
l'insertion des cartes dans le DOM, à chaque rendu de page de résultats.
Chaque appel est isolé par un `try`/`catch` (erreur journalée en console) :
une erreur dans un hook n'empêche pas l'affichage des autres cartes.

⚠️ `custom-sources.js` est chargé après `constants.js` (qui déclare
`sourceCardHooks`) — ne pas le renommer ni le déplacer sans mettre à jour
l'ordre des `<script>` dans `index.html`.

### Limite à connaître

Ce mécanisme est pensé pour des **ajouts/modifications ponctuelles** sur une
carte déjà rendue (texte, classes, éléments ajoutés), pas pour une
restructuration complète. Pour une mise en page radicalement différente
selon la source, il faudrait une fonction de rendu dédiée par source
(duplication du gabarit de carte) — hors du périmètre de ce hook léger.

## A.3 Vérifier

Comme pour tout changement dans `docsearch-ui/public/` : reconstruire le
conteneur `ui` (le `Dockerfile` recopie `public/` dans l'image à la
construction, pas de bind-mount en dev), puis vider le cache du navigateur
avant de tester.

```bash
cd docsearch-infra
docker compose --profile dev up -d --build ui
```

---

# B — Interface Vue (`docsearch-ui-vue`)

Deux fichiers dans `docsearch-ui-vue/public/`, servis tels quels par Nginx :
ils **n'entrent pas dans le bundle**. On peut donc les éditer directement
dans le conteneur, à `/usr/share/nginx/html/`, et recharger la page — sans
reconstruire l'application.

## B.1 Personnalisation visuelle (CSS)

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

## B.2 Personnalisation du contenu (registre déclaratif)

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

C'est la différence de fond avec la section A. Sous Vue, tout ce qu'un hook
écrirait dans le DOM est **écrasé au rendu suivant** — changement de page de
résultats, bascule de la vue compacte, dépli d'une carte. Un registre de
valeurs, lu *pendant* le rendu, est idempotent par construction et survit à
ces trois cas (vérifié).

On y perd l'arbitraire du JS ; on y gagne une personnalisation qui ne
disparaît pas au premier clic — panne difficile à diagnostiquer s'il avait
fallu la subir.

## B.3 Correspondance des sélecteurs

Pour transposer une personnalisation écrite pour la section A :

| `docsearch-ui` | `docsearch-ui-vue` |
|---|---|
| `.result-card` | `.ds-result` |
| `.result-title` | `.ds-result__title` |
| `.result-meta` | `.ds-result__meta` |
| `.snippet` | `.ds-result__snippet` |
| `.ext-icon` | `.ds-result .fr-badge` |
| `sourceCardHooks['x'] = fn` | `window.docsearchSourceCards.x = { … }` |

L'attribut `data-source` est le seul élément commun aux deux interfaces.

## B.4 Vérifier

Sans reconstruction, sur un conteneur qui tourne déjà :

```bash
docker exec -it docsearch-ui-vue vi /usr/share/nginx/html/custom-sources.css
```

Puis recharger la page (vider le cache du navigateur si le changement ne se
voit pas). Pour rendre le réglage permanent, le reporter dans
`docsearch-ui-vue/public/` et reconstruire :

```bash
cd docsearch-infra
docker compose --profile dev up -d --build ui-vue
```

⚠️ Une modification faite uniquement dans le conteneur est **perdue à la
reconstruction suivante**. Le dossier `public/` du dépôt reste la source de
vérité.
