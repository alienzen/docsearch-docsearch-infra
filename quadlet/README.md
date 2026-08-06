# Unités Quadlet — orchestration DocSearch

DocSearch tourne sous **podman rootful**, orchestré par **systemd** via
Quadlet : chaque service est un fichier `.container` que le générateur
Quadlet transforme en unité systemd au démarrage de la machine. Ce
dossier remplace les fichiers Docker Compose.

Ce que ça change en pratique :

| | Compose | Quadlet |
|---|---|---|
| Démarrer | `docker compose --profile dev up -d` | `systemctl start docsearch.target` |
| Au boot | `restart: unless-stopped` (démon Docker) | `systemctl enable docsearch.target` |
| Journaux | `docker compose logs` | `journalctl -u docsearch-api` |
| Dev vs prod | profils (`dev`, `production`) | unités installées sur la machine |
| Réplicas de worker | `deploy.replicas` sans nom stable | une unité par worker, adressable |
| Configuration | `.env` + `${VAR}` interpolés | `/etc/docsearch/*.env` (aucune interpolation) |

## Arborescence

```
quadlet/
├── install-units.sh          installe le rôle demandé sur la machine
├── common/
│   ├── docsearch.target              cible commune (les 8 machines)
│   ├── docsearch-net.network         réseau bridge + DNS entre conteneurs
│   ├── docsearch-kafka-ready.service verrou de disponibilité Kafka
│   ├── bin/docsearch-wait-kafka      script d'attente appelé par l'unité
│   ├── docsearch.env.example         configuration applicative
│   └── elasticsearch.env.example     réglages ES (fichier séparé)
├── dev/                      pile complète sur une machine
└── roles/                    déploiement 8 machines
    ├── es-data/  es-voting/  kafka/  frontend/  ingest/
```

## Installation

```bash
sudo ./quadlet/install-units.sh dev              # poste de développement
sudo ./quadlet/install-units.sh <rôle> [options] # serveur de production
```

L'installateur copie les unités dans `/etc/containers/systemd/`, la
cible et le verrou Kafka dans `/etc/systemd/system/`, la configuration
dans `/etc/docsearch/`, recharge systemd et active la cible au boot.

Les fichiers `/etc/docsearch/*.env` ne sont **jamais écrasés** : à la
première installation ils sont copiés depuis les `.example`, ensuite ils
sont laissés tels quels. Relancer l'installateur après une mise à jour
du dépôt est donc sans risque.

Options : `--workers N` (nombre d'unités worker), `--with-singletons`
(ajoute le watcher — **ingest-1 uniquement**), `--no-enable` (n'active
pas le démarrage au boot), `--dry-run`.

### Démarrage au boot

L'installateur active `docsearch.target` au démarrage de la machine.
Pour ne pas le vouloir — poste de développement où la pile ne doit
monter qu'à la demande :

```bash
sudo systemctl disable docsearch.target   # la pile en cours n'est PAS arrêtée
sudo systemctl is-enabled docsearch.target
```

⚠️ Réinstaller les unités ensuite (mise à jour, `scale-workers`)
réactiverait le démarrage au boot : passer `--no-enable` à
`install-units.sh` pour que le choix soit respecté.

## Déploiement 8 machines

| Machine | Disque | Rôle à installer | Contient |
|---|---|---|---|
| es-data-1 | 4 To SSD | `es-data` (`node.name=es01`) | Elasticsearch (master+data) |
| es-data-2 | 4 To SSD | `es-data` (`node.name=es02`) | Elasticsearch (master+data) |
| es-voting | 256 Go | `es-voting` | Elasticsearch (voting_only) + Kibana |
| kafka | 256 Go | `kafka` | Kafka (KRaft, broker unique) |
| frontend | 256 Go | `frontend` | Redis + API + interface + Nginx |
| ingest-1 | 256 Go | `ingest --with-singletons` | 2× Tika + 3 workers + watcher |
| ingest-2 | 256 Go | `ingest` | 2× Tika + 3 workers |
| ingest-3 | 256 Go | `ingest` | 2× Tika + 3 workers |

Ce qui distinguait `NODE_NAME=es01 docker compose up` d'une machine à
l'autre vit maintenant dans `/etc/docsearch/elasticsearch.env` : les
unités sont identiques sur les deux nœuds de données, plus rien à passer
en ligne de commande — donc plus de risque de démarrer deux nœuds avec
le même nom.

### Ordre de démarrage

L'ordre entre machines reste manuel (systemd ne coordonne qu'une
machine) : **es-data-1 et es-data-2**, puis **es-voting** (vérifier que
le cluster voit 3 nœuds), puis **kafka**, puis **frontend**, puis les
trois **ingest**. Sur chaque machine :

