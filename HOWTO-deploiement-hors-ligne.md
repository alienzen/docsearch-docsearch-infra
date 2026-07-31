# HOWTO — Déploiement hors ligne (production sans Internet)

La production de DocSearch tourne sur un **intranet isolé, sans accès
Internet**. Ce document décrit comment installer et mettre à jour la
pile dans ces conditions.

⚠️ **Le problème n'est pas l'application, c'est le déploiement.** Une
fois démarrée, DocSearch ne fait aucun appel sortant (voir §1). En
revanche, construire les images et récupérer le code demandent un
réseau : ces étapes se font ailleurs, sur une machine de préparation.

## 1. Ce qui a besoin d'Internet, et ce qui n'en a pas

| Étage | Accès Internet | Détail |
|---|---|---|
| **Exécution** de l'application | **Aucun** | Voir ci-dessous |
| **Construction** des images DocSearch | Requis | `apt-get`, `pip install`, `npm ci` dans les Dockerfiles |
| **Images tierces** (ES, Kibana, Kafka, Tika, Redis, Nginx, crawler) | Requis | Tirées depuis `docker.elastic.co`, Docker Hub |
| **Paquets podman** (podman, netavark, aardvark-dns) | Requis | Dépôts Debian + backports |
| **Récupération du code** | Requis | `git clone` / `git pull` depuis le dépôt d'origine |

À l'exécution, rien ne sort du réseau :

- **Interfaces web** — aucun CDN. Les polices Marianne sont servies
  localement (`docsearch-ui/public/fonts/`), les logos sont des SVG
  `data:` inline. Côté `docsearch-ui-vue`, `@iconify/vue` est aliasé
  vers sa variante `offline` dans
  [vite.config.ts](../docsearch-ui-vue/vite.config.ts) — sans cet alias,
  le composant `VIcon` du DSFR irait chercher **chaque icône** sur
  `api.iconify.design` au moment de l'affichage.
- **API** — Elasticsearch, Tika, Redis, Kafka, LDAP/AD uniquement. Aucun
  SDK de LLM, aucune clé d'API tierce, aucun envoi de mail (les alertes
  sont écrites dans Redis, voir `alert_notifications.py`).
- **Ingestion** — Tika, Elasticsearch, Kafka, bases SQL, partages
  CIFS/NFS. Aucune dépendance ne télécharge de modèle ou de dictionnaire
  au premier lancement.

**Seule exception fonctionnelle : les sources web.** Le crawler Elastic
ne peut atteindre que des sites accessibles depuis l'intranet. Les
configurations livrées dans [crawlers/](crawlers/) visent des sites
publics (`conseil-constitutionnel.fr`, `ccomptes.fr`) : elles sont
inexploitables en production isolée. Voir
[HOWTO-creer-source-web.md](HOWTO-creer-source-web.md).

## 2. Principe : une machine de préparation

Tout ce qui a besoin du réseau se fait sur une **machine de préparation**
connectée à Internet, située **hors** du réseau de production. On y
construit et on y tire les images, on les exporte en archives, on les
transfère, puis on les charge sur chaque machine de production.

Une seule exigence : **même architecture que la production**
(`linux/amd64` en pratique). Depuis un poste ARM, ajouter
`--platform linux/amd64` à chaque `podman pull` et `podman build`, sinon
les images ne démarreront pas en production.

> 💡 Contrairement à l'époque Compose, l'arborescence des dossiers n'a
> plus d'importance : les images portent des noms explicites
> (`localhost/docsearch/api:latest`) au lieu de noms dérivés du nom du
> dossier (`multi-host-api`). Une image construite n'importe où se
> charge et s'utilise telle quelle.

## 3. Inventaire des images par machine

| Machine | Images tierces | Images construites |
|---|---|---|
| es-data-1, es-data-2 | `docker.elastic.co/elasticsearch/elasticsearch:9.4.3` | — |
| es-voting | `elasticsearch:9.4.3`, `docker.elastic.co/kibana/kibana:9.4.3` | — |
| kafka | `docker.io/confluentinc/cp-kafka:8.3.0` | — |
| frontend | `docker.io/library/redis:7.2-alpine`, `docker.io/library/nginx:1.27-alpine` | `localhost/docsearch/api`, `localhost/docsearch/ui-vue`, `localhost/docsearch/ingestion`¹ |
| ingest-1/2/3 | `docker.io/apache/tika:3.3.1.0-full` | `localhost/docsearch/ingestion` |

