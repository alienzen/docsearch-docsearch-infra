# HOWTO — Créer une source web

Une "source web" = un site externe crawlé par **Elastic Open Web
Crawler** (conteneur dédié, image
`docker.elastic.co/integrations/crawler`) vers un index Elasticsearch
**intermédiaire**, que `web_indexer.py` relit à intervalle régulier pour
le transformer vers le schéma DocSearch commun dans un index **final** —
voir `web_sources_config.py` (dupliqué à l'identique dans
`docsearch-ingestion/app/` et `docsearch-api/app/`, comme
`file_sources_config.py` et `sql_sources_config.py`).

⚠️ **Point à bien comprendre avant de commencer** : une source web
fonctionne en **deux étages totalement indépendants**, qui ne se
parlent qu'à travers le nom d'un index Elasticsearch partagé :

1. **Le crawl** — un conteneur Elastic Open Web Crawler, piloté par un
   fichier YAML (`docsearch-infra/crawlers/*.yml`), explore le site
   selon son propre planning (`schedule:`) et écrit les pages brutes
   dans un index ES intermédiaire (`output_index` côté crawler,
   `crawl_index` côté DocSearch).
2. **La synchronisation DocSearch** — `web_worker.py` relit
   périodiquement cet index intermédiaire et transforme son contenu
   vers le schéma DocSearch (`es_index`), qui rejoint l'alias de
   recherche fédérée.

Le registre DocSearch (Redis) **ne configure jamais** l'URL du site, la
profondeur de crawl ou les règles d'inclusion/exclusion — ça, c'est
uniquement dans le YAML du crawler. Le registre DocSearch ne fait que
déclarer le **lien** entre l'index de crawl et l'index final, plus
quelques métadonnées admin (libellé, description, ACL, cadence de
synchro). Confondre les deux est la source d'erreur la plus fréquente :
ajouter une source dans `manage.sh` sans avoir de crawler qui tourne en
face ne crawle rien ; démarrer un crawler sans enregistrer la source
correspondante laisse son contenu dans l'index intermédiaire, jamais
répercuté vers la recherche.

Conséquence pratique : **ajouter une nouvelle source web n'est pas une
seule commande**, contrairement à une source fichier. Il faut créer
trois choses, dans cet ordre :

1. un nouveau fichier YAML de config crawler ;
2. un nouveau service docker-compose pour faire tourner ce crawler ;
3. un enregistrement DocSearch (`manage.sh`, API ou UI admin) qui relie
   l'index de crawl à un index final.

## Prérequis

- Le stack DocSearch tourne (`./manage.sh start` ou `start-prod`) —
  `web-worker` doit être actif (il tourne par défaut, profils `dev` et
  `production`, aucune activation particulière requise).
- Connaître le domaine à crawler, ses éventuelles `sitemap_urls`, et les
  règles d'inclusion/exclusion souhaitées (`crawl_rules`).
- Avoir choisi deux noms d'index **distincts** : l'un pour le crawl brut
  (`crawl_index`), l'autre pour le résultat final DocSearch (`es_index`)
  — `add_source()` refuse une valeur identique pour les deux.

## Étape 1 : créer la config YAML du crawler

Un fichier par site, sous `docsearch-infra/crawlers/`. Modèle réel du
projet (`crawlers/cc-decisions.yml`), à copier et adapter :

```yaml
# crawlers/mon-site.yml
output_sink: elasticsearch
output_index: mon_site_raw          # = crawl_index, étape 3

domains:
  - url: https://www.mon-site.example
    sitemap_urls:
      - https://www.mon-site.example/sitemap.xml
    crawl_rules:
      - policy: allow
        type: begins
        pattern: /articles/
      - policy: deny
        type: begins
        pattern: /recherche/
      - policy: deny
        type: regex
        pattern: '.*\?f(\[|%5B).*'
      - policy: deny
        type: begins
        pattern: /

max_crawl_depth: 3
user_agent: "docsearch-crawler (contact: admin@example.com)"

schedule:
  pattern: "0 3 * * *"     # recrawl quotidien à 3h (syntaxe cron)

elasticsearch:
  host: http://es01-dev
  port: 9200
```

Points d'attention :

- `output_index` est le nom qui deviendra `crawl_index` à l'étape 3 —
  notez-le, il doit correspondre **exactement**.
