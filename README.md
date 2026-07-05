# docsearch-infra

Orchestration Docker Compose de **DocSearch** — c'est le dépôt à cloner en
premier et celui qui lance l'ensemble du système.

## Architecture multi-dépôts

DocSearch est découpé en 5 dépôts indépendants :

| Dépôt | Rôle | Cycle de vie |
|---|---|---|
| [docsearch-ingestion](../docsearch-ingestion) | Extraction, ACL, indexation | Évolue avec les formats de documents |
| [docsearch-api](../docsearch-api) | API de recherche (FastAPI) | Évolue avec les besoins de recherche |
| [docsearch-ui](../docsearch-ui) | Interface web statique | Évolue avec l'UX |
| **docsearch-infra** (ce dépôt) | Orchestration, déploiement | Évolue rarement |
| [docsearch-docs](../docsearch-docs) | Documents commerciaux | Géré par les équipes commerciales |
| [docsearch-dataset-generator](../docsearch-dataset-generator) | Génération de jeux de test | Utilisé ponctuellement, hors production |

**Convention de clonage** — tous les dépôts doivent être clonés côte à côte
dans un même dossier parent, car `docker-compose.yml` référence les autres
projets par chemin relatif (`../docsearch-ingestion`, `../docsearch-api`,
`../docsearch-ui`) :

```
docsearch/
├── docsearch-infra/       ← vous êtes ici, lancez manage.sh depuis ce dossier
├── docsearch-ingestion/
├── docsearch-api/
├── docsearch-ui/
└── docsearch-docs/
```

```bash
mkdir docsearch && cd docsearch
git clone <url>/docsearch-infra.git
git clone <url>/docsearch-ingestion.git
git clone <url>/docsearch-api.git
git clone <url>/docsearch-ui.git
git clone <url>/docsearch-docs.git

cd docsearch-infra
cp .env.example .env
nano .env                    # adapter DOCS_PATH, DOCKER_UID, LDAP...
chmod +x manage.sh

./manage.sh start            # démarre tout (mode dev)
./manage.sh init             # publie les fichiers sur Kafka (voir note ci-dessous)
```

> ⚠️ **`init` ne fait qu'écrire sur Kafka** — l'indexation réelle est
> faite en arrière-plan par les réplicas du service `worker`, qui
> doivent déjà tourner (démarrés par `start`/`start-prod`). Si `init`
> est lancé alors qu'aucun worker n'est actif (stack jamais démarré,
> ou arrêté depuis un `stop`/`reset`), l'index est créé mais reste
> vide, sans erreur visible — `manage.sh` vérifie maintenant ce cas
> et refuse de continuer si Kafka ou les workers ne sont pas détectés.
> Suivre la progression avec `./manage.sh logs worker` et
> `curl http://localhost:9200/documents/_count?pretty`.


## Pourquoi ce découpage

- **Tokens/contexte réduits** — travailler sur l'indexation n'a plus besoin
  de charger le code de l'API ni de l'UI dans le contexte de conversation
- **Cycles de déploiement indépendants** — reconstruire l'API ne nécessite
  pas de rebuild de l'ingestion (et inversement)
- **Séparation des responsabilités** — l'API ne dépend d'aucun autre dépôt
  (elle lit uniquement un ES déjà peuplé) ; l'ingestion ne dépend pas de
  l'API

## Commandes

```bash
./manage.sh start           # Mode dev : ES single-node, 1 worker
./manage.sh start-prod      # Mode prod : cluster ES 3 nœuds + Nginx
./manage.sh stop
./manage.sh status
./manage.sh logs <service>  # ex: api, worker, watcher, es01-dev
./manage.sh init            # Indexation initiale (dossier complet)
./manage.sh init finance    # Réindexer uniquement /documents/finance
./manage.sh scale-workers N
./manage.sh backup
./manage.sh reset           # ⚠️ supprime toutes les données
```

## Rebuild après modification d'un sous-projet

```bash
# Après une modification dans docsearch-ingestion :
docker compose build worker watcher indexer-init
docker compose up -d worker watcher

# Après une modification dans docsearch-api :
docker compose build api
docker compose up -d api

# Après une modification dans docsearch-ui :
docker compose build ui
docker compose up -d ui
```

## Nom de l'index Elasticsearch

`ES_INDEX` (défaut `documents`) doit être **identique** entre tous les
services — `docsearch-ingestion` (qui écrit) et `docsearch-api` (qui
lit) doivent pointer vers le même index, sinon l'API renverra
silencieusement zéro résultat alors que l'indexation semble fonctionner.
Ce fichier `docker-compose.yml` propage `ES_INDEX` à tous les services
via `x-app-env` — il suffit de le définir une seule fois dans `.env`.

```bash
# .env
ES_INDEX=documents_prod
```

⚠️ Changer cette valeur sur un environnement déjà en production ne
migre pas les données : le nouvel index démarre vide. Prévoir une
réindexation complète (`./manage.sh init`) après tout changement.

## Stack technique

Elasticsearch 9.4.3 · Apache Tika 3.3.1.0 · Kafka 8.3 (KRaft, sans
Zookeeper) · Redis 7.2 · Nginx 1.27 · Python 3.12.

Voir `guide_install_virtualbox.docx` dans `docsearch-docs` pour une
installation pas à pas sur VM VirtualBox.
