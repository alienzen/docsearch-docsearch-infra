# DocSearch — Déploiement multi-machines (8 serveurs)

Découpage du `docker-compose.yml` mono-hôte en un fichier par rôle, pour
une répartition sur 8 machines physiques (6× i3-12100T/16 Go/SSD 256 Go,
2× i3-12100T/16 Go/SSD 4 To). Voir le document d'architecture
(`docsearch-docs`) pour le détail du raisonnement et la procédure
d'installation Debian complète — ce README couvre uniquement la partie
Docker Compose.

## Rôles

| Machine       | Disque   | Fichier compose                                    | Contient |
|---------------|----------|-----------------------------------------------------|----------|
| es-data-1     | 4 To SSD | `docker-compose.es-data.yml` (`NODE_NAME=es01`)    | Elasticsearch (master+data) |
| es-data-2     | 4 To SSD | `docker-compose.es-data.yml` (`NODE_NAME=es02`)    | Elasticsearch (master+data) |
| es-voting     | 256 Go   | `docker-compose.es-voting.yml`                     | Elasticsearch (voting_only) + Kibana |
| kafka         | 256 Go   | `docker-compose.kafka.yml`                         | Kafka (KRaft, broker unique) |
| frontend      | 256 Go   | `docker-compose.frontend.yml`                      | Redis + API + UI + Nginx |
| ingest-1      | 256 Go   | `docker-compose.ingest.yml` + `docker-compose.ingest1-extra.yml` | 2× Tika + workers + watcher + indexer-init |
| ingest-2      | 256 Go   | `docker-compose.ingest.yml`                        | 2× Tika + workers |
| ingest-3      | 256 Go   | `docker-compose.ingest.yml`                        | 2× Tika + workers |

## Préparation (sur les 8 machines)

```bash
mkdir -p ~/docsearch && cd ~/docsearch
git clone <url>/docsearch-infra.git
git clone <url>/docsearch-ingestion.git   # requis sur frontend + ingest-*
git clone <url>/docsearch-api.git          # requis sur frontend
git clone <url>/docsearch-ui.git           # requis sur frontend
cd docsearch-infra/multi-host
cp .env.example .env
nano .env   # renseigner les 8 adresses IP réelles — IDENTIQUE sur les 8 machines
```

## Ordre de démarrage

L'ordre compte : Kafka doit être prêt avant les workers/watcher, l'API a
besoin de Redis, Nginx a besoin de l'API.

1. **es-data-1** et **es-data-2** (en parallèle) :
   ```bash
   NODE_NAME=es01 docker compose -f docker-compose.es-data.yml up -d   # sur es-data-1
   NODE_NAME=es02 docker compose -f docker-compose.es-data.yml up -d   # sur es-data-2
   ```
2. **es-voting** :
   ```bash
   docker compose -f docker-compose.es-voting.yml up -d
   ```
   Vérifier le cluster à 3 nœuds avant de continuer :
   ```bash
   curl -s http://<ES_DATA1_IP>:9200/_cluster/health?pretty
   # "status": "green", "number_of_nodes": 3
   ```
3. **kafka** :
   ```bash
   docker compose -f docker-compose.kafka.yml up -d
   ```
4. **frontend** :
   ```bash
   docker compose -f docker-compose.frontend.yml up -d --build
   ```
5. **ingest-1** (avec les services singletons) :
   ```bash
   docker compose -f docker-compose.ingest.yml \
                   -f docker-compose.ingest1-extra.yml up -d --build
   ```
6. **ingest-2** et **ingest-3** :
   ```bash
   docker compose -f docker-compose.ingest.yml up -d --build
   ```

## Lancer une indexation complète

Depuis **ingest-1** uniquement (c'est la seule machine où vit `indexer-init`) :

```bash
docker compose -f docker-compose.ingest.yml \
                -f docker-compose.ingest1-extra.yml \
                --profile init run --rm indexer-init python producer.py
```

## Ports à ouvrir entre machines (firewall)

| Port | Service | Depuis → vers |
|------|---------|----------------|
| 9200, 9300 | Elasticsearch (HTTP + transport) | es-data-1/2, es-voting entre eux ; frontend et ingest-* → es-data-1 |
| 9092, 9093 | Kafka (client + contrôleur KRaft) | ingest-* → kafka |
| 6379 | Redis | frontend (local) + ingest-* → frontend |
| 9998, 9999 | Tika | ingest-* entre eux (les 3 machines s'appellent mutuellement) |
| 80, 443 | Nginx | Public → frontend |
| 5601 | Kibana | Poste d'administration → es-voting (accès à restreindre, pas de SSO devant Kibana ici) |

Le réseau doit être un LAN dédié à ce cluster (ou au moins isolé/pare-feu
des autres usages) — Gigabit minimum recommandé, le trafic de réplication
ES et Kafka↔workers y transite désormais réellement (contrairement au dev
mono-hôte, où tout passait par le bridge Docker en loopback).

## Partage réseau des sources (`SOURCES_ROOT`)

Le dossier `SOURCES_ROOT` (documents à indexer) doit être monté au même
chemin sur les 4 machines qui en ont besoin : **ingest-1, ingest-2,
ingest-3** (Tika/workers/watcher/indexer-init) et **frontend** (aperçu de
document par l'API). Voir le document d'architecture pour la configuration
du montage CIFS/NFS côté Debian.

## Différences avec `manage.sh`

`manage.sh` (à la racine de `docsearch-infra`) suppose un déploiement
mono-hôte — ses commandes (`start`, `scale-workers`, `set-config`...)
appellent `docker compose` sans `-f`, donc sur le fichier `docker-compose.yml`
racine. Il n'est **pas utilisable tel quel** pour ce déploiement
multi-machines : chaque machine invoque directement `docker compose` avec
son propre fichier (voir ci-dessus). Les commandes de configuration à
chaud (`set-config`, `set-filetype`, `exclude-path`...) restent
utilisables depuis n'importe quelle machine ayant l'image
`docsearch-ingestion` construite (elles ne font que lire/écrire dans
Redis, sur `frontend`) — adapter la commande en remplaçant
`$COMPOSE --profile init run --rm indexer-init` par l'invocation
multi-fichiers d'ingest-1 ci-dessus.
