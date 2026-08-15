# `docsearch_contract` — contrat partagé entre dépôts

**Source de vérité : ce dossier.** Les copies présentes dans les autres
dépôts sont générées par `./manage.sh sync-contract` et ne se modifient
jamais sur place.

Premier morceau du lot 0 de [PLAN-PLUGINS.md](../PLAN-PLUGINS.md).

## Ce qu'il contient, et ce qu'il ne contiendra jamais

Uniquement des règles **sans dépendance** : ni Redis, ni Elasticsearch, ni
FastAPI. Les entrées/sorties restent chez les consommateurs. C'est ce qui
permet de vendoriser ce paquet partout sans rien tirer derrière lui, de le
tester sans lancer un seul service, et de l'importer depuis un worker de fond
qui n'a pas à charger l'API pour savoir ce qu'une source est.

| Module | Rôle |
|---|---|
| `sources.py` | Vue générique des registres de sources : `SourceEntry`, `visible_to()`, `searchable_names()`, `collectable_names()`, `find()` |
| `plugins.py` | Déclaration d'une source portée par un module complémentaire : `PluginSource`, politiques d'ACL, `valider_declaration()` |
| `documents.py` | Enveloppe des messages poussés sur `documents-ready`, construction du document indexé, application de l'ACL |
| `manifeste.py` | Déclaration d'un module installable : image, capacités, secrets, bornes de ressources, sources déclarées |
| `erreurs.py` | `ContratInvalide`, seule exception du contrat |
| `version.py` | `CONTRACT_VERSION` — version sémantique du contrat |

## Pourquoi une copie plutôt qu'une dépendance installée

Trois raisons, dans l'ordre où elles éliminent les alternatives :

- le contexte de `podman build` est le dépôt consommateur : il ne peut pas
  atteindre `../docsearch-infra` au moment de la construction ;
- la production n'a pas d'accès Internet et pas de registre de paquets
  interne — une roue vendorisée serait un artefact binaire de plus à
  committer, pour le même résultat ;
- `podman build .` lancé à la main dans un dépôt consommateur doit continuer
  de produire une image qui fonctionne.

La copie est donc assumée. Ce qui change par rapport aux six copies de
`*_sources_config.py` tenues à la main, c'est qu'elle est **générée** et que
sa dérive est **détectée** : `./manage.sh build` refuse de construire tant
qu'une copie diverge.

## Faire évoluer le contrat

```bash
# 1. modifier la source ici, et ses tests
cd docsearch-infra/contract && python3 -m pytest tests/

# 2. répercuter dans les dépôts consommateurs
cd .. && ./manage.sh sync-contract

# 3. committer la copie DANS chaque dépôt consommateur, avec le code qui
#    l'utilise — la copie est versionnée avec son dépôt
```

Un changement non rétrocompatible incrémente la majeure de
`CONTRACT_VERSION`. Tant que le paquet est en `0.x`, la forme du contrat
n'est pas figée : elle ne le sera qu'une fois les lots 1 et 2 passés dessus.

## Ajouter un dépôt consommateur

Une seule ligne à ajouter à `CONTRACT_CIBLES` dans `manage.sh`, puis
`./manage.sh sync-contract`. La destination est `app/docsearch_contract`
et non `vendor/` : les modules Python de ces dépôts sont à plat dans
l'image (`COPY app/ .`), un paquet déposé là est importable sans toucher ni
au Dockerfile ni au `sys.path` des tests.

## Consommateurs actuels

| Dépôt | Ce qu'il en utilise |
|---|---|
| `docsearch-api` | `sources.py` — `search_api.py` et `search_query.py`, via `app/source_registries.py` ; `plugins.py` — `plugin_sources_config.py` |
| `docsearch-ingestion` | `plugins.py` et `documents.py` — `plugin_sources_config.py`, `plugin_worker.py`, `plugin_indexer.py` |
| `docsearch-infra` | `manifeste.py` — `./manage.sh plugin install`, qui valide **sans conteneur ni pile démarrée** : la source de vérité du contrat est ici même |

C'est le contrat qui rend `plugin_sources_config.py` supportable en deux
exemplaires : les règles — validation, politiques d'ACL, valeurs par
défaut — n'existent qu'ici, la copie ne porte plus que l'entrée/sortie
Redis. À comparer aux six copies de `*_sources_config.py` natives, qui
dupliquent aussi leurs règles.
