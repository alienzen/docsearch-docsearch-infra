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
| **Paquets podman** (podman, netavark, aardvark-dns) | Requis | Dépôts Debian 13 stables |
| **Récupération du code** | Requis | `git clone` / `git pull` depuis le dépôt d'origine |

À l'exécution, rien ne sort du réseau :

- **Authentification** — l'annuaire LDAP/AD et, si la connexion
  automatique est activée, le KDC Kerberos sont des services **de
  l'intranet** : aucun appel sortant. Les jetons de session sont signés
  localement par une clé RS256 générée sur place, il n'y a pas d'autorité
  externe à joindre. Côté **construction**, en revanche, l'image de l'API
  compile `gssapi` contre `libkrb5-dev` : ces paquets s'installent (et se
  purgent) pendant le build, sur la machine de préparation.

- **Interface web** — aucun CDN. Les polices Marianne viennent du paquet
  `@gouvfr/dsfr` et entrent dans le bundle Vite à la construction (voir
  [src/dsfr.ts](../docsearch-ui-vue/src/dsfr.ts)) : plus rien à recopier
  à la main dans `public/fonts/` comme le faisait `docsearch-ui`. Les
  logos sont des SVG `data:` inline. `@iconify/vue` est aliasé
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
  sudo podman pull "$img"
done
```

### 4.3 Construire les images DocSearch

```bash
cd ~/docsearch/docsearch-infra
sudo ./manage.sh build all      # api + ingestion + ui-vue
sudo podman images | grep docsearch
```

⚠️ **Tout ce chapitre travaille dans le magasin rootful**, `sudo` compris
sur `podman pull` et `podman save` : les deux magasins sont étanches, et
un export ne trouve que ce qui a été tiré ou construit dans le sien.
Mélanger les deux donne un `image not known` à l'export, ou une archive
silencieusement incomplète.

C'est la même règle que sur les machines cibles (`sudo podman load`,
§6), appliquée ici par cohérence : un seul magasin, celui de root, du
début à la fin de la chaîne. Voir
[HOWTO-commandes-utiles.md](HOWTO-commandes-utiles.md), section
« Construire en rootless, exécuter en rootful ».

ℹ️ Sur la machine de préparation, les images ne sont jamais exécutées —
elles sont construites puis exportées. Le magasin de root y sert donc
uniquement d'espace de travail, et peut être purgé après transfert
(`sudo podman image prune -f`) : sur une machine qui produit plusieurs
Go d'archives, ce n'est pas anecdotique.

### 4.4 Exporter une archive par rôle

`podman save` accepte plusieurs images ; `gzip` divise le volume par
deux à trois (comptez ~2,5 Go pour Elasticsearch, ~2,5 Go pour Kibana,
~1,2 Go pour Tika avant compression).

Les images DocSearch portent DEUX tags depuis `./manage.sh build` :
`:latest`, que visent les unités Quadlet, et `:<version>` lu dans le
fichier `VERSION` des dépôts. **Transférer les deux** — c'est le tag
versionné qui permet ensuite de savoir, sur un serveur isolé, ce qui y a
été chargé (`sudo podman images`). Nommer aussi les archives d'après la
version : sur une chaîne de transfert manuelle vers huit machines, une
archive anonyme est une confusion qui attend son tour.

```bash
mkdir -p ~/docsearch-transfert && cd ~/docsearch-transfert

# Version produit à transférer — celle des fichiers VERSION des dépôts,
# identique dans les trois, telle que taguée par ./manage.sh build.
VERSION=2.2.0

sudo podman save docker.elastic.co/elasticsearch/elasticsearch:9.4.3 \
  | gzip > es-data.tar.gz

sudo podman save docker.elastic.co/elasticsearch/elasticsearch:9.4.3 \
             docker.elastic.co/kibana/kibana:9.4.3 \
  | gzip > es-voting.tar.gz

sudo podman save docker.io/confluentinc/cp-kafka:8.3.0 | gzip > kafka.tar.gz

sudo podman save docker.io/library/redis:7.2-alpine \
             docker.io/library/nginx:1.27-alpine \
             localhost/docsearch/api:latest     localhost/docsearch/api:$VERSION \
             localhost/docsearch/ui-vue:latest  localhost/docsearch/ui-vue:$VERSION \
  | gzip > frontend-$VERSION.tar.gz

sudo podman save docker.io/apache/tika:3.3.1.0-full \
             localhost/docsearch/ingestion:latest localhost/docsearch/ingestion:$VERSION \
  | gzip > ingest-$VERSION.tar.gz

sha256sum *.tar.gz > SHA256SUMS
```

ℹ️ Les deux tags d'une même image ne pèsent rien de plus dans l'archive :
`podman save` n'écrit les couches qu'une fois et ne répète que la
référence.

Pour vérifier ce que contient une archive **sans la charger**, ou ce
qu'une image chargée annonce comme identité :

```bash
sudo podman inspect --format '{{index .Labels "org.opencontainers.image.version"}} {{index .Labels "org.opencontainers.image.revision"}}' \
  localhost/docsearch/api:latest
