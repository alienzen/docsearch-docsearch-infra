# HOWTO — Commandes utiles (démarrer, arrêter, rebuilder, vérifier)

Pense-bête des commandes d'exploitation courantes de DocSearch, toutes
lancées depuis `docsearch-infra`. Les services sont des **unités systemd**
générées par Quadlet (voir [quadlet/README.md](quadlet/README.md)) : la
plupart des commandes passent par `manage.sh`, les autres par `systemctl`
et `podman` directement.

**Ce qui demande `sudo`** — les unités, le réseau, les images et
`/etc/docsearch/*.env` appartiennent à root (podman rootful) :

| Sans sudo | Avec sudo |
|---|---|
| `status`, `logs`, `build`, `backup`, `get-config`, `get-filetypes`, `list-*` | `start`, `stop`, `restart`, `reset`, `init`, `scale-workers`, `dev-user`, et tout ce qui modifie une source ou la configuration (`add-*`, `remove-*`, `run-*`, `set-*`, `*-path`) |

Sans `sudo`, les commandes de la seconde colonne refusent avec un
message explicite. `manage.sh status` fonctionne sans privilège mais
signale que `/etc/docsearch/docsearch.env` (mode `0600`, il porte le mot
de passe LDAP) lui est illisible : il retombe alors sur les valeurs par
défaut, ce qui n'affecte que l'affichage.

En cas de panne au démarrage, voir la section **Dépannage** de
[quadlet/README.md](quadlet/README.md) : elle couvre les quatre causes
réellement rencontrées (sous-réseau occupé, image absente du magasin de
root, unités abandonnées par systemd, configuration non prise en compte).

## Démarrer / arrêter / redémarrer

```bash
sudo ./manage.sh start      # démarre docsearch.target (toutes les unités de la machine)
sudo ./manage.sh stop       # arrête la pile
sudo ./manage.sh restart    # redémarre la pile
```

Équivalents systemd directs, utiles pour un seul service :

```bash
sudo systemctl start   docsearch.target        # toute la pile
sudo systemctl restart docsearch-api           # un seul service
sudo systemctl status  docsearch-worker-1      # état détaillé + dernières lignes de journal
systemctl list-units 'docsearch-*'             # tout ce qui tourne
```

⚠️ Il n'y a plus de `start-prod` : ce qu'une machine démarre dépend des
unités qui y sont installées (`quadlet/install-units.sh <rôle>`), pas
d'une option au démarrage. Un `restart` ne reconstruit **jamais** les
images : après une modification de code, voir "Reconstruire une image"
plus bas.