```bash
sudo systemctl start docsearch.target
```

À l'intérieur d'une machine, l'ordre est géré par systemd : l'API attend
Redis, les workers attendent que Kafka réponde (`docsearch-kafka-ready`),
Nginx attend l'API et l'interface.

### Ports à ouvrir entre machines

| Port | Service | Depuis → vers |
|---|---|---|
| 9200, 9300 | Elasticsearch (HTTP + transport) | es-data-1/2, es-voting entre eux ; frontend et ingest-* → es-data-1 |
| 9092, 9093 | Kafka (client + contrôleur KRaft) | ingest-* → kafka |
| 6379 | Redis | frontend (local) + ingest-* → frontend |
| 9998, 9999 | Tika | ingest-* entre eux (les 3 machines s'appellent mutuellement) |
| 80, 443 | Nginx | Public → frontend |
| 5601 | Kibana | Poste d'administration → es-voting (pas de SSO devant Kibana) |

### Partage réseau des sources

Le dossier des documents doit être monté au même chemin sur les 4
machines qui en ont besoin : **ingest-1/2/3** (workers, watcher) et
**frontend** (aperçu de document par l'API). Les unités le montent en
lecture seule : `Volume=/data/docsearch-sources:/sources:ro`.

L'unité `docsearch-api` monte deux répertoires de secrets, également en
lecture seule : `/etc/docsearch/jwt` (clés RS256 qui signent les sessions)
et `/etc/docsearch/krb5` (keytab du SSO). **Le montage étant en lecture
seule, la génération des clés passe par un conteneur jetable** — un
`podman exec` dans le service échouerait sur un système de fichiers en
lecture seule :

```bash
sudo install -d -o 1000 -g 1000 -m 700 /etc/docsearch/jwt
sudo podman run --rm -v /etc/docsearch/jwt:/etc/docsearch/jwt:Z \
     localhost/docsearch/api:latest python scripts/generer-cles.py
```

`-o 1000` est l'UID de l'utilisateur *dans* le conteneur : appartenant à
root, les clés seraient générées puis illisibles par le service, et
`/auth/login` répondrait 503.

## Points à connaître

**Aucune interpolation dans les unités.** Quadlet ne substitue pas
`${VAR}` : tout ce qui varie d'une machine à l'autre passe par
`EnvironmentFile=`. Les valeurs par défaut qui vivaient dans
`docker-compose.yml` (`${ES_INDEX:-documents}`) sont donc toutes écrites
explicitement dans `/etc/docsearch/docsearch.env`.

**Chemins d'hôte en dur.** Pour la même raison, les montages sont
littéraux dans les unités. Pour en changer sans modifier le dépôt,
utiliser un drop-in :

```bash
sudo mkdir -p /etc/containers/systemd/docsearch-api.container.d
sudo tee /etc/containers/systemd/docsearch-api.container.d/override.conf <<'EOF'
[Container]
Volume=/autre/chemin:/sources:ro
EOF
sudo systemctl daemon-reload && sudo systemctl restart docsearch-api
```

⚠️ `SOURCES_HOST_PATH` (dans `docsearch.env`) doit alors être aligné :
c'est la valeur qu'utilisent les commandes ponctuelles de `manage.sh`
(`init`, `purge-path`…), qui lancent un conteneur hors unité.

**Noms DNS entre conteneurs.** Sur le réseau `docsearch-net`, un
conteneur est joignable par son `ContainerName` (`docsearch-api`) et par
ses alias. Les unités déclarent en alias les anciens noms de service
Compose (`api`, `redis`, `kafka`, `tika1`, `es01-dev`, `ui-vue`) : c'est
ce qui permet de garder `nginx.conf` et les valeurs de configuration
existantes sans les réécrire.

**Après modification d'une unité** (dans le dépôt) : réinstaller puis
recharger.

```bash
sudo ./quadlet/install-units.sh dev
sudo systemctl restart docsearch.target
```

Un `daemon-reload` seul ne recrée pas les conteneurs déjà démarrés.

**Vérifier ce que Quadlet génère** — utile pour diagnostiquer une unité
ignorée, ou contrôler qu'une clé est bien prise en charge par la version
de podman installée :

```bash
/usr/libexec/podman/quadlet -dryrun
```

**Services optionnels.** Certaines unités n'ont volontairement pas de
section `[Install]` : elles ne démarrent qu'à la demande, sans être
tirées par la cible.

- mono-hôte : `docsearch-kibana`, `docsearch-tika2/3/4`,
  `docsearch-dev-user-proxy`
- production (`frontend`) : `docsearch-alert-worker`,
  `docsearch-sql-worker`, `docsearch-web-worker`

```bash
sudo systemctl start docsearch-kibana
```

⚠️ Activer un serveur Tika supplémentaire suppose de l'ajouter à
`TIKA_SERVERS` dans `docsearch.env` : un serveur listé mais absent fait
échouer une extraction sur N.

## Dépannage

Les quatre pannes ci-dessous sont celles réellement rencontrées lors de
la bascule. Toutes ont le même symptôme de surface — des unités
`inactive (dead)` et rien qui répond — pour des causes très différentes.

### 1. Rien ne démarre : le sous-réseau est déjà pris

Sur toute machine ayant hébergé la pile Docker Compose, un réseau
orphelin subsiste et occupe `172.20.0.0/16` — son pont reste déclaré
dans les routes de l'hôte même sans conteneur. Comme toutes les unités
dépendent du réseau, **rien ne démarre**.

```
docsearch-net-network.service: Error: subnet 172.20.0.0/16 is already
used on the host or by another config
```

```bash
ip -4 route | grep 172.20               # qui occupe le sous-réseau
docker network ls                       # le coupable habituel
docker network rm docsearch-infra_docsearch-net
sudo systemctl start docsearch.target
```

Le symptôme est trompeur : `docsearch-kafka-ready` apparaît aussi en
échec, alors qu'il a simplement attendu 600 s un broker qui ne pouvait
pas démarrer. **Toujours remonter à l'unité réseau en premier.**

### 2. « connection refused » sur le port 443 de localhost

```
Error: initializing source docker://localhost/docsearch/api:latest:
pinging container registry localhost: dial tcp 127.0.0.1:443: connection refused
```

L'image est absente du magasin de **root**. Ne la trouvant pas, podman
interprète `localhost` comme un nom de registre et tente une connexion
HTTPS. Seules les unités utilisant `localhost/docsearch/*` sont touchées
— les images tierces, elles, sont tirées d'Internet sans bruit, ce qui
masque le problème sur une machine connectée.

```bash
sudo podman images | grep docsearch     # vérifier le magasin de ROOT
sudo ./quadlet/transfer-images.sh dev   # transférer depuis le magasin
                                        # utilisateur ou depuis Docker
```

### 3. Les unités abandonnent après quelques tentatives

Avec `Restart=always`, systemd arrête de réessayer au-delà de sa limite
de démarrages et laisse l'unité en `inactive`. Après avoir corrigé la
cause, un simple `start` ne suffit pas :

```bash
sudo systemctl reset-failed 'docsearch-*'
sudo systemctl start docsearch.target
```

### 4. La configuration installée n'est pas celle attendue

`install-units.sh` **n'écrase jamais** un `/etc/docsearch/*.env`
existant : il le crée depuis le modèle à la première installation, et le
laisse tel quel ensuite. Une configuration préparée puis copiée *après*
l'installateur n'est donc jamais prise en compte, et la pile démarre
avec les valeurs d'exemple — symptôme typique : l'API répond
`403 « Panneau d'administration nécessite LDAP_ENABLED=true »` alors que
le fichier préparé contient bien `LDAP_ENABLED=true`.

```bash
sudo grep -E '^(LDAP_ENABLED|ES_HOST)=' /etc/docsearch/docsearch.env
sudo install -m 0600 -o root -g root mon-docsearch.env /etc/docsearch/docsearch.env
sudo systemctl restart docsearch.target
curl -s http://localhost:8000/health    # doit rapporter ldap_enabled: True
```

### Faux positif fréquent : une recherche qui renvoie 0

Elasticsearch suspend le rafraîchissement automatique d'un index que
personne n'interroge (`index.search.idle.after`, 30 s). Juste après une
indexation, `_cat/indices` peut afficher des centaines de documents
pendant que `_count` et la recherche renvoient 0. Ce n'est pas une
panne :

```bash
curl -s -X POST http://localhost:9200/documents/_refresh
curl -s http://localhost:9200/docsearch-all/_count
```

La première vraie recherche déclenche le rafraîchissement d'elle-même.

## Docker Compose a été retiré

Les fichiers `docker-compose*.yml`, le dossier `multi-host/` et
`.env.example` ont été **supprimés** : Quadlet est la seule orchestration
du projet. Ils restent récupérables dans l'historique git si un doute
survient sur une traduction (`git show HEAD:docker-compose.yml`).

**Si des conteneurs Docker tournent encore** d'une installation
antérieure, ils ne peuvent plus être arrêtés par `docker compose down` —
les arrêter par leur nom :

```bash
docker rm -f $(docker ps -aq --filter name=docsearch)
docker volume ls | grep docsearch     # volumes de l'ancienne pile
```

Tant qu'ils tournent, ils occupent les ports (9200, 9092, 6379, 8000,
8080…) que réclament les unités : la pile podman ne démarrera pas
avant leur arrêt.

⚠️ Les volumes Docker (`docsearch-infra_es01_data`…) ne sont pas repris
par podman : la pile podman démarre avec des index **vides**. Prévoir une
réindexation (`sudo ./manage.sh init`) ou un snapshot Elasticsearch restauré
après bascule. Les données montées depuis l'hôte (`/data/es` en
production) ne sont pas concernées.