- Les `crawl_rules` sont évaluées dans l'ordre ; terminer par un `deny`
  catch-all (`pattern: /`) est le pattern utilisé dans l'exemple existant
  du projet pour n'autoriser explicitement que les chemins voulus plutôt
  que de tout crawler par défaut.
- `elasticsearch.host` pointe vers le cluster ES du stack (nom du
  service Docker, pas `localhost`, puisque le crawler tourne dans son
  propre conteneur sur le réseau `docsearch-net`).
- `schedule.pattern` est **entièrement géré par le crawler lui-même** —
  DocSearch n'y touche pas ; c'est indépendant de
  `poll_interval_seconds` (étape 3), qui régit uniquement la cadence à
  laquelle DocSearch *relit* le résultat déjà présent dans l'index de
  crawl.

## Étape 2 : ajouter le service docker-compose et démarrer le crawler

Dans `docker-compose.yml`, dupliquer le service existant
`web-crawler-cc-decisions` (~ligne 446) en l'adaptant :

```yaml
  web-crawler-mon-site:
    image: docker.elastic.co/integrations/crawler:latest
    container_name: docsearch-web-crawler-mon-site
    profiles: ["dev", "production"]
    command: jruby bin/crawler schedule /config/mon-site.yml
    volumes:
      - ./crawlers:/config:ro
    networks:
      - docsearch-net
    restart: unless-stopped
```

Points d'attention :

- La commande est `schedule`, pas `crawl` — `crawl` ne fait qu'une seule
  passe puis s'arrête, `schedule` tourne en continu et respecte le
  `schedule:` cron déclaré dans le YAML.
- Le volume monte tout le dossier `./crawlers` (pas juste le fichier) en
  lecture seule — un seul volume suffit pour tous les crawlers du
  projet, chaque service pointe juste vers son propre fichier via
  `command`.
- Un site supplémentaire = un nouveau service du même genre : `schedule`
  ne gère qu'un seul fichier de config à la fois, donc pas de
  mutualisation possible entre plusieurs sites dans un même conteneur.

Puis démarrer (ou redémarrer) le stack pour que le nouveau service soit
créé :

```bash
cd docsearch-infra
docker compose up -d web-crawler-mon-site
```

⚠️ Contrairement à l'enregistrement de la source côté DocSearch (étape
3), **ceci nécessite bien de créer un nouveau conteneur** — ajouter un
service docker-compose n'est pas une opération à chaud.

## Étape 3 : enregistrer la source côté DocSearch

Trois méthodes, au même statut. Les champs correspondent à
`WebSource` (`web_sources_config.py`) : `name`, `crawl_index`,
`es_index`, `acl_public` (défaut `true`), `poll_interval_seconds`
(défaut 3600s, **minimum 30s**), `label`, `description`.

### a. Script `manage.sh` (le plus rapide)

```bash
cd docsearch-infra
./manage.sh add-web-source mon_site mon_site_raw mon_site --poll-interval 3600 --label "Mon site"
```

```text
Usage : ./manage.sh add-web-source <nom> <crawl_index> <index_es> [--poll-interval secondes] [--private] [--label <libellé>]
```

- `<crawl_index>` doit être **identique** à `output_index` dans le YAML
  du crawler (étape 1) — sinon `web_indexer.py` lira un index vide ou
  inexistant.
- `--private` marque les pages `acl.public=false` au lieu de `true`
  (public par défaut, adapté à un site accessible sans authentification
  — à réserver aux sites internes/intranet).

### b. Panneau admin "Sources web" (`admin.html`)

Formulaire : **nom**, **index de crawl** (`output_index` du crawler),
**index ES final**, case "Contenu public", **intervalle** (secondes,
défaut 3600), **libellé** et **description** (optionnels) — bouton
"Ajouter". Le tableau au-dessus liste les sources déjà enregistrées avec
boutons Suspendre/Reprendre, modifier libellé, modifier description,
Retirer.

### c. API directement

```bash
curl -X POST http://localhost:8000/admin/web-sources \
  -H "X-User: alice.admin" -H "Content-Type: application/json" \
  -d '{
    "name": "mon_site", "crawl_index": "mon_site_raw", "es_index": "mon_site",
    "acl_public": true, "poll_interval_seconds": 3600, "label": "Mon site"
  }'
```

