# docsearch-infra

Orchestration de **DocSearch** sous **podman + systemd (Quadlet)** —
c'est le dépôt à cloner en premier et celui qui lance l'ensemble du
système. Les unités et leur installation sont décrites dans
[quadlet/README.md](quadlet/README.md).

Pour la liste complète des fonctionnalités (recherche, ingestion,
administration, sécurité), voir [FEATURES.md](FEATURES.md).

## Architecture multi-dépôts

DocSearch est découpé en 6 dépôts indépendants :

| Dépôt | Rôle | Cycle de vie |
|---|---|---|
| [docsearch-ingestion](../docsearch-ingestion) | Extraction, ACL, indexation | Évolue avec les formats de documents |
| [docsearch-api](../docsearch-api) | API de recherche (FastAPI) | Évolue avec les besoins de recherche |
| [docsearch-ui-vue](../docsearch-ui-vue) | Interface web (Vue 3 + DSFR) | Évolue avec l'UX |
| **docsearch-infra** (ce dépôt) | Orchestration, déploiement | Évolue rarement |
| [docsearch-docs](../docsearch-docs) | Documents commerciaux | Géré par les équipes commerciales |
| `docsearch-dataset-generator` | Génération de jeux de test | Cloné à la demande, hors de la disposition ci-dessous |

**Interface historique** — `docsearch-ui` (HTML/JS sans build) a été
remplacée par `docsearch-ui-vue` et n'est plus clonée : son dépôt est
archivé à la racine sous forme de bundle git, avec le stash resté en
suspens (`../docsearch-ui-2026-08-10.bundle`,
`../docsearch-ui-stash-2026-07-10.patch`). Elle n'a ni unité systemd ni
service déclaré : la remobiliser en repli se fait entièrement à la main.

```bash
git clone ../docsearch-ui-2026-08-10.bundle ../docsearch-ui
cd ../docsearch-ui
sudo podman build -t localhost/docsearch/ui:latest .
sudo podman run -d --name docsearch-ui -p 8082:80 \
  --network docsearch-net localhost/docsearch/ui:latest
```