¹ `ingestion` sur frontend seulement si les workers SQL/web y sont
activés (voir `quadlet/roles/frontend/`).

Cette liste se régénère sans rien deviner, depuis les unités installées :

```bash
grep -h '^Image=' /etc/containers/systemd/*.container | sort -u
```

Images supplémentaires nécessaires **uniquement sur la machine de
préparation** (bases de construction, jamais transférées) :
`docker.io/library/python:3.12-slim`, `docker.io/library/nginx:1.27-alpine`,
`docker.io/library/node:22-alpine`.

> 💡 Le crawler web (`docker.elastic.co/integrations/crawler:1.0.0`)
> n'est déclaré que dans la pile mono-hôte. Aucun rôle de production ne
> le porte : à ajouter si des sources web doivent être crawlées depuis
> l'intranet.

## 4. Sur la machine de préparation

### 4.1 Récupérer le code

```bash
mkdir -p ~/docsearch && cd ~/docsearch
git clone <url>/docsearch-infra.git
git clone <url>/docsearch-ingestion.git
git clone <url>/docsearch-api.git
git clone <url>/docsearch-ui-vue.git
```

### 4.2 Tirer les images tierces

```bash
for img in \
  docker.elastic.co/elasticsearch/elasticsearch:9.4.3 \
  docker.elastic.co/kibana/kibana:9.4.3 \
  docker.io/confluentinc/cp-kafka:8.3.0 \
  docker.io/apache/tika:3.3.1.0-full \
  docker.io/library/redis:7.2-alpine \
  docker.io/library/nginx:1.27-alpine ; do
  podman pull "$img"
done
```

### 4.3 Construire les images DocSearch

```bash
cd ~/docsearch/docsearch-infra
./manage.sh build all      # api + ingestion + ui-vue
podman images | grep docsearch
```

### 4.4 Exporter une archive par rôle

`podman save` accepte plusieurs images ; `gzip` divise le volume par
deux à trois (comptez ~2,5 Go pour Elasticsearch, ~2,5 Go pour Kibana,
~1,2 Go pour Tika avant compression).

```bash
mkdir -p ~/docsearch-transfert && cd ~/docsearch-transfert

podman save docker.elastic.co/elasticsearch/elasticsearch:9.4.3 \
  | gzip > es-data.tar.gz

podman save docker.elastic.co/elasticsearch/elasticsearch:9.4.3 \
             docker.elastic.co/kibana/kibana:9.4.3 \
  | gzip > es-voting.tar.gz

podman save docker.io/confluentinc/cp-kafka:8.3.0 | gzip > kafka.tar.gz

podman save docker.io/library/redis:7.2-alpine \
             docker.io/library/nginx:1.27-alpine \
             localhost/docsearch/api:latest \
             localhost/docsearch/ui-vue:latest \
  | gzip > frontend.tar.gz

podman save docker.io/apache/tika:3.3.1.0-full \
             localhost/docsearch/ingestion:latest \
  | gzip > ingest.tar.gz

sha256sum *.tar.gz > SHA256SUMS
```

### 4.5 Récupérer les paquets podman

Les serveurs isolés ne peuvent pas non plus faire `apt install`. Sur une
Debian 12 de préparation, avec les backports activés :

```bash
sudo apt-get install -y --download-only -t bookworm-backports \
     podman netavark aardvark-dns
cp /var/cache/apt/archives/*.deb ~/docsearch-transfert/paquets/
```

⚠️ Vérifier la version obtenue (`podman --version`) : Quadlet exige au
moins **4.4**, et `install-units.sh` refuse de continuer en dessous.

## 5. Transfert

Copier les archives, les paquets `.deb` et **le code source** (les
unités, les configurations Nginx et les fichiers `/etc/docsearch/*.env`
vivent sur les machines, pas dans les images). Deux options pour le
code :

- un dépôt Git interne à l'intranet — le plus confortable, `git pull`
  continue de fonctionner en production ;
- à défaut, une archive : `git archive --format=tar.gz -o
  docsearch-infra.tar.gz HEAD` par dépôt.

Vérifier l'intégrité après copie, avant de charger :

```bash
sha256sum -c SHA256SUMS
```

## 6. Sur chaque machine de production

