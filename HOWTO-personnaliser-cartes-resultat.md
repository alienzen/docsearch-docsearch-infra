# HOWTO — Personnaliser les cartes de résultat par source

Chaque résultat de recherche porte une clé technique de source (`r.source`,
ex. `sharepoint_rh` — distincte du libellé affiché, voir `name` dans
`file_sources_config.py` / `web_sources_config.py` / `sql_sources_config.py`,
dupliqués à l'identique dans `docsearch-api/app/` et
`docsearch-ingestion/app/`). Deux fichiers dédiés, dans `docsearch-ui/public/`,
permettent de personnaliser l'affichage et le comportement des `.result-card`
source par source, sans toucher au code central (`index.css`, `results.js`) —
donc sans risque de perte à une future mise à jour de ces fichiers.

## 1. Trouver la clé technique d'une source

Trois façons de la récupérer :

- Inspecteur du navigateur : attribut `data-source` sur l'élément
  `.result-card`.
- Admin des sources (panneau "Toutes les sources", vue unifiée
  fichier/SQL/web) : colonne "nom".
- Directement dans le registre (`name` du `Source` renvoyé par
  `get_all_sources()`).

## 2. Personnalisation visuelle (CSS)

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

## 3. Personnalisation comportementale (JS)

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

## 4. Vérifier

Comme pour tout changement dans `docsearch-ui/public/` : reconstruire le
conteneur `ui` (le `Dockerfile` recopie `public/` dans l'image à la
construction, pas de bind-mount en dev), puis vider le cache du navigateur
(les fichiers CSS/JS statiques sont mis en cache côté client) avant de
tester.

```bash
cd docsearch-infra
docker compose --profile dev up -d --build ui
```
