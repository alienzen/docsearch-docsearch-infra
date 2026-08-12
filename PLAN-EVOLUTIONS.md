# Sept évolutions de DocSearch — plan d'implémentation

Arrêté le 2026-08-12, à partir d'une revue de l'existant
([FEATURES.md](FEATURES.md) et les README des quatre dépôts de code). Les
numéros sont ceux de la proposition d'origine : le **5** (assistant RAG réel)
et le **9** (pages légales et déclaration RGAA) n'y figurent pas — le premier
attend un arbitrage matériel, le second n'a pas besoin d'un plan.

Ce document dit **où chaque chose se branche dans le code existant, ce qui
casse si on s'y prend mal, et comment on vérifie**. Il ne recopie pas ce que
les README disent déjà.

---

## Les cinq invariants

Ils valent pour les sept chantiers, et aucun n'est négociable.

1. **Rien ne contourne l'ACL.** Toute nouvelle lecture d'Elasticsearch passe
   par `build_acl_filter()` et `_searchable_source_names()`. Ça vise en
   particulier les fonctions qui ne renvoient pas de documents : une
   agrégation de titres, un compte de doublons ou une suggestion de saisie
   fuient exactement autant qu'un résultat de recherche.
2. **La production n'a pas Internet** (voir
   [HOWTO-deploiement-hors-ligne.md](HOWTO-deploiement-hors-ligne.md)) : aucun
   modèle téléchargé au démarrage, aucune ressource distante, aucune image
   `latest`.
3. **Toute fonctionnalité visible a sa bascule d'administration**, déclarée aux
   **trois** endroits de `ui_config.py` (`DEFAULT_UI_CONFIG`, le modèle
   `UiConfigUpdate`, la chaîne `set_param`) — sinon le POST répond 200 sans
   rien enregistrer. Une bascule qui **ajoute** un élément à l'écran démarre à
   `false`, y compris dans le repli de `stores/uiConfig.ts`.
4. **Aucune régression de `/search`.** Les chantiers 2 et 4 touchent au chemin
   chaud : ce qui coûte ne s'exécute que dans le cas où il sert (zéro résultat,
   regroupement demandé), jamais sur la recherche nominale.
5. **Ce qui change la construction de requête change deux fichiers.**
   `search_api.py::search()` et `search_query.py` sont deux implémentations
   volontairement séparées ; leur divergence fait mentir les alertes. Aucun des
   sept chantiers n'y touche — si l'un finit par le faire, c'est un signal
   d'alerte, pas un détail.

## Séquencement conseillé

| Lot | Chantiers | Pourquoi ensemble |
|---|---|---|
| **A** | ~~7 permaliens, 8a historique, 1 autocomplétion~~ — **lot terminé le 2026-08-12** | Aucun changement de mapping ni d'index. 8a produit la donnée que 1 consomme. Le meilleur rapport visible/risque. |
| **B** | ~~3 rétention, 2 zéro résultat~~ — **lot terminé le 2026-08-12** | Hygiène. 3 protège le disque avant que les chantiers suivants n'écrivent davantage. |
| **C** | 4 doublons ✔, 6 synonymes ✔ — **résultats épinglés restants** | **Les deux seuls qui touchent au mapping et aux réglages des index** : `close`/`open` pour l'un, réindexation pour l'autre. À grouper dans une seule fenêtre d'exploitation. |
| **D** | 8b récemment consultés, 8c collections partagées | Confort, sans dépendance. |

Charge totale estimée : **17 à 22 jours-homme**, hors recette.

---

## §1. Autocomplétion de la barre de recherche — **fait le 2026-08-12**

Livré : `GET /suggest` (`user_history.py`), `SearchSuggestions.vue`
(combobox annotée ARIA, navigation clavier, anti-rebond 150 ms,
annulation de la requête précédente), bascule `autocomplete_enabled`
désactivée par défaut. 9 tests d'interface, 13 tests d'API contre un vrai
Elasticsearch — dont le cloisonnement ACL des suggestions et
l'échappement des préfixes hostiles.