```bash
# 1. podman et ses dépendances réseau
sudo apt-get install -y ./paquets/*.deb

# 2. images de la machine concernée
gunzip -c frontend.tar.gz | sudo podman load
sudo podman images                       # contrôler que tout est présent

# 3. unités du rôle
cd ~/docsearch/docsearch-infra
sudo ./quadlet/install-units.sh frontend
sudo nano /etc/docsearch/docsearch.env   # renseigner les IP réelles

# 4. démarrage
sudo systemctl start docsearch.target
```

⚠️ Les images doivent être chargées **en rootful** (`sudo podman load`) :
podman sépare le magasin d'images de root de celui de chaque
utilisateur. Une image chargée sans `sudo` reste invisible pour les
unités systemd, qui tournent en root — c'est le piège le plus courant
de cette migration, et il s'est effectivement produit lors de la
bascule.

Pour éviter de le refaire, `transfer-images.sh` vérifie image par image
ce que réclament les unités du rôle et va chercher ce qui manque dans le
magasin de l'utilisateur puis dans celui de Docker :

```bash
sudo ./quadlet/transfer-images.sh frontend --dry-run   # inventaire
sudo ./quadlet/transfer-images.sh frontend             # transfert
```

Il sort en erreur avec la liste des images introuvables, ce qui vaut
mieux que de le découvrir au premier `systemctl start`.

Rien ne construit d'image au démarrage : une unité dont l'image est
absente échoue immédiatement avec un message clair, sans jamais tenter
d'atteindre le réseau. Contrôler avant de démarrer :

```bash
sudo podman images
systemctl list-units 'docsearch-*'
```

## 7. Mettre à jour une brique

```bash
# 1. Sur la machine de préparation
cd ~/docsearch/docsearch-api && git pull
cd ~/docsearch/docsearch-infra && ./manage.sh build api
podman save localhost/docsearch/api:latest | gzip > ~/docsearch-transfert/api.tar.gz

# 2. Transfert de api.tar.gz + du code à jour vers frontend

# 3. Sur frontend
gunzip -c api.tar.gz | sudo podman load
sudo systemctl restart docsearch-api docsearch-alert-worker
```

Trois points à garder en tête :

- `podman load` d'une image portant le même nom **remplace le tag**,
  mais les conteneurs en cours continuent de tourner sur l'ancienne
  image jusqu'au `systemctl restart`. Le basculement reste maîtrisé.
- Une seule image `ingestion` sert aux workers, au watcher, aux workers
  SQL/web et aux commandes d'administration : après l'avoir rechargée,
  redémarrer toutes les unités concernées.
- Les workers d'ingestion sont répliqués : les mettre à jour **une
  machine à la fois** (ingest-1, puis ingest-2, puis ingest-3), pour
  qu'il reste toujours des consommateurs Kafka actifs.

## 8. Pièges connus

- **Magasin d'images rootful.** Voir §6 : toujours `sudo podman load`,
  `sudo podman images`, `sudo podman ps`.
- **Aucun tag flottant.** Le crawler Elastic est épinglé à `1.0.0`
  (même digest `sha256:6f3c02f6c783…` que le `latest` du 2026-07-31). Un
  tag flottant rend impossible de savoir quelle version transférer et
  fait diverger les machines. **Toute nouvelle image ajoutée à une unité
  doit être épinglée**, et son nom pleinement qualifié
  (`docker.io/library/...`) : podman n'a pas de registre implicite.
- **aardvark-dns.** Sans lui, aucun conteneur ne résout le nom d'un
  autre : l'API ne trouve pas Redis, Nginx ne trouve pas l'interface.
  Symptôme typique — tout démarre, puis tout échoue en boucle sur des
  erreurs de connexion.
- **Nouvelles dépendances.** Avant d'ajouter un paquet Python ou npm,
  vérifier qu'il ne télécharge rien au premier lancement (modèles
  HuggingFace, dictionnaires, bases GeoIP…) : la construction passerait
  sur la machine de préparation et l'application échouerait en
  production.
- **Front-end.** Aucun `<script>`, `<link>`, `@font-face` ni `fetch`
  vers un domaine externe. Contrôle rapide :
  ```bash
  grep -rInE "https?://(cdn|unpkg|jsdelivr|cdnjs|fonts\.)" docsearch-ui/public docsearch-ui-vue/src
  ```
- **Télémétrie Elasticsearch / Kibana.** Kibana reçoit
  `TELEMETRY_ENABLED=false` dans ses unités ; sans cela, il tente de
  joindre `elastic.co` — sans conséquence fonctionnelle, mais avec du
  trafic sortant bloqué et du bruit dans les journaux.