Les unités portent `Restart=always` et sont tirées par `docsearch.target`,
lui-même activé au boot (`systemctl enable docsearch.target`, fait par
l'installateur) : un redémarrage machine remonte la pile sans intervention.

```bash
sudo ./manage.sh reset   # ⚠️ arrête tout et supprime les volumes (irréversible, confirmation "oui")
./manage.sh backup       # snapshot Elasticsearch dans ./backups/<date>/
```

## Vérifier que tout fonctionne

### Vue d'ensemble rapide

```bash
./manage.sh status
```

Affiche l'état des unités (`systemctl list-units 'docsearch-*'`), la
santé Elasticsearch (`_cluster/health`), et le nombre total de documents
indexés (alias `ES_SEARCH_ALIAS`, toutes sources confondues).

### Vue détaillée (composant par composant)

```bash
curl -H "X-User: alice.admin" http://localhost:8000/admin/status | jq
```

Correspond à `cluster_status.get_full_status()` — vérifie, sans accès à
la socket du moteur de conteneurs (uniquement via le réseau applicatif,
comme n'importe quel client) :

- **Elasticsearch** : up/down, statut du cluster (`green`/`yellow`/`red`)
- **Redis** : up/down
- **Tika** (×4) : up/down par instance
- **Kafka** : broker joignable
- **Workers actifs + lag** : déduits du groupe de consumers Kafka
  `indexer-workers` — le lag (messages publiés non encore traités)
  donne directement la progression d'une indexation en cours
- **Battement du watcher** (`docsearch:heartbeat:watcher` dans Redis) :
  considéré silencieux au-delà de 60s sans battement
- **Sources** : nombre de documents indexé par source (voir aussi
  `./manage.sh list-file-sources` / `list-sql-sources` / `list-web-sources`)

Voir `docsearch-api/app/cluster_status.py` pour le détail de chaque
vérification.

### État des conteneurs

```bash
systemctl list-units 'docsearch-*'                  # état vu par systemd
podman ps --format '{{.Names}}\t{{.Status}}'        # état + healthcheck (healthy/unhealthy)
podman healthcheck run docsearch-es01               # forcer une vérification immédiate
```

⚠️ En rootful, ces commandes `podman` s'exécutent avec `sudo` : les
conteneurs appartiennent à root, un `podman ps` en tant qu'utilisateur
ordinaire interroge un magasin d'images vide et n'affiche rien.

Deux services ont un healthcheck HTTP natif consultable directement :

```bash
curl -sf http://localhost:9200/_cluster/health?pretty   # es01-dev
curl -sf http://localhost:8000/health                   # api
```

### Vérifier dans le navigateur

⚠️ Depuis l'outil `claude-in-chrome`, utiliser l'IP LAN de la VM
(`http://192.168.56.101:8090/` pour le proxy dev-user, `:8080` pour
l'UI directe, `:5601` pour Kibana) — jamais `localhost`, qui côté
navigateur ne route pas vers le réseau de conteneurs de la VM. `curl`
depuis l'environnement shell n'est pas concerné, `localhost` y
fonctionne normalement.

## Consulter les journaux

Tout passe par **journald** : les conteneurs n'ont plus de journal
séparé, chaque unité écrit dans le journal système. Un service = une
unité `docsearch-<nom>.service`.

Unités notables : `docsearch-api`, `docsearch-ui-vue`,
`docsearch-worker-1..N`, `docsearch-watcher`, `docsearch-sql-worker`,
`docsearch-web-worker`, `docsearch-web-crawler-cc-decisions`,
`docsearch-alert-worker`, `docsearch-es01` (mono-hôte) / `docsearch-es`
(nœud de production), `docsearch-kibana`, `docsearch-kafka`,
`docsearch-redis`, `docsearch-tika1..4`, `docsearch-nginx`.

### Via `manage.sh`

```bash
./manage.sh logs           # toutes les unités DocSearch, temps réel
./manage.sh logs worker    # TOUTES les unités worker à la fois
./manage.sh logs watcher   # une unité précise
```

Contrairement à la version Compose, `logs` sans argument suit bien
**toutes** les unités de la machine, quel que soit son rôle : il n'y a
plus de profil à activer.

### Via `journalctl` directement

Plus de contrôle (limite de lignes, historique, plusieurs unités) :

```bash
journalctl -u docsearch-api -f                    # suivi temps réel
journalctl -u docsearch-api -n 100 -f             # 100 dernières lignes puis suivi
journalctl -u 'docsearch-worker-*' --since -30m   # les 30 dernières minutes, tous les workers
journalctl -u docsearch-api -u docsearch-ui-vue -f  # plusieurs unités entrelacées
journalctl -u 'docsearch-*' -p err                # seulement les erreurs
journalctl -u docsearch-worker-1 | grep -i error  # filtrer sans suivi
journalctl -u docsearch-es01 -b                   # depuis le dernier démarrage machine
```

L'horodatage est natif (plus besoin d'un `-t`), et l'historique survit
au redémarrage d'un conteneur — un journal n'est plus perdu quand
l'unité est recréée.

### Un seul worker parmi plusieurs

Chaque worker est une unité distincte (`docsearch-worker-1`,
`docsearch-worker-2`…), donc adressable directement — c'est plus simple
que les réplicas Compose, qui n'avaient pas de nom stable :

```bash
systemctl list-units 'docsearch-worker-*'   # lister les workers actifs
journalctl -u docsearch-worker-2 -f         # journal d'un seul worker
sudo systemctl restart docsearch-worker-2   # redémarrer un seul worker
```

## Commandes Redis de base

Redis stocke toute la configuration dynamique (sources fichier/SQL/web,
filtres, réglages runtime/UI) ainsi que les battements de vie des
workers — **pas de mot de passe** (unité `docsearch-redis.container`,
conteneur `docsearch-redis`, port `6379` publié sur l'hôte).

```bash
sudo podman exec -it docsearch-redis redis-cli   # shell interactif, depuis le conteneur
redis-cli -h localhost -p 6379                   # équivalent depuis l'hôte, si redis-cli est installé localement
```

### Explorer les clés

```bash
redis-cli KEYS 'docsearch:*'          # ⚠️ KEYS bloque le serveur le temps du scan — OK en dev, à éviter en prod sur une grosse base
redis-cli --scan --pattern 'docsearch:config:*'   # équivalent non bloquant (SCAN itératif), à préférer en prod
redis-cli TYPE docsearch:config:web_sources        # type de la clé (string, hash, list...)
```

Espaces de noms notables :

- `docsearch:config:*` — configuration dynamique lue à chaud par
  l'API/l'ingestion (`file_sources`, `sql_sources`, `web_sources`,
  `sql_dsns`, `pathfilters`, `filetypes`, `runtime`, `ui`,
  `engagement`...). Modifiable en direct via `redis-cli`, mais préférer
  `manage.sh` ou l'API admin qui appliquent la validation applicative.
- `docsearch:heartbeat:*` — battements de vie (`watcher`,
  `sql_worker`, `web_worker`), consultés par `/admin/status` ; une clé
  absente ou expirée signale un composant silencieux.

### Lire une valeur

```bash
redis-cli GET docsearch:config:web_sources | jq     # valeur JSON brute (la plupart des clés config sont des strings JSON)
redis-cli GET docsearch:heartbeat:web_worker         # timestamp du dernier battement
redis-cli TTL docsearch:heartbeat:web_worker          # secondes avant expiration (120s pour web_worker)
```

### Écrire / supprimer (à réserver au dépannage — préférer `manage.sh`/l'API)

```bash
redis-cli DEL docsearch:heartbeat:web_worker    # force l'état "silencieux" vu par /admin/status (utile pour tester une alerte)
redis-cli SET <clé> '<json>'                    # ⚠️ écrase toute validation applicative — vérifier le format attendu avant
```

⚠️ Ne pas confondre avec `sudo ./manage.sh reset`, qui arrête la pile et
supprime **tous** les volumes podman, dont celui de Redis — pour ne
vider que Redis :

```bash
redis-cli FLUSHDB     # ⚠️ supprime TOUTE la config dynamique (sources, filtres, runtime...) — irréversible, pas de confirmation demandée
```

### Surveiller en direct

```bash
redis-cli MONITOR              # ⚠️ trace CHAQUE commande reçue par Redis en temps réel — usage ponctuel de dépannage seulement, impact perf notable sous charge
redis-cli INFO memory | grep used_memory_human   # mémoire utilisée (maxmemory 512mb, policy allkeys-lru — éviction silencieuse au-delà)
```

## Reconstruire une image

Le code de `docsearch-api`, `docsearch-ingestion` et `docsearch-ui-vue`
est copié DANS l'image à la construction (pas de bind-mount, pas de
`--reload`) — modifier un fichier sur disque n'a aucun effet tant que
l'image n'est pas reconstruite et l'unité redémarrée :

```bash
./manage.sh build ingestion              # ou : api, ui, all
sudo systemctl restart docsearch.target  # recrée les conteneurs sur la nouvelle image
```

⚠️ Une machine **isolée du réseau** ne peut rien construire (`apt-get`,
`pip install`, `npm ci` dans les Dockerfiles) : les images y arrivent
par `podman load`, voir
[HOWTO-deploiement-hors-ligne.md](HOWTO-deploiement-hors-ligne.md).

Il n'y a plus qu'**une image par dépôt**, et non plus une par service :
c'est le principal gain par rapport à Compose. Une seule construction de
`localhost/docsearch/ingestion:latest` met à jour d'un coup les workers,
le watcher, le worker SQL, le worker web et les commandes
d'administration de `manage.sh`. Il reste à redémarrer les unités qui
l'utilisent :

```bash
./manage.sh build ingestion
sudo systemctl restart 'docsearch-worker-*' docsearch-watcher docsearch-sql-worker docsearch-web-worker
```

De même, `localhost/docsearch/api:latest` sert à `docsearch-api` **et**
à `docsearch-alert-worker`.

⚠️ **Cache navigateur pour l'UI** : après rebuild de `ui`, le navigateur
peut continuer à servir un `theme-search.css` périmé (pas de
`Cache-Control`, Chrome saute la revalidation). Un rechargement de page
cache-busté (`?nocache=1`) ne suffit pas — il faut forcer le
sous-ressource CSS spécifiquement :

```js
const link = document.querySelector('link[href="/theme-search.css"]');
const fresh = link.cloneNode();
fresh.href = '/theme-search.css?bust=' + Date.now();
link.replaceWith(fresh);
```

Signe qu'on est dans ce cas plutôt que face à un vrai bug CSS :
`getComputedStyle(document.documentElement).getPropertyValue('--un-token-ajouté')`
renvoie `""` juste après un rebuild.

## Rétro-remplir les groupes des journaux

Les statistiques par groupe reposent sur un champ `groups` écrit au
moment de chaque recherche/avis/suggestion. Les enregistrements
antérieurs à cet ajout n'en ont pas et forment un lot « Non renseigné »
qui écrase les autres. Pour les compléter depuis LDAP, **une fois** :

```bash
sudo podman exec docsearch-api python3 backfill_groups.py
```

Cette première commande ne fait que simuler. Relancer avec `--apply`
pour écrire :

```bash
sudo podman exec docsearch-api python3 backfill_groups.py --apply
```

⚠️ Le script applique l'appartenance LDAP **d'aujourd'hui** à des
événements passés — l'inverse de la capture normale. À réserver à
l'amorçage des statistiques, jamais en tâche planifiée. Il ne touche
que les documents dépourvus de `groups` et laisse les suggestions
anonymes intactes. Détail dans `docsearch-api/README.md`, section
« Statistiques par groupe d'utilisateurs ».

## Ajuster la charge

```bash
sudo ./manage.sh scale-workers 12   # recommandé à fort volume (4 unités par défaut en mono-hôte, 3 par machine d'ingestion)
```

## Voir aussi

- [HOWTO-creer-source-fichier.md](HOWTO-creer-source-fichier.md) —
  créer/gérer une source d'indexation fichier
- [HOWTO-creer-source-sql.md](HOWTO-creer-source-sql.md) —
  créer/gérer une source d'indexation SQL
- [HOWTO-creer-source-web.md](HOWTO-creer-source-web.md) —
  créer/gérer une source d'indexation web (crawl)
- [HOWTO-filtres-sous-dossiers.md](HOWTO-filtres-sous-dossiers.md) —
  motifs glob d'inclusion/exclusion par source
- [HOWTO-simuler-utilisateur.md](HOWTO-simuler-utilisateur.md) —
  fournir `X-User` sans SSO (nécessaire pour `/admin/*`)