Règles de validation (`web_sources_config.add_source()`), valables pour
les trois méthodes :

- **nom**, **crawl_index** et **es_index** : minuscules, chiffres,
  `-`/`_`, doivent commencer par une lettre/chiffre — jamais vides
  (même contrainte que fichiers/SQL).
- **`crawl_index` et `es_index` doivent être différents** — erreur
  explicite sinon (l'un reçoit le format brut du crawler, l'autre le
  schéma DocSearch transformé).
- **`es_index`** ne doit être utilisé par aucune autre source déjà
  enregistrée, **tous types confondus** (web, SQL, fichier) — un même
  index avec deux schémas incompatibles serait incohérent.
- **`poll_interval_seconds` >= 30** — évite de marteler l'index de crawl
  inutilement souvent (seuil plus bas que le SQL, 10s, car un crawl
  complet est typiquement bien plus lent qu'une requête SQL).

⚠️ Même piège que pour les sources fichiers et SQL : `add_source()`
**remplace entièrement** l'entrée si le nom existe déjà — l'API
`/admin/web-sources` relit `searchable`/`collectable` au préalable pour
ne pas les réinitialiser à `true`, mais un appel direct à `add_source()`
en script n'a pas ce filet, il faut repasser tous les champs.

La source est prise en compte par `web-worker` sous ~5s (cache local,
`WEB_SOURCES_CACHE_TTL`, défaut 10s), **sans redémarrage de conteneur**
— mais il attend `poll_interval_seconds` avant son tout premier passage
automatique. Voir étape 4 pour forcer un passage immédiat.

## Étape 4 : forcer une première synchro et vérifier

Pas besoin d'attendre `poll_interval_seconds` pour tester une source qui
vient d'être ajoutée — à condition que le crawler ait déjà terminé au
moins un passage (sinon `crawl_index` est vide ou inexistant) :

```bash
./manage.sh run-web-source mon_site
```

Déclenche immédiatement un passage complet
(`python web_indexer.py mon_site` dans le conteneur `indexer-init`).
Chaque passage (manuel ou automatique) fait **deux choses** en une seule
lecture de `crawl_index` :

1. **Upsert** de chaque page — jamais de "skip if exists" : le contenu
   d'une page peut changer sans que son URL (donc son identité) ne
   change.
2. **Réconciliation** : tout document présent dans `es_index` mais dont
   l'URL n'apparaît plus dans le dernier scan de `crawl_index` est
   supprimé (page disparue du site, ou purgée par le crawler lui-même
   lors d'un recrawl).

Vérifier :

```bash
./manage.sh list-web-sources
curl -s http://localhost:9200/mon_site/_count?pretty
```

Ou la vue unifiée (fusionne fichier/SQL/web, avec compte de documents et
taille sur disque) :

```bash
curl -H "X-User: alice.admin" http://localhost:8000/admin/all-sources | jq
```

⚠️ `./manage.sh status` / `GET /admin/status` ne couvrent que les
sources **fichiers** (le battement de `web-worker` est bien écrit dans
Redis, clé `docsearch:heartbeat:web_worker`, TTL 120s, mais il n'est pas
encore agrégé dans cette route) — utiliser `list-web-sources` ou
`/admin/all-sources` ci-dessus pour une source web.

Enfin, chercher une page du site fraîchement indexée directement dans
l'interface de recherche (`/search`) — les documents web rejoignent le
même alias fédéré que les sources fichiers et SQL (`ES_SEARCH_ALIAS`,
`docsearch-all` par défaut) et sont donc cherchables normalement, avec
le même filtrage ACL (`acl.public`, valeur fixée par `acl_public` de la
source à l'étape 3 — pas de gestion d'ACL fine par page).

## Opérations courantes

- **Suspendre / reprendre la synchro** : bouton "Suspendre" dans le
  panneau admin, ou `POST /admin/web-sources/{name}/pause`
  (`{"paused": true}`). Arrête uniquement la répercussion
  `crawl_index → es_index` (web-worker saute la source à chaque tick) —
  **n'arrête PAS le conteneur crawler**, qui continue de tourner et de
  peupler `crawl_index` selon son propre cron tant qu'il n'est pas
  arrêté séparément (`docker compose stop web-crawler-mon-site`). Les
  documents déjà dans `es_index` restent cherchables pendant la
  suspension.
- **Modifier le libellé** : `POST /admin/web-sources/{name}/label`, ou
  directement dans le tableau du panneau admin. Le nom (clé de registre,
  et champ `source` des documents déjà indexés) ne change jamais.
- **Modifier la description** : `POST /admin/web-sources/{name}/description`.
- **searchable / collectable** : panneau "Toutes les sources", ou
  `POST /admin/all-sources/{name}/{searchable,collectable}?type=web`.
  `searchable=false` retire la source de `/search` sans arrêter la
  synchro ; `collectable=false` bloque l'ajout à une collection sans
  effet sur la recherche.
- **Forcer un passage manuel** : `./manage.sh run-web-source <nom>` —
  utile après une modification de `crawl_rules` suivie d'un recrawl
  manuel, pour ne pas attendre `poll_interval_seconds`.
- **Changer `crawl_index`, `es_index` ou `poll_interval_seconds`** : pas
  de route dédiée — réappeler `add-web-source`/`POST /admin/web-sources`
  avec l'ensemble des champs (l'entrée est remplacée en entier, voir
  l'avertissement de l'étape 3).

## Retirer une source web

```bash
./manage.sh remove-web-source mon_site
```

Retire **uniquement** l'entrée du registre (`web-worker` arrête de la
synchroniser) — **ne supprime ni `crawl_index` ni `es_index`**, ni les
documents déjà indexés dans l'un ou l'autre. Pour nettoyer :