### Reprendre la configuration Redis de l'ancienne pile

Elasticsearch se réindexe, mais Redis contient ce qui ne se retrouve pas
tout seul : registres de sources (fichier/SQL/web), filtres de chemin,
types de fichiers, réglages runtime et UI, recherches sauvegardées.
Son `dump.rdb` se transporte d'un volume à l'autre.

```bash
# 1. Extraire depuis le volume Docker (avant de le supprimer !)
docker run --rm -v docsearch-infra_redis_data:/data:ro \
  docker.io/library/alpine:latest tar -cf - -C /data dump.rdb > redis-data.tar

# 2. Créer le volume podman et y importer l'archive, AVANT tout démarrage
#    de Redis — un Redis qui s'arrête réécrit dump.rdb et écraserait la
#    reprise. Le volume est créé par Quadlet avec "--ignore" : le
#    pré-créer ne gêne pas l'installation.
sudo podman volume create systemd-redis-data
sudo podman volume import systemd-redis-data redis-data.tar

# 3. Installer, démarrer, vérifier
sudo ./quadlet/install-units.sh dev
sudo systemctl start docsearch.target
sudo podman exec docsearch-redis redis-cli DBSIZE
```

Le nom du volume dépend de la version de podman (`systemd-redis-data`
avec le préfixe Quadlet, `redis-data` sans) — le vérifier avec
`sudo podman volume ls` en cas de doute. Les clés `docsearch:heartbeat:*`
expirent au chargement, c'est normal : les workers les réécrivent.