**Écart avec le plan ci-dessous, mesuré plutôt que supposé** : le volet
corpus porte sur l'auteur et les mots-clés, **pas sur le nom de
fichier**. Le coût d'un `include` régex tient à la cardinalité du champ
(151 auteurs et 102 mots-clés distincts, contre 22 494 noms de fichier
sur la pile de dev — un par document) : les deux premiers restent bornés
quand le corpus grandit, le troisième croît avec lui. Le nom de fichier
suppose donc un champ dédié et une réindexation, à traiter avec le lot C.

**Constat** — aucun `suggest` nulle part dans `search_api.py`. Sur 4 000 000 de
documents, l'utilisateur tape à l'aveugle, et l'indicateur de recherches sans
résultat de `stats.html` en porte la trace.

### 1.1 Deux gisements, et un seul est sans danger

| Source | Coût | Danger |
|---|---|---|
| **Historique personnel** (`search_logs`, `username` en `keyword`, `query` avec sous-champ `.keyword`) | nul, la donnée est déjà là | aucun — l'utilisateur ne voit que ses propres requêtes |
| **Corpus** (`filename`, `author`, `keywords`, tous en `keyword`) | agrégation `terms` avec `include` préfixé | **fuite si l'agrégation n'est pas filtrée par l'ACL** |
| Requêtes populaires **tous utilisateurs** | nul | ❌ **à ne pas faire** : une requête contient souvent le nom d'un dossier confidentiel, et la suggérer le divulgue à qui ne le connaissait pas |

Le troisième gisement est le plus tentant et le seul à proscrire. À écrire dans
le code, pas seulement ici.

### 1.2 API

Route **nouvelle** `GET /suggest?q=&limit=8`, sous `Depends(current_user)` :

- `q` de moins de 2 caractères → liste vide, sans toucher ES ;
- volet « vos recherches » : `search_logs`, `{"term": {"username": user}}`,
  agrégation `terms` sur `query.keyword` avec `include: "<q échappé>.*"`,
  triée par date de dernière occurrence ;
- volet « dans les documents » : agrégation `terms` sur `filename`,
  `author`, `keywords` — **dans une requête portant `build_acl_filter(user)`
  et le filtre de sources cherchables**, pas sur l'index nu ;
- ⚠️ `include` prend une **expression régulière Lucene**, pas un glob :
  échapper `. ( ) [ ] { } * + ? | \ " ~ ^ /` dans `q`, sans quoi une
  parenthèse tapée par l'utilisateur produit une 400 et une saisie comme
  `.*` fait scanner tout le dictionnaire de termes ;
- budget de temps : `timeout` ES court (200 ms) et repli sur liste vide —
  une suggestion qui se fait attendre est pire que pas de suggestion.

Pas de nouvelle dépendance Python.

### 1.3 Interface

- `src/api/search.ts` : `suggest(q, signal)`, avec **annulation** de la requête
  précédente (`AbortController`, `client.ts`) et anti-rebond de 150 ms.
- Composant `SearchSuggestions.vue` sous la barre du `DsfrHeader`. La barre est
  un composant DSFR : son identifiant se passe par la prop `searchbar-id`,
  jamais en attribut, sinon `vue-dsfr` en tire un au sort à chaque rendu.
- Accessibilité, non facultative sur un service de l'État :
  `role="combobox"`, `aria-expanded`, `aria-activedescendant`, navigation
  ↑/↓/Échap/Entrée, et la liste doit rester utilisable au clavier seul.
  Les identifiants suivent la convention du dépôt (`recherche-suggestions`,
  kebab-case français) et la spec de page appelle `idsDupliques()`.
- ⚠️ **Ne pas se battre avec le parseur de syntaxe avancée** (`search.ts`,
  `parseAdvancedQuery`) : tant que la saisie contient un opérateur
  (`auteur:`, `type:`…), l'autocomplétion se tait. Suggérer les *valeurs* d'un
  opérateur est une v2, à ne pas mélanger.
- Bascule `autocomplete_enabled`, à `false` par défaut (invariant 3).

### 1.4 Recette

`vitest` sur le composant (navigation clavier, annulation, silence en syntaxe
avancée) ; côté API, un test qui vérifie qu'un document non visible par
`bob.user` **ne produit aucune suggestion** — c'est le seul test qui compte
vraiment ici.

