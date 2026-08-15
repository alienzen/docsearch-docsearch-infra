# Modules complémentaires (plugins) — plan d'implémentation

**Proposé le 2026-08-14, pas encore arbitré** — à la différence de
[PLAN-EVOLUTIONS.md](PLAN-EVOLUTIONS.md), rien de ce qui suit n'est décidé.
Écrit à partir d'une revue de l'existant : les trois registres de sources, les
workers d'ingestion, `search_api.py`, les unités Quadlet et les deux
`nginx.conf`.

Deux besoins ont été exprimés — **ajouter des sources de données** et **ajouter
des fonctionnalités**. Ce document soutient qu'ils ne relèvent pas du même
mécanisme, propose un contrat pour chacun, et dit où ça se branche, ce qui
casse si on s'y prend mal, et comment on vérifie.

Il complète [PLAN-EVOLUTIONS.md](PLAN-EVOLUTIONS.md), dont les cinq invariants
restent valables ici sans être recopiés.

---

## La décision de fond : un plugin est une image, pas un fichier

Le code est **copié dans les images** (`COPY app/ .` dans les trois
Dockerfile), les unités Quadlet sont statiques, et la production n'a pas
Internet ([HOWTO-deploiement-hors-ligne.md](HOWTO-deploiement-hors-ligne.md)).

Trois conséquences, dans l'ordre où elles éliminent des solutions :

1. **Un plugin ne peut pas être « déposé » dans un dossier et chargé à chaud.**
   Un système à base d'`importlib` / `entry_points` obligerait à reconstruire
   `docsearch/api` ou `docsearch/ingestion` à chaque plugin — soit un fork avec
   des étapes en plus.
2. **Les dépendances d'un plugin ne peuvent pas rejoindre celles du cœur.**
   `requirements.txt` est épinglé au correctif près dans les deux dépôts
   (`elasticsearch==9.4.1`, `fastapi==0.115.0`) : le premier plugin qui réclame
   une autre version de `httpx` casse l'API pour tout le monde.
3. **Le vecteur de déploiement est déjà `podman save` / `podman load`.** Une
   image de plugin s'y transfère exactement comme le reste
   ([quadlet/transfer-images.sh](quadlet/transfer-images.sh)), un fichier
   déposé à la main sur huit serveurs isolés, non.

**Donc : un plugin = une image OCI + un manifeste + une unité Quadlet.** C'est
déjà le modèle de fait du dépôt — `docsearch-web-crawler-cc-decisions.container`
est un composant tiers, dans son image, avec son unité, qui alimente DocSearch
par un index intermédiaire. Le système de plugins ne fait que généraliser et
documenter ce précédent.

## Les invariants propres aux plugins

Ils s'ajoutent aux cinq de [PLAN-EVOLUTIONS.md](PLAN-EVOLUTIONS.md).

1. **Un plugin n'écrit jamais dans Elasticsearch et n'y lit jamais
   directement.** Il n'a ni l'URL du cluster, ni de compte. Toute écriture
   passe par le worker d'ingestion du cœur (§1), toute lecture par l'API du
   cœur avec le jeton de l'utilisateur (§2). C'est ce qui rend
   [`build_acl_filter()`](../docsearch-api/app/search_api.py:262) inévitable
   plutôt que recommandé.
2. **Un plugin ne choisit ni son index, ni son ACL.** Les deux sont déclarés
   par l'administrateur à l'enregistrement. Un plugin qui pourrait poser
   `acl.public: true` sur ses documents pourrait publier n'importe quoi à tout
   le monde.
3. **Un plugin ne parle jamais à l'annuaire.** L'identité lui vient du jeton de
   session, vérifié contre le JWKS déjà publié
   ([`/auth/.well-known/jwks.json`](../docsearch-api/app/auth/router.py:626)).
   Aucune seconde connexion LDAP, jamais — même règle que dans `charlie`.
4. **Un plugin désactivé ne détruit rien.** `disable` retire la source de la
   recherche et masque l'entrée d'interface ; les index et les données restent.
   Même comportement que `searchable` aujourd'hui.