Checklist de validation de la bascule :

1. `sudo ./quadlet/install-units.sh <rôle>` passé sur la machine ;
2. `sudo systemctl start docsearch.target` puis
   `systemctl list-units 'docsearch-*'` — tout `active` ;
3. chaîne fonctionnelle : `./manage.sh status`, `sudo ./manage.sh init`, une
   recherche qui renvoie des résultats, `/admin.html` qui voit
   Elasticsearch, Tika et Kafka ;
4. redémarrage machine : la pile remonte seule, sans boucle de
   redémarrage dans `journalctl -u 'docsearch-*'`.

## Prérequis podman

- **podman ≥ 4.4** (Quadlet). **Debian 13 « trixie » livre 5.4.2 dans ses
  dépôts stables : plus aucun backport n'est nécessaire.** (Sur une
  Debian 12 résiduelle, il fallait passer par `bookworm-backports`, la
  version stable — 4.3 — étant en dessous du seuil.) L'installateur
  vérifie et refuse de continuer en dessous.
- **netavark** et **aardvark-dns** : sans aardvark-dns, aucun conteneur
  ne résout le nom d'un autre et toute la pile tombe.
- **rootful** : les ports 80/443, les montages de partages réseau et la
  lecture des ACL POSIX/CIFS supposent podman en root.

