# HOWTO — Commandes utiles (démarrer, arrêter, rebuilder, vérifier)

Pense-bête des commandes d'exploitation courantes du stack DocSearch,
toutes lancées depuis `docsearch-infra`. La plupart passent par
`manage.sh` (voir son bloc `help` pour la liste complète), certaines
nécessitent `docker compose` directement — notamment le rebuild ciblé
d'un seul conteneur, que `manage.sh` ne fait pas.

## Démarrer / arrêter / redémarrer

```bash
./manage.sh start        # mode dev  : ES single-node, 1 worker — rebuild les images (--build)
./manage.sh start-prod   # mode prod : cluster ES 3 nœuds + Nginx — idem (--build)
./manage.sh stop         # arrête tout (dev ET prod)
./manage.sh restart      # down puis up -d EN MODE DEV, sans rebuild
```

⚠️ `restart` repasse toujours en profil **dev**, même si le stack
tournait en `start-prod` — et ne rebuild rien (`up -d` sans `--build`).
Après une modification de code, `restart` seul ne suffit pas : voir
"Rebuilder un conteneur" ci-dessous, ou relancer `start`/`start-prod`
qui rebuildent automatiquement (mais redémarrent TOUT le stack, plus
lourd qu'un rebuild ciblé).

```bash
./manage.sh reset        # ⚠️ down -v : supprime TOUTES les données (irréversible, confirmation "oui" requise)
./manage.sh backup       # snapshot Elasticsearch dans ./backups/<date>/
```

## Vérifier que tout fonctionne

### Vue d'ensemble rapide

```bash
./manage.sh status
```

Affiche `docker compose ps` (état de chaque conteneur), la santé
Elasticsearch (`_cluster/health`), et le nombre total de documents
indexés (alias `ES_SEARCH_ALIAS`, toutes sources confondues).

### Vue détaillée (composant par composant)

```bash
curl -H "X-User: alice.admin" http://localhost:8000/admin/status | jq
```

Correspond à `cluster_status.get_full_status()` — vérifie, sans accès
au socket Docker (uniquement via le réseau applicatif, comme n'importe
quel client) :

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
docker compose ps    # état + healthcheck (healthy/unhealthy) de chaque conteneur
```

Deux services ont un healthcheck HTTP natif consultable directement :

```bash
curl -sf http://localhost:9200/_cluster/health?pretty   # es01-dev
curl -sf http://localhost:8000/health                   # api
```

### Vérifier dans le navigateur

⚠️ Depuis l'outil `claude-in-chrome`, utiliser l'IP LAN de la VM
(`http://192.168.56.101:8090/` pour le proxy dev-user, `:8080` pour
l'UI directe, `:5601` pour Kibana) — jamais `localhost`, qui côté
navigateur ne route pas vers le réseau Docker de la VM. `curl` depuis
l'environnement shell n'est pas concerné, `localhost` y fonctionne
normalement.

## Consulter les logs

Services notables : `api`, `ui`, `worker` (réplicas, voir
`scale-workers`), `watcher`, `sql-worker`, `web-worker`,
`web-crawler-cc-decisions`, `alert-worker`, `es01-dev` (dev) /
`es01`/`es02`/`es03` (prod), `kibana`, `kafka`, `redis`, `tika1..4`,
`nginx` (prod uniquement).

### Via `manage.sh`

```bash
./manage.sh logs           # tous les services (profil dev), temps réel
./manage.sh logs worker    # un seul service, temps réel
./manage.sh logs watcher
```

⚠️ `./manage.sh logs` **sans argument** n'active que le profil `dev`
(voir son implémentation : `--profile dev logs -f`, pas `production`)
— en mode `start-prod`, ça exclut `nginx`, `es01`, `es02`, `es03`
(services `profiles: ["production"]` uniquement). Avec un nom de
service explicite, les deux profils sont activés
(`--profile dev --profile production logs -f <service>`), donc ce
cas-là fonctionne quel que soit le mode démarré. Pour tout tailer en
mode prod, passer par `docker compose` directement (ci-dessous).

### Via `docker compose` directement

Plus de contrôle (limite de lignes, historique, plusieurs services à
la fois) :

```bash
docker compose --profile production logs -f              # tous les services, mode prod
docker compose logs -f --tail 100 api                     # dernières 100 lignes puis suivi
docker compose logs -f -t worker                          # avec horodatage (-t)
docker compose logs --since 30m watcher                   # seulement les 30 dernières minutes
docker compose logs -f api ui                              # plusieurs services entrelacés
docker compose logs worker | grep -i error                # filtrer sans suivi (pas de -f)
```

### Un seul réplica parmi plusieurs (`worker`)

`worker` tourne en plusieurs réplicas (pas de `container_name` fixe,
incompatible avec `replicas` > 1) — `docker compose logs worker`
entrelace déjà les logs de tous les réplicas, préfixés par leur nom de
conteneur. Pour cibler un seul réplica :

```bash
docker compose ps worker                  # liste les noms réels (ex: docsearch-infra-worker-1, -2, -3, -4)
docker logs -f docsearch-infra-worker-2   # logs de ce seul réplica
```

### `docker logs` direct (sans `docker compose`, par nom de conteneur)

Les services à instance unique ont un `container_name` fixe
(`docker-compose.yml`) — utilisable avec `docker logs` même hors du
dossier `docsearch-infra` :

```bash
docker logs -f docsearch-api
docker logs -f docsearch-watcher
docker logs --tail 200 docsearch-es01
```

## Commandes Redis de base

Redis stocke toute la configuration dynamique (sources fichier/SQL/web,
filtres, réglages runtime/UI) ainsi que les battements de vie des
workers — **pas de mot de passe** (`docker-compose.yml`, service
`redis`, container `docsearch-redis`, port `6379` exposé sur l'hôte).

```bash
docker exec -it docsearch-redis redis-cli        # shell interactif, depuis le conteneur
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

⚠️ Ne pas confondre avec `./manage.sh reset`, qui fait un `docker
compose down -v` et supprime **tout** le volume `redis_data` (ainsi que
les autres volumes) — pour ne vider que Redis :

```bash
redis-cli FLUSHDB     # ⚠️ supprime TOUTE la config dynamique (sources, filtres, runtime...) — irréversible, pas de confirmation demandée
```

### Surveiller en direct

```bash
redis-cli MONITOR              # ⚠️ trace CHAQUE commande reçue par Redis en temps réel — usage ponctuel de dépannage seulement, impact perf notable sous charge
redis-cli INFO memory | grep used_memory_human   # mémoire utilisée (maxmemory 512mb, policy allkeys-lru — éviction silencieuse au-delà)
```

## Rebuilder un conteneur

Le code de `docsearch-api`, `docsearch-ingestion` et `docsearch-ui` est
copié DANS l'image au build (pas de bind-mount, pas de `--reload`) —
modifier un fichier sur disque n'a aucun effet tant que l'image n'est
pas reconstruite et le conteneur recréé :

```bash
docker compose --profile dev build <service>
docker compose --profile dev up -d <service>
```

En production, remplacer `dev` par `production`.

Exemple concret (UI) :

```bash
docker compose --profile dev build ui
docker compose --profile dev up -d ui
```

⚠️ Chaque service a sa **propre image**, même quand plusieurs partagent
le même contexte de build — reconstruire `worker` ne met PAS à jour
`watcher`/`sql-worker`/`web-worker`/`indexer-init` (tous construits
depuis `docsearch-ingestion`). Après une modif dans `docsearch-ingestion`,
rebuilder chaque service concerné explicitement :

```bash
docker compose --profile dev build worker watcher sql-worker web-worker
docker compose --profile dev up -d worker watcher sql-worker web-worker
```

Modif dans `docsearch-api` → rebuild `api` ET `alert-worker` (même
image, code partagé, voir leurs blocs `build:` dans
`docker-compose.yml`).

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
docker exec docsearch-api python3 backfill_groups.py
```

Cette première commande ne fait que simuler. Relancer avec `--apply`
pour écrire :

```bash
docker exec docsearch-api python3 backfill_groups.py --apply
```

⚠️ Le script applique l'appartenance LDAP **d'aujourd'hui** à des
événements passés — l'inverse de la capture normale. À réserver à
l'amorçage des statistiques, jamais en tâche planifiée. Il ne touche
que les documents dépourvus de `groups` et laisse les suggestions
anonymes intactes. Détail dans `docsearch-api/README.md`, section
« Statistiques par groupe d'utilisateurs ».

## Ajuster la charge

```bash
./manage.sh scale-workers 12   # recommandé en production à fort volume (voir docker-compose.yml : 4 par défaut)
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