5. **Tout ce qui s'installe ou se bascule s'inscrit dans le journal d'audit.**
   Gratuit si les routes vivent sous `/admin/` : le middleware de
   [audit_log.py](../docsearch-api/app/audit_log.py) est générique.

---

## Constat : ce que coûte un type de source aujourd'hui

Avant de discuter du contrat, il faut mesurer ce qu'un « type de source
supplémentaire » coûte réellement dans l'état actuel du code.

| Ce qu'il faut écrire | Où | Précédent |
|---|---|---|
| Un module de registre Redis | **deux fois** (api + ingestion) | `*_sources_config.py` existe en **6 exemplaires**, en-têtes marqués « COPIE SYNCHRONISÉE » |
| Un ordonnanceur | `docsearch-ingestion` | [sql_worker.py](../docsearch-ingestion/app/sql_worker.py) et [web_worker.py](../docsearch-ingestion/app/web_worker.py) sont le **même** fichier à deux imports près |
| Un indexeur (mapping, alias, réconciliation) | `docsearch-ingestion` | `put_alias(ES_SEARCH_ALIAS)` est écrit **trois fois** ([indexer.py:479](../docsearch-ingestion/app/indexer.py:479), [sql_indexer.py:253](../docsearch-ingestion/app/sql_indexer.py:253), [web_indexer.py:133](../docsearch-ingestion/app/web_indexer.py:133)) |
| ~10 routes d'administration | `search_api.py` | 3 940 lignes, décorateurs `@app.` — seul `auth_router` est un `APIRouter` |
| Une énumération de plus dans `_searchable_source_names()` | `search_api.py` | trois boucles identiques, [ligne 426](../docsearch-api/app/search_api.py:426) |
| Un panneau Vue | `docsearch-ui-vue` | `AdminFileSourcesPanel` / `AdminSqlSourcesPanel` / `AdminWebSourcesPanel` |
| 4 à 6 commandes `manage.sh` | `docsearch-infra` | `add-*`, `list-*`, `remove-*`, `run-*` |
| Une unité Quadlet | `docsearch-infra` | une par worker, une par crawler |

**Un système de plugins posé par-dessus cette duplication la multiplie par le
nombre de plugins.** D'où le §0, qui n'apporte rien de visible et sans lequel
rien ne tient.

⚠️ **La divergence est déjà là et se paie déjà.** L'ACL par document n'a pas le
même modèle selon le type de source : les sources fichiers l'extraient du
système de fichiers (`acl_extractor.py`), les sources web portent un booléen
`acl_public` de registre ([web_indexer.py:206](../docsearch-ingestion/app/web_indexer.py:206)),
et les sources SQL n'ont **rien de prévu** — l'administrateur doit penser à
mapper une colonne vers le champ `acl.public`, ce qui produit une clé *plate*
que [`_doc_acl()`](../docsearch-api/app/search_api.py:2043) doit renormaliser
côté lecture. S'il n'y pense pas, les documents sont invisibles pour tout le
monde (heureusement : `build_acl_filter` est *fail-closed*, aucune clause
`should` ne matche un document sans `acl`). Un quatrième modèle d'ACL improvisé
par plugin est exactement ce qu'il ne faut pas laisser arriver.

---

## §0. Le socle — registre générique et paquet de contrat

Deux préalables, sans valeur d'usage propre, et incontournables.