### Passage de podman 4.9 à 5.4 (Debian 12 → 13)

C'est un saut de version majeure, et il mérite une vérification plutôt
qu'une supposition. Les clés Quadlet employées ici (`Image`, `Exec`,
`Volume`, `Network`, `PublishPort`, `PodmanArgs`, `HealthCmd`) n'ont pas
changé de syntaxe, et le seul retrait notable de podman 5 — CNI, remplacé
par netavark — ne concerne pas cette installation, qui utilise déjà
netavark et aardvark-dns.

Sur la **première** machine migrée, faire tourner le générateur à blanc
avant de démarrer quoi que ce soit : il relit toutes les unités et signale
les clés qu'il ne comprend pas, sans rien créer.

```bash
sudo /usr/lib/systemd/system-generators/podman-system-generator --dryrun
```

Une sortie sans erreur vaut mieux qu'un `systemctl start` qui échoue unité
par unité.

⚠️ **Le magasin d'images de root est distinct de celui de chaque
utilisateur.** Une image construite ou tirée sans `sudo` n'est pas
visible par les unités systemd — symptôme : `image not known` au
démarrage alors que `podman images` la montre.

`transfer-images.sh` règle la question : il lit les images réclamées par
les unités du rôle, et va chercher celles qui manquent dans le magasin
podman de l'utilisateur puis dans celui de Docker.

```bash
sudo ./quadlet/transfer-images.sh dev --dry-run   # montre ce qui serait fait
sudo ./quadlet/transfer-images.sh dev             # transfère
```

Les transferts se font par tube, sans archive intermédiaire sur disque.
Récupérer les images tierces depuis Docker évite de retélécharger ~8 Go
(Elasticsearch, Kibana, Kafka, Tika…), et les noms courts de Docker sont
requalifiés à la volée : `redis:7.2-alpine` devient
`docker.io/library/redis:7.2-alpine`, exactement ce que déclarent les
unités.

Alternative sans transfert, si les images n'existent pas encore :
`sudo ./manage.sh build all` construit directement dans le magasin de
root. Dans tous les cas, vérifier avec `sudo podman images`, jamais
`podman images`.

Sur une machine isolée du réseau, ces paquets doivent être transférés au
même titre que les images — voir
[HOWTO-deploiement-hors-ligne.md](../HOWTO-deploiement-hors-ligne.md).