```bash
curl -X DELETE http://localhost:9200/mon_site_raw
curl -X DELETE http://localhost:9200/mon_site
```

Et si le site ne doit plus être crawlé du tout, arrêter et retirer aussi
le conteneur crawler :

```bash
docker compose stop web-crawler-mon-site
docker compose rm -f web-crawler-mon-site
```

(puis retirer le service de `docker-compose.yml` et le fichier YAML sous
`crawlers/` si le nettoyage doit être définitif).

## Dépannage

- **`Index de crawl 'xxx' introuvable`** (erreur explicite de
  `web_indexer.py`, levée plutôt que de traiter un index absent comme
  "0 page, tout supprimer") : le crawler n'a probablement jamais tourné
  pour ce site — vérifier `output_index` dans le YAML, et que le service
  docker-compose du crawler est bien démarré
  (`docker compose ps web-crawler-mon-site`, `docker compose logs
  web-crawler-mon-site`).
- **La source n'est jamais synchronisée automatiquement** : vérifier
  qu'elle n'est pas `paused` (`list-web-sources` ou panneau admin), et
  que `web-worker` tourne (`docker compose ps web-worker`). Un passage
  encore en cours au moment où l'intervalle suivant arrive est
  simplement sauté pour ce tick (jamais deux passages concurrents de la
  même source) — normal sur un très gros crawl, pas un bug.
- **Réconciliation refusée / des pages ne disparaissent pas alors
  qu'elles n'existent plus sur le site** : garde-fou intégré
  (`RECONCILE_MAX_DELETE_RATIO`) — un passage ne supprime jamais plus de
  50% d'un index `es_index` d'au moins 20 documents en une seule fois.
  Un `crawl_index` anormalement vide ou tronqué (crawler en échec,
  mauvaise config `output_index`, robots.txt bloquant soudainement tout)
  déclenche ce refus plutôt que de purger tout l'index DocSearch — un
  message d'erreur explicite apparaît dans les logs de `web-worker`
  (`docker compose logs web-worker`). Vérifier `crawl_index` avant toute
  purge manuelle.
- **`crawl_index` et `es_index` identiques** refusé à l'enregistrement
  (étape 3) — erreur de validation explicite, pas un crash silencieux
  plus tard.
- **Un index ES est déjà utilisé par une autre source** : erreur 400
  explicite à l'enregistrement — la vérification porte sur les trois
  registres (web, SQL, fichier), pas seulement sur les autres sources
  web.

## Voir aussi

- [HOWTO-creer-source-fichier.md](HOWTO-creer-source-fichier.md) —
  équivalent pour les sources fichiers
- [HOWTO-creer-source-sql.md](HOWTO-creer-source-sql.md) — équivalent
  pour les sources SQL
- [HOWTO-commandes-utiles.md](HOWTO-commandes-utiles.md) — démarrer,
  vérifier, rebuilder