> **Entamé le 2026-08-15 — chemin de LECTURE livré, écriture et migration
> restant à faire.**
>
> Livré : `contract/docsearch_contract/` (source de vérité) avec
> `sources.py` — `SourceEntry`, `visible_to()`, `searchable_names()`,
> `collectable_names()`, `find()` —, `./manage.sh sync-contract [--check]`
> et son contrôle de dérive avant chaque `build`, la copie dans
> `docsearch-api/app/docsearch_contract/`, et `app/source_registries.py`
> qui lie les trois registres à cette vue. 10 tests dans `contract/`
> (aucun service requis), 4 dans `docsearch-api`.
>
> Six énumérations des trois registres ont disparu de `docsearch-api` —
> quatre dans `search_api.py`, deux dans `search_query.py`, dont la copie
> de `_visible_to()` marquée « Identique à… ». `search_api` et
> `search_query` répondent désormais *par construction* la même chose à
> « quelles sources cet utilisateur peut-il atteindre », et un test le
> verrouille.
>
> **Écart avec le plan, mesuré plutôt que supposé** : le paquet est
> **vendorisé en source**, pas construit en roue. Le contexte de
> `podman build` est le dépôt consommateur — il ne peut pas atteindre
> `../docsearch-infra` — et il n'existe pas de registre de paquets interne
> en production. Une roue aurait ajouté un artefact binaire à committer
> pour le même résultat. Ce qui compte n'était pas la forme du paquet mais
> que la copie soit *générée* et sa dérive *détectée* : c'est le cas.
>
> Reste à faire pour clore le lot : la clé Redis unique et le chemin
> d'ÉCRITURE (les trois registres gardent leurs clés et leurs fonctions de
> mutation), la migration ci-dessous, et la vendorisation vers
> `docsearch-ingestion` — inutile tant que le lot 1 n'existe pas.

### 0.1 Un registre de sources générique

Un seul module, une seule clé Redis, une entrée typée :

```json
"clients": {
  "type": "sql",
  "label": "Clients", "description": "", "searchable": true,
  "collectable": true, "allowed_groups": [],
  "es_index": "clients_sql",
  "config": { "…": "poche opaque, propre au type" }
}
```

Les champs communs (`label`, `searchable`, `collectable`, `allowed_groups`,
`description`, `es_index`) remontent au niveau générique ; tout le reste
descend dans `config`. Un type de plugin s'écrit alors `"type": "plugin:jira"`,
sans nouvelle clé Redis ni nouveau module.

Ce que ça débloque immédiatement, avant même le premier plugin :
[`_searchable_source_names()`](../docsearch-api/app/search_api.py:426) et
`_get_any_source()` cessent d'énumérer trois registres en dur. **C'est le point
qui compte pour la sécurité** : l'invariant « rien ne contourne l'ACL » tient
parce qu'il existe un seul endroit qui décide ce qu'un utilisateur peut
atteindre, pas quatre — et bientôt pas *N*.

⚠️ **Migration.** Les trois clés Redis existantes
(`docsearch:config:file_sources`, `:sql_sources`, `:web_sources`) sont peuplées
sur les installations en service. Prévoir une bascule à la lecture (si la
nouvelle clé est absente, lire et convertir les trois anciennes) et une
commande `./manage.sh migrer-registre-sources --apply`, sur le modèle de
`migrer-synonymes` / `migrer-exact` déjà présentes dans `manage.sh`. Ne pas
supprimer les anciennes clés dans la même version.

### 0.2 Un paquet de contrat versionné

Le schéma de document, le schéma de manifeste et leurs validateurs vivent dans
un petit paquet Python — `docsearch-contract` — construit en roue et vendorisé
dans les deux images.

Sans lui, le contrat de plugin devient la **7ᵉ copie synchronisée à la main**,
et cette fois avec des tiers qui en dépendent. Il porte un numéro de version
sémantique : c'est ce numéro qu'un manifeste déclare, et le seul moyen de
refuser proprement un plugin trop ancien.

⚠️ Une roue de plus à vendoriser pour le déploiement hors ligne. C'est un coût
réel, à assumer explicitement : il est très inférieur à celui d'un contrat
recopié dans deux dépôts et divergeant en silence, ce que le dépôt a déjà vécu
six fois.

**Effort : 5 à 8 j.**

---

## §1. Sources de données — connecteur hors processus