Le `sudo` de la construction est indispensable ici aussi (voir plus bas,
« Reconstruire après modification d'un sous-projet »). Il reste ensuite à
pointer l'amont `ui_backend` de [nginx/nginx.conf](nginx/nginx.conf) sur
`docsearch-ui:80` — le 8082 ci-dessus est publié sur l'hôte, pas visible
depuis le proxy — et à redémarrer `docsearch-nginx`, qui résout ses amonts
au démarrage.

Le bundle contient `main` et le stash (`refs/stash`), que `git clone` ne
récupère pas — il faut aller le chercher, et il **entre en conflit** avec
`main`, dont les derniers commits lui sont postérieurs. Le même contenu est
fourni en clair dans `../docsearch-ui-stash-2026-07-10.patch`, qui ne
s'applique pas tel quel sur `main` pour la même raison.

```bash
# depuis ../docsearch-ui
git fetch ../docsearch-ui-2026-08-10.bundle 'refs/stash:refs/stash'
git stash apply refs/stash   # conflits à résoudre
```

**Convention de clonage** — tous les dépôts doivent être clonés côte à côte
dans un même dossier parent, car `./manage.sh build` construit les images
depuis des chemins relatifs (`../docsearch-ingestion`, `../docsearch-api`,
`../docsearch-ui-vue`) :

```
docsearch/
├── docsearch-infra/       ← vous êtes ici, lancez manage.sh depuis ce dossier
├── docsearch-ingestion/
├── docsearch-api/
├── docsearch-ui-vue/
└── docsearch-docs/
```

```bash
mkdir docsearch && cd docsearch
git clone <url>/docsearch-infra.git
git clone <url>/docsearch-ingestion.git
git clone <url>/docsearch-api.git
git clone <url>/docsearch-ui-vue.git
git clone <url>/docsearch-docs.git

cd docsearch-infra
chmod +x manage.sh quadlet/install-units.sh

sudo ./manage.sh build all               # construit les images (machine CONNECTÉE)
sudo ./quadlet/install-units.sh dev      # installe les unités systemd
sudo nano /etc/docsearch/docsearch.env   # adapter SOURCES_HOST_PATH, LDAP...

sudo ./manage.sh start                   # démarre la pile
sudo ./manage.sh init                    # publie les fichiers sur Kafka (voir note ci-dessous)
```

> ⚠️ **`init` ne fait qu'écrire sur Kafka** — l'indexation réelle est
> faite en arrière-plan par les unités `docsearch-worker-*`, qui doivent
> déjà tourner (démarrées par `start`). Si `init` est lancé alors
> qu'aucun worker n'est actif (pile jamais démarrée, ou arrêtée depuis
> un `stop`/`reset`), l'index est créé mais reste
> vide, sans erreur visible — `manage.sh` vérifie maintenant ce cas
> et refuse de continuer si Kafka ou les workers ne sont pas détectés.
> Suivre la progression avec `./manage.sh logs worker` et
> `curl http://localhost:9200/documents/_count?pretty`.
>
> **`init` reste nécessaire pour le contenu déjà présent** au moment où
> une source est enregistrée (`add-file-source`) : le watcher ne détecte
> que les fichiers créés/modifiés APRÈS son démarrage, jamais ceux déjà
> sur disque à cet instant-là. En revanche, le mapping Elasticsearch et
> l'alias de recherche fédérée sont désormais initialisés automatiquement
> par le watcher dès qu'il commence à surveiller une source — un fichier
> déposé après coup dans le dossier d'une source jamais "init" est
> maintenant indexé et cherchable correctement (auparavant, Elasticsearch
> auto-créait l'index à la première écriture avec un mapping dynamique et
> sans alias, le rendant invisible à la recherche fédérée, sans aucune
> erreur visible pour le diagnostiquer).


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
sudo ./manage.sh start      # Démarre docsearch.target
sudo ./manage.sh stop
./manage.sh status
./manage.sh logs <service>  # ex: api, worker, watcher, es01
sudo ./manage.sh init            # Indexation initiale (dossier complet)
sudo ./manage.sh init finance    # Réindexer uniquement la source "finance"
sudo ./manage.sh scale-workers N
sudo ./manage.sh build [all|api|ingestion|ui]
./manage.sh backup
sudo ./manage.sh reset      # ⚠️ supprime toutes les données
```

Ce qu'une machine démarre dépend des unités qui y sont installées
(`quadlet/install-units.sh <rôle>`) : il n'y a plus de `start-prod` ni de
profils.

**Qui a besoin de `sudo`** — les unités, le réseau, les images et
`/etc/docsearch/*.env` appartiennent tous à root (podman rootful) :

| Sans sudo | Avec sudo |
|---|---|
| `status`, `logs`, `build`, `backup`, `get-config`, `get-filetypes`, `list-*` | `start`, `stop`, `restart`, `reset`, `init`, `scale-workers`, `dev-user`, et toutes les commandes qui modifient une source ou la configuration (`add-*`, `remove-*`, `run-*`, `set-*`, `*-path`) |

Les commandes d'administration lancent un conteneur jetable sur le
réseau de la pile : sans `sudo`, `manage.sh` refuse avec un message
explicite plutôt que d'échouer sur un « réseau introuvable ».

## Reconstruire après modification d'un sous-projet

Une image par dépôt, et non plus une par service : reconstruire
`ingestion` met à jour d'un coup les workers, le watcher, les workers
SQL/web et les commandes d'administration. Il reste à redémarrer les
unités qui l'utilisent.

```bash
# Après une modification dans docsearch-ingestion :
sudo ./manage.sh build ingestion
sudo systemctl restart 'docsearch-worker-*' docsearch-watcher docsearch-sql-worker docsearch-web-worker

# Après une modification dans docsearch-api :
# (docsearch-api ET alert-worker partagent l'image)
sudo ./manage.sh build api
sudo systemctl restart docsearch-api docsearch-alert-worker

# Après une modification dans docsearch-ui-vue :
sudo ./manage.sh build ui
sudo systemctl restart docsearch-ui-vue
```

⚠️ Le `sudo` de la construction est indispensable : les unités systemd
tournent en root et ne voient pas les images d'un magasin rootless. Sans
lui, l'unité redémarre sans erreur et continue de servir l'image
précédente. Détail et procédure de rattrapage dans
[HOWTO-commandes-utiles.md](HOWTO-commandes-utiles.md), section
« Construire en rootless, exécuter en rootful ».

⚠️ Le code est copié DANS l'image : modifier un fichier sur disque n'a
aucun effet tant que l'image n'est pas reconstruite **et** l'unité
redémarrée.

## Chemin des documents (hôte vs conteneur)

Trois valeurs distinctes, à ne pas confondre :

| Valeur | Où elle est écrite | Rôle |
|---|---|---|
| `Volume=/chemin:/sources:ro` | dans chaque unité `.container` | montage réel du dossier de l'**hôte** |
| `SOURCES_HOST_PATH` | `/etc/docsearch/docsearch.env` | le même chemin hôte, pour les commandes ponctuelles de `manage.sh` |
| `SOURCES_MOUNT` | `/etc/docsearch/docsearch.env` | chemin correspondant **dans les conteneurs** (`/sources`) |

⚠️ **Ces valeurs peuvent diverger, et c'est le principal piège de
l'orchestration par unités** : Quadlet ne substitue aucune variable, le
chemin hôte est donc écrit en dur dans les unités et dupliqué dans
`SOURCES_HOST_PATH`. À l'époque de Compose, une seule variable pilotait
les deux et la divergence était impossible.

Conséquence : pour changer de dossier de sources, modifier **les deux**
(unités via un drop-in, voir [quadlet/README.md](quadlet/README.md), et
`SOURCES_HOST_PATH`). Les oublier à moitié reproduit un bug déjà
rencontré par le passé : le code cherche dans un chemin différent de
celui réellement monté, index vide sans erreur visible.

## Panneau d'administration

Accessible sur `/admin.html`, réservé aux membres du groupe LDAP/AD
défini par `ADMIN_GROUP` (nécessite `LDAP_ENABLED=true`) :

```bash
# /etc/docsearch/docsearch.env
LDAP_ENABLED=true
ADMIN_GROUP=docsearch-admins
```

Permet de consulter l'état des composants, ajuster la configuration
(types de fichiers, paramètres opérationnels, filtres de chemin) et
déclencher un scan ou une purge — sans jamais toucher aux conteneurs.
Voir le README de `docsearch-api` pour le détail des routes `/admin/*`.

L'accès à `/admin.html` suppose une session **et** l'appartenance au
groupe `ADMIN_GROUP` : l'application redirige vers `/connexion` à défaut
de la première, et refuse en 403 à défaut de la seconde. Voir
[HOWTO-simuler-utilisateur.md](HOWTO-simuler-utilisateur.md) pour se
connecter, pour les comptes de secours quand l'annuaire est en panne, et
pour les harnais de recette. Pour la syntaxe des motifs glob des filtres
de sous-dossiers (liste noire/liste blanche), voir
[HOWTO-filtres-sous-dossiers.md](HOWTO-filtres-sous-dossiers.md).

## Nom de l'index Elasticsearch

`ES_INDEX` (défaut `documents`) doit être **identique** entre tous les
services — `docsearch-ingestion` (qui écrit) et `docsearch-api` (qui
lit) doivent pointer vers le même index, sinon l'API renverra
silencieusement zéro résultat alors que l'indexation semble fonctionner.
Toutes les unités lisent le même `EnvironmentFile` — il suffit donc de
définir `ES_INDEX` une seule fois par machine.

```bash
# /etc/docsearch/docsearch.env
ES_INDEX=documents_prod
```

⚠️ Changer cette valeur sur un environnement déjà en production ne
migre pas les données : le nouvel index démarre vide. Prévoir une
réindexation complète (`sudo ./manage.sh init`) après tout changement.

## Déploiement en production (réseau isolé)

La production n'a **aucun accès Internet**. L'application n'en a pas
besoin pour fonctionner, mais l'installation et les mises à jour, si :
les images tierces, les `pip install` / `npm ci` des Dockerfiles et les
`git pull` supposent tous un réseau. La procédure (machine de
préparation, `podman save`/`podman load`, paquets podman à transférer)
est décrite dans
[HOWTO-deploiement-hors-ligne.md](HOWTO-deploiement-hors-ligne.md).

Aucune construction n'a lieu au démarrage : `systemctl start` échoue
immédiatement si une image manque, sans jamais tenter d'atteindre le
réseau. Il n'y a donc rien à désactiver sur une machine isolée — seule
`./manage.sh build` demande un accès Internet, et ne se lance que sur la
machine de préparation.

## Supervision (Zabbix)

Les sondes des 8 machines de production et de l'application vivent dans
[zabbix/](zabbix/) : modèles à importer (Zabbix 7.0 LTS), scripts de
collecte, configuration de l'agent et script de déploiement par rôle.
Elles n'appellent rien à l'extérieur — `curl`, `openssl`, `awk`,
`systemctl` et `podman` sont déjà là, rien à vendoriser. Voir
[zabbix/README.md](zabbix/README.md), en commençant par l'ouverture du
port 10050 dans nftables : le jeu de règles du guide d'installation est
en `policy drop` et ne le liste pas.

## Stack technique

Elasticsearch 9.4.3 · Apache Tika 3.3.1.0 · Kafka 8.3 (KRaft, sans
Zookeeper) · Redis 7.2 · Nginx 1.27 · Python 3.12 · Elastic Open Web
Crawler 1.0.0.

Voir `guide_install_virtualbox.md` dans `docsearch-docs` pour une
installation pas à pas sur VM VirtualBox.