**Effort : 2 à 3 j** (dont 1 j si l'on se limite au volet historique).

---

## §2. Écran « zéro résultat » actionnable — **fait le 2026-08-12**

Livré : bloc `zero_result` de `/search` (un seul `msearch`, uniquement
quand le total est nul), `EmptyResultsHelp.vue`. 10 tests d'API contre un
vrai Elasticsearch, 8 d'interface.

**Un piège trouvé en route, absent du plan** : le correcteur
orthographique lit le dictionnaire de termes de l'index, que l'ACL ne
filtre pas — il pouvait donc proposer un mot tiré d'un document interdit.
La correction n'est rendue que si elle donne des résultats visibles par
l'utilisateur, ce qui ferme la fuite et écarte du même coup les
corrections qui ne mènent nulle part.

**Écart avec le plan** : pas de champ `zero_result_helped` dans le
journal. Mesurer si l'aide a servi demande de rattacher la recherche
suivante à la précédente, ce qui est un sujet en soi — à reprendre si la
question se pose vraiment.

**Constat** — `ResultsList.vue:80` affiche « Aucun résultat ne correspond à ces
critères. » et rien d'autre. L'administration, elle, dispose déjà de la liste
des recherches infructueuses : le diagnostic existe, l'aide à l'utilisateur non.

### 2.1 Étendre `/search`, ne pas créer de route

Précédent explicite du dépôt (statistiques par groupe) : on étend les endpoints
existants. Quand — **et seulement quand** — `total == 0`, la réponse gagne un
bloc :

```json
"zero_result": {
  "did_you_mean": "rapport financier",
  "relaxations": [
    {"drop": "extension", "label": "sans le filtre « .pdf »", "count": 12},
    {"drop": "date",      "label": "sans la période",          "count": 4}
  ],
  "other_sources": [{"source": "archives", "label": "Archives", "count": 7}]
}
```

- **`did_you_mean`** : `term suggester` sur `content` — aucun changement de
  mapping. Un `phrase suggester` serait meilleur mais réclame un champ à
  shingles, donc une réindexation : à garder pour le lot C si le besoin se
  confirme.
- **`relaxations`** : un `msearch` avec `size: 0`, **une sous-requête par
  filtre actif retiré**, plafonné à 6. Les filtres sont déjà construits un par
  un dans `search()` (`extension_filter`, `author_filter`, … et
  `base_filters`), la liste s'obtient sans réécrire la requête.
- **`other_sources`** : compte par source **hors** sélection courante, en
  respectant `searchable` et l'ACL.

⚠️ **Chaque compte annoncé doit être atteignable.** Un « 12 résultats sans le
filtre .pdf » calculé hors ACL, puis un clic qui affiche une liste vide, coûte
plus de confiance qu'un écran vide honnête. Les sous-requêtes portent donc les
mêmes `base_filters` (ACL et sources) que la requête principale.

Coût sur le chemin nominal : **nul**, le bloc n'est calculé que sur un total nul.

### 2.2 Interface

Nouveau composant — ne pas surcharger `EmptySearchState.vue`, qui est l'état
d'**avant** toute recherche, un cas différent. L'écran propose, dans cet ordre :
la correction orthographique, les relâchements de filtre en boutons cliquables
(un clic retire le filtre et relance), les autres sources, puis le rappel de la
syntaxe avancée (`SearchHelp.vue` existe déjà, le lien suffit).

### 2.3 Boucle avec l'administration

Ajouter au journal un champ `zero_result_helped` (booléen) : on saura si l'aide
proposée a été suivie d'une recherche fructueuse. Sans lui, on ne mesurera
jamais si ce chantier a servi à quelque chose.

**Effort : 2 j.**

---

## §3. Rétention des journaux — **fait le 2026-08-12**

Livré : `log_retention.py`, tick quotidien dans `alert_worker.py` (verrou
Redis dont la durée de vie EST l'intervalle), cinq durées réglables à
chaud, `GET /admin/retention` pour prévisualiser. 9 tests contre un vrai
Elasticsearch (le dixième exige Redis et se saute sans lui).

**Écart avec le plan, dans le sens de la simplicité** : pas de panneau
d'administration dédié. Les durées vivent dans `DEFAULT_RUNTIME`
(`runtime_config.py`), dont le panneau « Paramètres opérationnels » rend
déjà toutes les clés génériquement — il ne restait qu'à écrire les
libellés d'aide. À noter pour la prochaine fois : `DEFAULT_RUNTIME` n'a
PAS à rester identique entre les deux dépôts, chacun y déclare ce dont il
est propriétaire (c'est écrit en tête du fichier).

**Ajout non prévu** : la route d'aperçu. Un réglage destructeur qu'on ne
peut pas prévisualiser ne se règle jamais, ou se règle une fois de trop.

**Constat** — cinq index de journalisation grossissent **sans aucune purge** :
`search_logs`, `nps_responses`, `suggestions`, `admin_audit_log`,
`login_events`. Ni ILM, ni `delete_by_query`, nulle part. Deux problèmes
distincts : le disque — le flood-stage à 95 % a déjà passé les index en lecture
seule le 2026-08-10, cluster « green » et voyants au vert pendant que les
écritures se perdaient — et la conservation sans durée fixée de données
personnelles (identifiant, requêtes, adresse IP).

### 3.1 Ce qui n'est PAS un journal

`custom_keywords` et `saved_collections` sont des **données utilisateur**, pas
des traces. Le module ne doit jamais les connaître : la liste des index purgés
est explicite et close, jamais un motif `*_logs`.

### 3.2 Mécanisme

Nouveau module `docsearch-api/app/log_retention.py`, appelé par un **tick
quotidien ajouté à `alert_worker.py`** — le conteneur tourne déjà, il porte la
même image, et le dépôt a déjà tranché contre l'ordonnanceur externe (voir
l'en-tête d'`alert_worker.py`). Verrou Redis avec TTL (`SET NX`) pour que
plusieurs exemplaires ne se marchent pas dessus, et clé
`docsearch:retention:last_run` pour ne pas rejouer avant 24 h.

`delete_by_query` sur `timestamp < now-Nd`, avec `conflicts="proceed"`,
`slices="auto"` et `requests_per_second` bridé : sur un cluster qui sert des
recherches, une purge non throttlée se voit à l'écran.

⚠️ `delete_by_query` **ne rend pas le disque immédiatement** — les segments ne
sont réécrits qu'à la fusion. Ne pas enchaîner un `_forcemerge` automatique :
c'est une opération lourde qui doit rester une décision d'exploitation.

**ILM plutôt que `delete_by_query` ?** Plus propre sur le principe, mais il
faudrait convertir ces index en flux de données ou en alias à rollover, donc
migrer l'existant. Hors périmètre ; à reconsidérer le jour où l'un de ces index
deviendra assez gros pour que la purge par requête coûte.

### 3.3 Réglages

Dans `runtime_config` (donc à chaud), une durée par index, exposée dans un
panneau « Journaux et conservation » du panneau d'administration :

| Index | Défaut proposé | Raison |
|---|---|---|
| `search_logs` | 12 mois | comparaison année sur année possible |
| `login_events` | 12 mois | trace de sécurité |
| `admin_audit_log` | 36 mois | c'est la trace qui protège l'administrateur |
| `nps_responses` | 24 mois | tendance de satisfaction |
| `suggestions` | 24 mois | porte un `username` quand elle n'est pas anonyme |

`0` signifie **conservation illimitée**, écrit tel quel dans l'interface. Chaque
passage journalise le nombre de documents supprimés par index — une purge
silencieuse de journaux est exactement ce qu'on ne veut pas — et **la purge du
journal d'audit s'inscrit elle-même dans le journal d'audit**.

### 3.4 Effets de bord à annoncer

- `stats.html` doit dire sur quelle fenêtre portent ses chiffres, sinon la
  volumétrie « qui baisse » sera lue comme une baisse d'usage.
- L'historique personnel (§8a) et les documents récemment consultés (§8b) sont
  bornés par la même fenêtre. C'est cohérent, mais ça se dit.
- Si les index sont déjà en lecture seule (disque > 95 %), la purge échoue elle
  aussi : le journal doit le dire explicitement, en nommant le blocage
  (`index.blocks.read_only_allow_delete`), qu'ES relève seul sous 90 %.

### 3.5 Recette

`pytest` sur un vrai ES : injecter des documents datés, vérifier que seuls les
plus anciens disparaissent, que `0` ne supprime rien, que `custom_keywords` et
`saved_collections` sont intacts, et que la purge du journal d'audit y laisse
une ligne.

**Effort : 2 j.**

---

## §4. Détection de doublons — **fait le 2026-08-12**

Livré : `content_sha256` calculé par les deux chemins d'indexation,
`GET /admin/duplicates` (agrégation + cache Redis quotidien), panneau
« Doublons », et `./manage.sh backfill-hashes` pour l'existant. 6 tests
contre un vrai Elasticsearch.

**Écart avec le plan** : le regroupement des copies dans les résultats de
recherche (`collapse`) n'est PAS livré. Le rapport d'administration
répond au besoin réel — savoir combien de place les copies occupent et où
elles sont — alors que `collapse` change les comptes affichés à tous les
utilisateurs pour un gain moins clair. À reprendre si la demande vient du
terrain.

**Constat** — le champ `doc_hash` du mapping
([indexer.py:466](../docsearch-ingestion/app/indexer.py:466)) vaut le `doc_id`,
c'est-à-dire un MD5 du **chemin**. Rien, aujourd'hui, ne peut savoir que le
même fichier est indexé vingt fois sous vingt chemins.

**Constat annexe, à trancher séparément** : `worker.py:209` saute tout fichier
dont le `doc_id` existe déjà (`es.exists`). Un scan de réindexation ne met donc
**jamais** à jour un fichier déjà indexé dont le contenu a changé — seul le
watcher rattrape les modifications. C'est peut-être voulu ; ça mérite d'être su.

### 4.1 Un champ neuf, pas un détournement

`content_sha256`, en `keyword`, ajouté au mapping de `create_index()` (additif,
`put_mapping` le propage aux index existants). **Ne pas réutiliser `doc_hash`** :
en changer la sémantique casserait silencieusement tout code qui s'y fie.

Hacher le **flux binaire du fichier**, par blocs de 64 kio, et non le texte
extrait : le texte dépend de la version de Tika, donc une montée de version
ferait bouger tous les hachages d'un coup. Le fichier est de toute façon lu pour
Tika, le surcoût est celui d'un SHA-256 sur un flux déjà en mémoire.

- **Membres d'archive** : hacher le flux extrait du membre, pas l'archive.
- **Sources SQL et web** : pas de fichier. Champ **absent**, assumé — hacher une
  ligne SQL et un fichier bureautique reviendrait à comparer deux choses qui ne
  se comparent pas.
- **Limite connue à écrire dans le README** : deux fichiers au contenu identique
  mais aux métadonnées différentes (même document réenregistré) ne sont pas
  détectés. C'est le prix du hachage binaire, et l'écrasante majorité des
  doublons d'un partage bureautique sont des copies à l'octet près
  (« rapport - Copie.pdf »).

### 4.2 Les trois usages

**a. Rapport d'administration** — le plus rentable, et le seul sans effet sur
l'expérience de recherche. Agrégation `terms` sur `content_sha256` avec
`min_doc_count: 2`, `size: 50`, et une somme de `size` pour chiffrer l'espace
occupé en double. ⚠️ Sur 4 M de documents cette agrégation n'est pas gratuite :
la calculer une fois par nuit et **mettre le résultat en cache dans Redis**,
comme le reste des états consultés trois fois par an.

**b. Regroupement dans les résultats** — `collapse` sur `content_sha256` avec
`inner_hits` pour lister les copies (« + 7 copies »). Trois pièges :
- `total` continue de compter les **documents**, pas les groupes : l'afficher
  tel quel après regroupement fait mentir la pagination ;
- les copies remontées par `inner_hits` héritent du filtre ACL de la requête —
  c'est ce qu'on veut, et ça implique que deux utilisateurs voient un nombre de
  copies différent pour le même document. Normal, à ne pas « corriger » ;
- comme ça change les comptes, c'est une **préférence utilisateur**
  (`stores/preferences.ts`) désactivée par défaut, pas un changement imposé.

**c. Réindexation** — aucun gain, contrairement à l'intuition : le skip actuel
est déjà total (§4, constat annexe). À ne pas mettre dans l'argumentaire.

### 4.3 Rétro-remplissage

Les documents déjà indexés n'ont pas de hachage : le rapport ne couvrira que les
nouveaux tant qu'on n'a pas rattrapé l'existant. Précédent :
`backfill_groups.py`. Ici, un `backfill_hashes.py` **relit les fichiers sans
appeler Tika** (I/O pur, pas d'extraction) — reprenable, simulation par défaut,
`--apply` pour écrire, et n'écrit que les documents dépourvus du champ.

**Effort : 3 j** (1,5 j ingestion + hachage, 1 j rapport admin, 0,5 j
rétro-remplissage), plus la réindexation ou le rattrapage sur l'existant.

---

## §6. Synonymes métier et résultats épinglés — **synonymes faits le 2026-08-12**

Livré : les trois analyseurs du champ `content`, `migrer_analyse()` +
`./manage.sh migrer-synonymes` pour les index existants, CRUD du
thésaurus (`/admin/synonyms`), essai d'une requête, panneau
« Thésaurus ». 8 tests contre un vrai Elasticsearch.

**Les résultats épinglés (§6.2) restent à faire** — le seul élément du
plan qui n'a pas été livré à ce jour.

**Quatre points éprouvés contre le moteur avant d'écrire le code**, dont
un dément ce que ce plan affirmait :

1. L'ordre des filtres est déterminant : synonymes AVANT le stemmer,
   sinon zéro résultat sans la moindre erreur.
2. `search_quote_analyzer` s'applique bien à `multi_match type: phrase` —
   c'est ce qui laisse la recherche entre guillemets littérale, **sans
   toucher à la construction de requête de `search_api.py`**. Le plan
   envisageait de documenter une bizarrerie ; le mapping l'évite.
3. ⚠️ **Le §6.1 avait tort** : un jeu de synonymes inexistant n'empêche
   ni la création, ni la fermeture, ni la réouverture d'un index. La
   précaution d'ordre qu'il imposait est inutile (ES 9.4.3).
4. En revanche, Elasticsearch **refuse de supprimer un jeu référencé par
   un index** (400). Retirer la dernière règle écrit donc un jeu vide,
   parfaitement accepté et équivalent à l'absence de synonymes. Trouvé
   par un test qui a échoué.



Deux fonctionnalités distinctes, réunies parce qu'elles répondent à la même
question — « pourquoi cette recherche ne donne rien alors que le document
existe » — et se pilotent depuis le même écran.

### 6.1 Synonymes

**Constat** — zéro synonyme dans tout le dépôt. Sur un corpus administratif,
c'est le levier de pertinence le plus fort : sigles internes, noms de code,
ancien et nouveau nom d'un service.

Voie retenue : l'**API `_synonyms` d'Elasticsearch** (jeu de synonymes stocké
dans un index système, pas un fichier sur disque — donc aucune reconstruction
d'image, et compatible avec la production isolée). Le jeu est référencé par un
filtre `synonym_graph` marqué `updateable: true`, utilisé **uniquement en
analyseur de recherche** : c'est ce qui permet de modifier le thésaurus sans
réindexer 4 M de documents.

```
analyzer: french_search = french + synonym_graph(synonyms_set: docsearch_fr, updateable: true)
champ content : analyzer "french" (indexation) + search_analyzer "french_search"
```

Trois pièges, dans l'ordre où ils se présentent :

1. ⚠️ **Un filtre `updateable: true` est refusé dans un analyseur
   d'indexation.** C'est une contrainte d'ES, et c'est aussi exactement ce
   qu'on veut : elle garantit qu'aucune modification du thésaurus n'exigera de
   réindexation.
2. ⚠️ **Ajouter un analyseur à un index existant impose `close` puis `open`.**
   Quelques secondes d'indisponibilité **par index de source**, sans
   réindexation. À scripter (`./manage.sh migrer-synonymes`), à passer dans une
   fenêtre d'exploitation — d'où le regroupement avec le chantier 4 dans le
   lot C.
3. ⚠️ **Créer le jeu de synonymes AVANT de migrer les index**, même vide : un
   index qui référence un jeu inexistant peut refuser de se rouvrir. À éprouver
   sur la VM de développement avant de toucher à la production, sur une copie
   d'index — c'est le seul point du plan qui peut rendre un index indisponible.

Comportement à documenter dans `SearchHelp.vue` : l'expansion s'applique aussi
à la recherche entre guillemets, alors que l'utilisateur y attend « aucune
tolérance ». La désactiver dans ce cas seul supposerait un champ dédié ; ça ne
vaut pas son prix, mais il faut le dire plutôt que de le laisser surprendre.

Administration : panneau « Thésaurus », une règle par ligne
(`DRH, direction des ressources humaines`), avec un bouton **« tester une
requête »** appuyé sur `_analyze` — sans lui, personne ne saura si une règle est
prise en compte. Les modifications passent par `/admin/*`, donc le journal
d'audit les capte déjà.

**Boucle avec le chantier 2** : sur le tableau des recherches sans résultat de
`stats.html`, un bouton « créer un synonyme » pré-rempli avec la requête ratée.
C'est ce qui transforme une mesure en correction.

### 6.2 Résultats épinglés

Registre Redis `docsearch:config:pinned` : requête normalisée (minuscules,
accents repliés, espaces réduits) → liste de `doc_id` ordonnée.

À la recherche, si `from_ == 0` et que la requête normalisée correspond : les
documents épinglés sont récupérés **à travers le même filtre ACL** que le reste
(jamais un `mget` direct), retirés de la liste naturelle pour éviter le doublon,
et affichés en tête **avec une mention visible** — « Proposé par votre
administration ». Un classement modifié en silence est une mauvaise surprise le
jour où quelqu'un s'en aperçoit.

⚠️ Un document épinglé puis supprimé de l'index doit disparaître du résultat, et
le panneau d'administration doit l'afficher comme introuvable — sinon on épingle
durablement un lien mort.

**Effort : 3 j synonymes (dont l'éprouvage de la migration) + 1,5 j épinglés.**

---

## §7. Permaliens de recherche — **fait le 2026-08-12**

Livré : `src/utils/permalien.ts` (sérialisation), `usePermalien` (lecture au
chargement et au retour arrière), écriture depuis `doSearch()`, bouton
« Copier le lien » dans la barre d'outils des résultats. 19 tests d'aller-retour
et de robustesse d'URL, 8 tests de store. Descendu dans [FEATURES.md](FEATURES.md).

**Constat** — aucun `pushState`/`replaceState` dans l'interface : l'état de
recherche ne va pas dans l'URL. Conséquences quotidiennes : impossible
d'envoyer une recherche à un collègue, le bouton Précédent quitte les
résultats, F5 perd tout.

### 7.1 L'URL porte les critères canoniques, pas le texte tapé

C'est la décision structurante. Sérialiser la sortie de `currentCriteria()`
(`stores/search.ts`) — `q`, `ext[]`, `author[]`, `keywords[]`, `folder[]`,
`source[]`, `custom`, `date_from`, `date_to`, `sort`, `page` — et **reconstruire
la barre de recherche à partir de là**. Sérialiser le texte brut ferait diverger
deux états déjà équivalents aujourd'hui : `auteur:Dupont` tapé à la main et la
même puce posée depuis une facette.

- `replaceState` pendant qu'on affine (facettes, tri) ;
- `pushState` sur une soumission et un changement de page ;
- écouteur `popstate` : ré-hydrate le store depuis l'URL et relance.

### 7.2 Points d'attention

- **Aller-retour par la page de connexion** : `client.ts:79` conserve déjà
  `pathname + search` dans le paramètre `suite`. Le permalien survit donc à la
  redirection — c'est un cas de test explicite : un lien partagé à quelqu'un de
  non connecté doit revenir sur la même recherche après authentification.
- **Le lien partage la recherche, pas les droits.** L'ACL refiltre pour le
  destinataire, qui verra peut-être moins de résultats. À écrire dans
  l'infobulle du bouton « Copier le lien », à côté du `CopyPathButtons.vue`
  existant.
- **Longueur d'URL** : beaucoup de valeurs de facettes cochées produisent des
  URL longues. Sans gravité côté navigateur ; si Nginx finit par répondre 414,
  le réglage est `large_client_header_buffers`, à noter dans le HOWTO plutôt
  qu'à anticiper.

### 7.3 Recette

Test d'aller-retour dans `stores/search.spec.ts` : critères → URL → critères,
identiques, y compris facettes multiples, facettes personnalisées SQL et dates.
C'est là que se logent les régressions.

**Effort : 1,5 à 2 j.** Meilleur rapport valeur/effort des sept.

---

## §8. Espace personnel

Trois briques indépendantes, par coût croissant.

### 8a. Historique de recherche personnel — **fait le 2026-08-12**

Livré : `GET /me/searches`, `HistoriquePanel.vue` (entrée « Mes recherches
récentes » à côté des recherches enregistrées), bascule
`search_history_enabled` désactivée par défaut. Les recherches sans texte
libre (filtres seuls) en sont écartées : le journal ne porte pas de quoi
les rejouer — il n'enregistre pas les facettes personnalisées des sources
SQL.


La donnée existe déjà : `search_logs` porte `username` en `keyword` et `query`
avec son sous-champ `.keyword` (pas de piège de type ici, contrairement à
l'index `suggestions`). Route `GET /me/searches` — `{"term": {"username": user}}`,
**jamais** un paramètre d'utilisateur dans la requête, dédoublonnage par texte
de requête, tri par occurrence la plus récente. Affichage dans le menu
utilisateur, à côté des recherches enregistrées, avec « relancer » et
« enregistrer cette recherche ». Alimente aussi le §1.

### 8b. Documents récemment consultés — 1,5 j

La donnée existe aussi : les clics sont déjà enregistrés en `nested`
(`doc_id`, `position`, `timestamp`) dans les documents de `search_logs`
(`POST /click`). Route `GET /me/recent-documents` : requête `nested` sur les
journaux de l'utilisateur, 20 derniers `doc_id` distincts, **puis relecture de
chaque document avec `_check_doc_access()`** — un document dont l'ACL a changé
depuis le clic ne doit plus apparaître, et un document supprimé de l'index doit
disparaître sans erreur. À placer dans `EmptySearchState.vue`, qui occupe
aujourd'hui un grand espace vide avant la première recherche.

### 8c. Collections partagées — 2 à 3 j

`saved_collections.py` est strictement personnel. Ajouter `shared_with`
(liste de groupes) et une visibilité `owner == user ||
shared_with ∩ get_effective_groups(user)` — en réutilisant `get_effective_groups`,
point unique de vérité, et non une seconde résolution de groupes.

⚠️ **Partager une collection partage la référence, pas le droit de lecture.**
Chaque document reste refiltré par l'ACL à l'affichage : deux personnes ouvrant
la même collection n'y voient pas forcément le même nombre de documents. Ne pas
masquer l'écart — afficher « 3 documents ne vous sont pas accessibles ». Sans
ce message, le propriétaire croit avoir partagé dix documents quand le
destinataire en voit sept, et personne ne s'en rend compte.

Écriture réservée au propriétaire (aucun verrouillage à écrire), plus un bouton
« dupliquer dans mes collections » qui couvre le reste des besoins. Bascule
`collections_shared_enabled`, à `false` par défaut.

---

## Ce que ce plan ne fait pas

- **Pas d'email** : arbitré, et l'arbitrage tient — un titre de document en
  clair dans une boîte aux lettres sort du périmètre ACL.
- **Pas de nouveau conteneur** : le seul travail de fond ajouté (§3) tient dans
  le tick d'`alert_worker.py`, qui tourne déjà.
- **Pas de nouvelle dépendance Python ni npm.** `hashlib`, les agrégations ES
  et l'API `_synonyms` suffisent aux sept chantiers.
- **Aucune modification de `search_query.py`** : les alertes continuent de voir
  exactement ce qu'une recherche manuelle verrait.