> **Fait le 2026-08-15.**
>
> Livré : le topic `documents-ready` (auto-créé par Kafka, comme
> `documents-to-index`), `plugin_worker.py` et `plugin_indexer.py` côté
> `docsearch-ingestion`, le registre `plugin_sources_config.py` dans les
> deux dépôts, `plugins.py` et `documents.py` dans le contrat (version
> 0.2.0), le type `plugin` branché dans `source_registries.REGISTRES`,
> `./manage.sh add|list|remove-plugin-source`, et l'unité
> `docsearch-plugin-worker.container` (dev + rôle `ingest`, avec les
> singletons).
>
> 26 tests de contrat (aucun service) et 23 dans `docsearch-ingestion`
> contre un vrai Elasticsearch — dépôt qui n'avait **aucun test** avant
> ce lot, et dont la CI ne faisait que `ruff` et `docker build`.
>
> **Écart avec le plan** : le registre est une QUATRIÈME clé Redis
> (`docsearch:config:plugin_sources`), pas l'entrée typée d'une clé
> unique — le chemin d'écriture générique du §0 n'est pas fait. Le
> surcoût est nul là où ça comptait : le type `plugin` s'est branché
> dans la vue générique en une ligne, ce qui était exactement la promesse
> du lot 0. La consolidation des clés reste une hygiène à faire, pas un
> préalable.
>
> **Reste hors périmètre, et le demeure tant qu'aucun module n'existe** :
> les routes `/admin/plugin-sources` et leur panneau (les sources se
> déclarent par `manage.sh`, comme les sources SQL et web l'ont d'abord
> fait), et la passerelle HTTP → Kafka pour les auteurs de modules sans
> client Kafka.

**Le plugin ne parle jamais à Elasticsearch. Il publie des documents déjà
extraits sur un topic Kafka, et un worker générique du cœur écrit.**

```
plugin (image tierce, son unité, son propre rythme)
   └─→ Kafka  documents-ready       (documents au schéma DocSearch)
          └─→ docsearch-ingest-worker  (cœur)
                 ├─ valide le schéma et le nom de source contre le registre
                 ├─ impose l'ACL selon la politique déclarée par l'ADMIN
                 ├─ crée l'index avec le mapping du cœur, rejoint docsearch-all
                 └─ es.index(...)
```

### 1.1 Pourquoi Kafka plutôt qu'un endpoint HTTP d'ingestion

Le bus est déjà là, dimensionné (`KAFKA_NUM_PARTITIONS=16`), avec ses unités et
sa supervision. Il donne le tampon, la reprise après panne et la contre-pression
gratuitement — un plugin qui déverse 200 000 lignes ne fait pas tomber
l'indexation des autres. Et il évite de poser un chemin d'écriture dans l'API de
lecture, qui n'en a aujourd'hui aucun.

Le topic est **nouveau** : `documents-to-index`
([producer.py:26](../docsearch-ingestion/app/producer.py:26)) transporte des
*références de fichiers* à extraire par Tika, pas des documents finis. Les deux
ne se mélangent pas.

Une passerelle HTTP → Kafka pourra s'ajouter plus tard si des auteurs de
plugins n'ont pas de client Kafka utilisable ; elle ne change pas le contrat.

### 1.2 Le contrat de message

Trois types de messages, tous portant `source`, `plugin`, `contract_version` et
`run_id` :

| Type | Charge | Effet |
|---|---|---|
| `document` | le document au schéma DocSearch | indexé |
| `delete` | un `doc_id` | supprimé |
| `run_end` | rien | déclenche la réconciliation de la passe |

Le schéma de document reprend les champs communs déjà produits par les trois
chemins existants (`filename`, `filepath`, `title`, `content`, `author`,
`keywords`, `date_created`, `date_modified`, `size`, `source`, `indexed_at`),
plus une poche de champs supplémentaires déclarés par le plugin dans son
manifeste — mappés comme les colonnes d'une source SQL, avec les mêmes types
autorisés et le même contrôle de facette.

### 1.3 Les quatre points qui font la différence

1. **L'index et l'ACL n'appartiennent pas au plugin** (invariant 2). Le message
   annonce `source: "<nom>"` ; le worker **refuse** si ce nom n'est pas dans le
   registre, ou s'il n'est pas de type `plugin:<le plugin qui pousse>`, et
   déduit `es_index` du registre. La politique d'ACL est déclarée à
   l'enregistrement, en trois valeurs et pas une de plus :

   | Politique | Effet |
   |---|---|
   | `public` | `acl.public = true` sur tous les documents de la source |
   | `groupes` | `acl.groups = [...]` fixés par l'administrateur |
   | `fournie` | le plugin fournit `acl.users`/`acl.groups`, **validés contre une liste blanche** ; `acl.public` est ignoré, toujours |

   Écrire la troisième ligne dans le code, pas seulement ici : `acl.public`
   proposé par un plugin est le seul champ dont l'acceptation naïve ouvre tout
   le corpus.