```

Un `revision` suffixé de `+modifie` signale une image construite depuis
un dépôt portant des modifications non commitées — à ne pas laisser
partir en production.

### 4.5 Récupérer les paquets podman

Les serveurs isolés ne peuvent pas non plus faire `apt install`. Sur une
Debian 13 de préparation — **de même version que les machines cibles**,
sans quoi les dépendances téléchargées ne s'installeront pas :

```bash
sudo apt-get install -y --download-only podman netavark aardvark-dns
cp /var/cache/apt/archives/*.deb ~/docsearch-transfert/paquets/
```

Plus de `-t bookworm-backports` : Debian 13 livre podman 5.4.2 dans ses
dépôts stables. Le drapeau était indispensable sur Debian 12, dont la
version stable (4.3) passait sous le seuil.

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

# 3bis. frontend UNIQUEMENT — clés de signature des sessions.
# Aucune sortie réseau : la paire RSA est générée sur place, dans l'image
# déjà chargée. Sans elle, l'application démarre mais /auth/login répond
# 503 et personne ne peut se connecter.
sudo install -d -o 1000 -g 1000 -m 700 /etc/docsearch/jwt
sudo podman run --rm -v /etc/docsearch/jwt:/etc/docsearch/jwt:Z \
     localhost/docsearch/api:latest python scripts/generer-cles.py
# reporter les 3 lignes JWT_* dans /etc/docsearch/docsearch.env

# 4. démarrage
sudo systemctl start docsearch.target
```

⚠️ Un conteneur **jetable**, et non `podman exec` dans le service : l'unité
monte `/etc/docsearch/jwt` en lecture seule. Et `-o 1000` donne le
répertoire à l'UID de l'utilisateur *dans* le conteneur — appartenant à
root, les clés seraient générées puis illisibles par le service.

Prévoir aussi, sur le frontend, un **compte de secours local** avant la
première panne d'annuaire : sans lui, un annuaire injoignable rend
DocSearch totalement inaccessible, administration comprise. Il porte ses
propres groupes, ce qui est justement ce qui le rend utilisable quand
l'annuaire ne répond plus.

```bash
sudo podman exec -it docsearch-api python scripts/gerer-comptes-locaux.py \
     creer secours.admin --groupes docsearch-users,docsearch-admins
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
VERSION=$(cat VERSION)
cd ~/docsearch/docsearch-infra && sudo ./manage.sh build api
sudo podman save localhost/docsearch/api:latest localhost/docsearch/api:$VERSION \
  | gzip > ~/docsearch-transfert/api-$VERSION.tar.gz

# 2. Transfert de api-$VERSION.tar.gz + du code à jour vers frontend

# 3. Sur frontend
gunzip -c api-*.tar.gz | sudo podman load
sudo systemctl restart docsearch-api docsearch-alert-worker

# 4. Contrôle : la version annoncée est-elle la bonne ?
curl -s http://localhost:8000/health | python3 -m json.tool
```

Quatre points à garder en tête :

- `podman load` d'une image portant le même nom **remplace le tag**,
  mais les conteneurs en cours continuent de tourner sur l'ancienne
  image jusqu'au `systemctl restart`. Le basculement reste maîtrisé.
- Une seule image `ingestion` sert aux workers, au watcher, aux workers
  SQL/web et aux commandes d'administration : après l'avoir rechargée,
  redémarrer toutes les unités concernées.
- Les workers d'ingestion sont répliqués : les mettre à jour **une
  machine à la fois** (ingest-1, puis ingest-2, puis ingest-3), pour
  qu'il reste toujours des consommateurs Kafka actifs.
- Une mise à jour ne portant que sur une brique fait volontairement
  diverger les versions — l'administration l'affiche alors en
  avertissement, ce qui est le comportement voulu. Elle ne redevient
  silencieuse qu'une fois les trois briques alignées.

## 8. Pièges connus

- **Magasin d'images rootful.** Voir §6 : toujours `sudo podman load`,
  `sudo podman images`, `sudo podman ps`.
- **Aucun tag flottant** — pour les images TIERCES. Le crawler Elastic
  est épinglé à `1.0.0` (même digest `sha256:6f3c02f6c783…` que le
  `latest` du 2026-07-31). Un tag flottant rend impossible de savoir
  quelle version transférer et fait diverger les machines. **Toute
  nouvelle image tierce ajoutée à une unité doit être épinglée**, et son
  nom pleinement qualifié (`docker.io/library/...`) : podman n'a pas de
  registre implicite.

  **Exception assumée : les trois images DocSearch restent en `:latest`
  dans les unités.** Ce que la règle ci-dessus proscrit, c'est un tag
  qu'un `podman pull` peut faire glisser sous les pieds d'une machine
  sans qu'on l'ait demandé. Ici il n'y a pas de registre : une image
  n'arrive que par un `podman load` explicite d'une archive précise, et
  le conteneur continue de tourner sur l'ancienne jusqu'au `systemctl
  restart`. Épingler les unités obligerait à les éditer, recharger
  systemd et redémarrer sur chaque machine à chaque livraison, sans rien
  empêcher de plus. La traçabilité est assurée autrement : le tag
  `:<version>` transféré à côté de `:latest` (§4.4), les labels OCI de
  l'image, et l'affichage en administration (« État des composants »,
  bloc « Versions déployées »).
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