2. **Le cœur seul crée l'index.** `create_index()` porte les analyseurs
   (`french`, `exact`), les sous-champs de recherche exacte, `dynamic: strict`
   et le `put_alias` vers `docsearch-all`. Un plugin qui écrirait directement
   reproduirait le bug déjà documenté dans [README.md](README.md) : index
   auto-créé en mapping dynamique, sans alias, invisible à la recherche
   fédérée, **sans aucune erreur visible**.

3. **La suppression est dans le contrat dès le départ.** `sql_indexer` et
   `web_indexer` réconcilient par diff d'identifiants, avec un garde-fou qui
   refuse de supprimer plus de la moitié d'un index. Le contrat plugin reprend
   les deux : chaque passe porte un `run_id`, le message `run_end` purge les
   documents de cette source dont le `run_id` est antérieur, et le garde-fou
   s'applique à l'identique. Sans ça, aucun plugin ne sait supprimer, et
   personne ne s'en aperçoit avant des mois.

4. **Pas de nouvel ordonnanceur.** Le plugin tourne en continu et gère son
   rythme lui-même, comme le crawler web. Le registre ne déclare que ce qu'on
   fait de ce qu'il pousse. Un `poll_interval` piloté par le cœur supposerait un
   canal de commande vers le plugin : c'est une deuxième moitié de protocole
   pour un gain nul.

### 1.4 Recette

`pytest` contre un vrai Elasticsearch, dans `docsearch-ingestion` :

- un message annonçant une source **non enregistrée** n'écrit rien ;
- un message annonçant la source d'un **autre** plugin n'écrit rien ;
- `acl.public: true` poussé par un plugin en politique `groupes` **n'est pas**
  retenu — le test qui compte vraiment ;
- une passe complète puis une passe amputée d'un document supprime ce document,
  et une passe amputée de **60 %** des documents ne supprime rien (garde-fou) ;
- un champ absent du manifeste fait échouer l'indexation du document
  (`dynamic: strict`) au lieu d'être inventé par ES.

Côté `docsearch-api`, un test d'accès : un document de source plugin non
visible par `bob.user` n'apparaît ni dans `/search`, ni dans `/search/suggest`,
ni via `/document/{id}`.

**Effort : 4 à 6 j.**

---

## §2. Fonctionnalités — service dorsal sous `/ext/`

> **Plomberie faite le 2026-08-15 (lot 3) ; le module de démonstration
> reste à écrire.**
>
> Livré : capacité `service_web` et clé `port` du manifeste (contrat
> 0.4.0), `jetons.py` — ce qu'un module doit vérifier d'une session —,
> l'écriture d'un fragment nginx par module à l'installation et son
> rechargement, le montage du répertoire de fragments dans les deux
> conteneurs nginx, `include /etc/nginx/plugins/*.conf` dans les DEUX
> `nginx.conf`, et `ext/` dans `API_ROUTES` de `vite.config.ts`. 16 tests
> de plus (87 dans `contract/`).
>
> Choix de conception : un fragment **généré par module** plutôt qu'un
> `location` générique à variable. Un `proxy_pass` contenant une variable
> oblige nginx à résoudre le nom à chaque requête, donc à connaître un
> `resolver` — l'adresse du DNS de podman, qui change avec le réseau. Un
> fragment statique ne dépend de rien et se relit en clair pour
> diagnostiquer.
>
> **Ce qui manque, et ce document le réclame explicitement** (« le lot 3
> doit livrer un vrai plugin, pas un squelette ») : l'assistant du §2.2
> lui-même, et le branchement de `ChatPage.vue` dessus. Tant qu'aucun
> module n'a emprunté ce chemin de bout en bout, le contrat de jeton et le
> retrait du préfixe `/ext/<nom>/` sont écrits, pas éprouvés.
>
> ⚠️ `include` a été ajouté dans `docsearch-ui-vue/nginx.conf`, qui est
> **copié dans l'image** : le routage `/ext/` n'existe qu'après un
> `./manage.sh build ui` et un redémarrage. Les fragments, eux, sont
> montés depuis l'hôte et prennent effet à chaud.

Le plugin expose son propre service HTTP dans son conteneur ; Nginx route
`/ext/<nom>/` vers lui.

### 2.1 Identité et accès aux données

Le plugin **valide lui-même la session** contre le JWKS publié par l'API
([`/auth/.well-known/jwks.json`](../docsearch-api/app/auth/router.py:626)) : il
connaît donc l'utilisateur sans toucher à l'annuaire ni au magasin de sessions
(invariant 3). Pour lire des documents, il rappelle l'API du cœur **en portant
le jeton de l'utilisateur** : l'ACL s'applique sans qu'il ait à la connaître ni
à pouvoir s'en écarter (invariant 1).

C'est le niveau qui donne le plus de liberté pour le moins de risque : le
plugin peut être écrit dans n'importe quel langage, ses dépendances vivent chez
lui, et le pire qu'il puisse faire est de mal répondre.

### 2.2 Le premier plugin est déjà identifié

**L'assistant RAG.** `chat.html` et `ChatPage.vue` existent, Nginx route déjà
`/ask` vers l'API — et l'API n'a aucune route `/ask` : la page répond
aujourd'hui avec des réponses en dur
([cannedResponses.ts](../docsearch-ui-vue/src/pages/chat/cannedResponses.ts)).
C'est le §5 de [PLAN-EVOLUTIONS.md](PLAN-EVOLUTIONS.md), en attente d'un
arbitrage matériel.

Le faire en plugin résout l'arbitrage au lieu de l'attendre : le service
d'inférence vit dans **son** image, avec **son** GPU et **ses** dépendances, sur
la machine qui les a. Le cœur n'embarque rien. Si le matériel n'arrive jamais,
le plugin n'est simplement pas installé.

⚠️ C'est aussi le meilleur banc d'essai du contrat : `/ask` doit citer ses
sources, donc relire des documents **au nom de l'utilisateur** — exactement le
cas que §2.1 doit rendre impossible à rater.

### 2.3 Le détail qui coûte une demi-journée si on l'oublie

Le préfixe `/ext/` doit être déclaré à **trois** endroits qui doivent rester
miroirs, et qui ne se surveillent pas mutuellement :

- [nginx/nginx.conf](nginx/nginx.conf) (proxy de la pile) ;
- [docsearch-ui-vue/nginx.conf](../docsearch-ui-vue/nginx.conf) (proxy servi
  avec l'interface) ;
- `API_ROUTES` dans [vite.config.ts](../docsearch-ui-vue/vite.config.ts) (le
  serveur de développement).

Un chemin ajouté ici sans l'être là est *la* source des bugs « fonctionne en
dev, 404 dans le conteneur », et le fichier `vite.config.ts` le dit lui-même.
Corollaire déjà connu du dépôt : **aucun fichier de `public/` ne peut
désormais commencer par `ext`**.

Choisir `/ext/` une fois pour toutes et ne plus jamais y toucher : chaque
plugin est un segment *sous* ce préfixe, jamais un préfixe de premier niveau.

**Effort : 3 à 5 j** (routage, contrat de jeton, plugin de démonstration bout
en bout).

---

## §3. Interface — points d'accroche déclaratifs

Le plugin ne livre **pas** de JavaScript dans le bundle de l'interface. Son
manifeste déclare des points d'accroche dans un vocabulaire fixe, que le cœur
rend avec ses propres composants DSFR :

| Accroche | Rendu par le cœur |
|---|---|
| `nav` | une entrée de menu (`NavMenuItem`), soumise à sa bascule |
| `result_action` | un bouton sur la carte de résultat, qui appelle `/ext/<nom>/...` |
| `admin_panel` | un panneau d'administration décrit en champs (booléen, texte, liste) |
| `page` | une page entière, servie en `iframe` sous `/ext/<nom>/` |

Deux raisons de ne pas ouvrir plus, et elles ne sont pas négociables :

- Sur un service de l'État, du JS tiers injecté dans la page de recherche fait
  porter au cœur la **conformité RGAA** de code qu'il n'écrit pas.
- Une XSS dans cette page vaut **contournement d'ACL côté navigateur** : la
  session y est, et l'API répond à qui la porte.

Chaque plugin porte sa bascule dans `ui_config`, déclarée aux **trois** endroits
habituels ([ui_config.py](../docsearch-api/app/ui_config.py) :
`DEFAULT_UI_CONFIG`, le modèle `UiConfigUpdate`, la chaîne `set_param`) plus le
repli de [stores/uiConfig.ts](../docsearch-ui-vue/src/stores/uiConfig.ts), et
démarre à `false` — elle **ajoute** un élément à l'écran (invariant 3 de
PLAN-EVOLUTIONS).

⚠️ Une bascule par plugin veut dire une clé `ui_config` créée dynamiquement,
alors que `set_param()` refuse aujourd'hui toute clé absente de
`DEFAULT_UI_CONFIG` — à dessein. Ne pas relâcher ce contrôle : réserver un
espace de noms `plugin.<nom>.enabled` validé contre le registre des plugins
installés, ce qui garde la propriété utile (une clé inconnue est refusée) sans
ouvrir la porte à n'importe quelle chaîne.

**Effort : 5 à 8 j.**

---

## §4. Ce qu'on n'ouvre pas

**Des routeurs Python chargés dans l'API, et des composants Vue tiers dans le
bundle.** Ce serait le modèle le plus puissant, et c'est celui à refuser :

- il suppose de découper `search_api.py` (3 940 lignes, décorateurs `@app.`) en
  `APIRouter`, puis d'exposer une façade Elasticsearch qui force
  `build_acl_filter` — un chantier en soi, et un invariant de sécurité de plus
  à tenir à chaque revue ;
- il rend les dépendances du plugin solidaires de celles du cœur (voir la
  décision de fond, point 2) ;
- et **malgré tout ça, l'image devrait être reconstruite pour chaque plugin**.
  Le gain par rapport à une simple branche est nul, le risque est entier.

Si le besoin revient, il faudra l'entendre comme « le contrat de §1/§2 est trop
étroit » et élargir le contrat — pas ouvrir le processus.

---

## §5. Cycle de vie, distribution, secrets

> **Fait le 2026-08-15** (lot 2).
>
> Livré : `manifeste.py` dans le contrat (version 0.3.0),
> `quadlet/plugin.container.in`, `./manage.sh plugin
> install|list|enable|disable|remove`, la validation du modèle d'unité par
> `valider-unites.sh`, et
> [HOWTO-creer-module-complementaire.md](HOWTO-creer-module-complementaire.md).
> 22 tests de manifeste supplémentaires (71 en tout dans `contract/`).
>
> **Deux écarts avec ce qui suit, tous deux dans le sens de la
> prudence :**
>
> 1. **Pas d'`EnvironmentFile=/etc/docsearch/docsearch.env` dans l'unité
>    générée**, contrairement à toutes les autres unités de la pile. Ce
>    fichier porte le mot de passe de liaison LDAP, les DSN des bases SQL
>    et la clé qui les chiffre : le donner à du code tiers réglait la
>    question de l'accès à Kafka en ouvrant tout le reste. Le module reçoit
>    `KAFKA_BOOTSTRAP`, `DOCSEARCH_TOPIC` et `DOCSEARCH_PLUGIN`, substitués
>    à l'installation, et ses propres secrets par `podman secret`.
> 2. **`capacites` n'accepte que `ingestion`.** `service_web` (§2) n'est
>    pas routée : l'accepter installerait un module à moitié servi. Elle
>    s'ajoutera avec le lot 3.
>
> ⚠️ **Limite connue, et elle n'est pas mineure.** Le conteneur d'un
> module est sur `docsearch-net`, où Elasticsearch et Redis répondent
> **sans authentification** (`xpack.security.enabled=false`). L'invariant 1
> — « un plugin n'écrit jamais dans Elasticsearch » — est donc tenu par le
> contrat, pas par le réseau : rien n'empêche techniquement un module
> d'écrire directement dans un index. La correction est un réseau dédié
> aux modules, avec le seul broker Kafka rattaché aux deux ; elle touche à
> l'unité Kafka et à ses listeners annoncés, donc elle demande sa propre
> fenêtre d'exploitation et une validation sur pile démarrée — c'est
> pourquoi elle n'a pas été faite au passage. **Jusque-là, n'installer que
> des modules dont on maîtrise le code.**

Une commande, alignée sur l'outillage existant :

```bash
sudo ./manage.sh plugin install /chemin/mon-plugin.tar
sudo ./manage.sh plugin list
sudo ./manage.sh plugin enable|disable <nom>
sudo ./manage.sh plugin remove <nom>
```

`install` fait : `podman load` de l'image, validation du manifeste (version de
contrat compatible, capacités demandées, nom de source libre), génération de
l'unité `.container` depuis un gabarit, enregistrement dans le registre,
`systemctl daemon-reload`.

- **Génération d'unité, pas d'unité template systemd.** La production vise
  podman 4.9, dont le support des templates par Quadlet est incertain — le
  dépôt a déjà tranché ce point pour les workers. Reprendre le mécanisme de
  [docsearch-worker.container.in](quadlet/dev/docsearch-worker.container.in) et
  du `sed` de [install-units.sh:131](quadlet/install-units.sh:131).
- **Image épinglée par version, jamais `:latest`** pour les images de plugins
  tierces — c'est la règle de HOWTO-deploiement-hors-ligne.md, et elle vise
  précisément ce cas.
- **Secrets par `podman secret`**, jamais dans le manifeste ni dans le
  registre. Le manifeste déclare le *nom* du secret attendu, comme
  `sql_sources_config` déclare le nom d'une variable d'environnement plutôt
  qu'un DSN.
- **Ressources bornées** : `PodmanArgs=--cpus=... --memory=...` dans le
  gabarit, comme les workers. Un plugin tiers qui part en boucle ne doit pas
  emporter la machine.
- **`disable` ne détruit rien** (invariant 4) : il arrête l'unité, passe la
  source à `searchable: false` et éteint la bascule d'interface. `remove`
  demande une confirmation explicite pour les index.

---

## Séquencement et effort

| Lot | Contenu | Effort |
|---|---|---|
| **0** | Registre générique + migration + paquet `docsearch-contract` | 5–8 j |
| **1** | Topic `documents-ready`, worker d'ingestion générique, `run_id`, politiques d'ACL | 4–6 j |
| **2** | `manage.sh plugin *`, gabarit d'unité, validation du manifeste | 3–4 j |
| **3** | Routage `/ext/`, contrat de jeton, **assistant RAG en plugin de démonstration** | 3–5 j |
| **4** | Points d'accroche d'interface déclaratifs | 5–8 j |

**Charge totale : 20 à 31 j-homme**, hors recette.

Les lots 0 à 2 se tiennent : livrés seuls, ils donnent les sources de données
en plugin, ce qui est le besoin le mieux défini. Les lots 3 et 4 se décident
ensuite, au vu de ce que le premier plugin de fonctionnalité aura appris.

⚠️ **Le lot 3 doit livrer un vrai plugin, pas un squelette.** C'est le seul
moyen de savoir si le contrat tient — et l'assistant RAG, qui doit citer des
documents au nom de son utilisateur, exerce précisément la partie du contrat
qu'on ne peut pas se permettre de rater.

## Le conseil qui précède tout le reste

Avant d'écrire le lot 0 : **lister les trois à cinq fonctionnalités réellement
visées**. Beaucoup de ce qu'on appelle « plugin de fonctionnalité » se révèle
être une bascule `ui_config` et un panneau d'administration — moins cher à
écrire nativement que le cadre censé l'accueillir. Le système de plugins se
justifie par le nombre de choses qu'il portera et par le fait qu'elles viennent
de **l'extérieur de l'équipe** ; s'il n'en porte que deux, écrites ici, il aura
coûté trois semaines pour rien.
