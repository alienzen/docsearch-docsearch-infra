# HOWTO — Créer une source SQL

Une "source SQL" = le résultat d'une requête `SELECT` (PostgreSQL ou
MySQL) indexé dans son propre index Elasticsearch, une ligne = un
document — voir `sql_sources_config.py` (dupliqué à l'identique dans
`docsearch-ingestion/app/` et `docsearch-api/app/`). Contrairement à une
source fichier, il n'y a ni dossier ni watcher événementiel : `sql_worker.py`
relit **intégralement** la requête à chaque passage (upsert de chaque
ligne + réconciliation, voir étape 4). Pas de source par défaut non plus
— une installation sans source SQL enregistrée n'en traite simplement
aucune.

## 1. Préparer la connexion (`connection_ref`)

`connection_ref` est toujours un **nom**, jamais le DSN lui-même — le
mot de passe ne doit jamais transiter par Redis. Deux méthodes,
interchangeables, au même statut (aucune dépréciée) :

### Méthode 1 — variable d'environnement (historique)

```bash
# /etc/docsearch/docsearch.env
CLIENTS_DB_DSN=postgresql+psycopg2://user:motdepasse@host:5432/dbname
FACTURES_DB_DSN=mysql+pymysql://user:motdepasse@host:3306/dbname
```

Nécessite `sudo systemctl restart docsearch-sql-worker` pour prendre
effet (nouvelle variable dans `/etc/docsearch/docsearch.env` = conteneur
à recréer).

### Méthode 2 — DSN chiffré via le panneau admin (dynamique, sans redémarrage)

> Les commandes `/admin/*` ci-dessous exigent une session : ouvrir un
> bocal à cookies une fois pour toutes, voir « S'authentifier pour les
> commandes d'administration » dans
> [HOWTO-commandes-utiles.md](HOWTO-commandes-utiles.md).

```bash
curl -X POST http://localhost:8000/admin/sql-dsns \
  -b ~/.docsearch-cookies -H "Content-Type: application/json" \
  -d '{"name": "CLIENTS_PG_DSN", "dsn": "postgresql+psycopg2://user:motdepasse@host:5432/dbname"}'
```

Ou dans l'admin UI : panneau "Sources SQL" > section "DSN chiffrés".
Le DSN est chiffré (Fernet) avant stockage dans Redis — jamais réexposé
en clair après coup (seul un indice schéma+hôte reste consultable via
`GET /admin/sql-dsns`). Nécessite `DSN_ENCRYPTION_KEY` (identique côté
`docsearch-api` ET `docsearch-ingestion` — une seule clé dans
`/etc/docsearch/docsearch.env`, que toutes les unités lisent) :

```bash
python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
# → coller dans DSN_ENCRYPTION_KEY= (/etc/docsearch/docsearch.env), puis :
#   sudo systemctl restart docsearch.target
```

Pas de raccourci `manage.sh` pour cette méthode — uniquement API/admin UI.

⚠️ **Priorité** : si une variable d'environnement du même nom existe
(méthode 1), elle est **toujours** prioritaire sur un DSN dynamique du
même nom (méthode 2) — voir `sql_indexer._resolve_dsn()`.

Dans les deux cas : préférer un compte SQL **en lecture seule**,
restreint à la ou aux tables interrogées.

## 2. Écrire la requête et le mapping colonnes → champs ES

Chaque colonne à indexer doit apparaître dans `fields`, sous la forme
`{"column": ..., "es_field": ..., "es_type": ...}` :

| `es_type` possible | Remarque |
|---|---|
| `keyword` | valeur exacte, facettable |
| `text` | plein texte ; seul type acceptant `"analyzer"` (ex. `french`) |
| `long`, `double` | numérique |
| `date` | — |
| `boolean` | facettable |

- `id_column` doit obligatoirement figurer dans `fields` (sert de
  `_id` du document ES — c'est ce qui permet l'upsert et la
  réconciliation, voir étape 4).
- `"facet": true` n'est accepté que pour `keyword`/`boolean` (une
  agrégation `terms` sur `text` échouerait, faute de `doc_values`) —
  ajoute une section de filtre dans la sidebar de recherche
  (`facet_label` optionnel pour le titre affiché, sinon le nom du
  champ ES est utilisé tel quel).
- **Un même `es_field` ne peut apparaître qu'une fois.** Deux colonnes
  envoyées vers le même champ sont désormais refusées à l'enregistrement,
  avec le nom des deux colonnes fautives. La règle n'est pas cosmétique :
  le mapping d'index comme le document sont construits par écrasement
  successif, donc le dernier mappage gagnait — mais seulement à la
  création de l'index, Elasticsearch refusant ensuite de changer le type
  d'un champ existant. Le contrôle de facette ci-dessus devenait alors un
  mensonge, validant le type *déclaré* pendant que l'agrégation frappait
  le type *réel* : c'est ce qui a mis la recherche fédérée à zéro
  résultat le 2026-08-13, une source déclarant `titre → title (text)`
  puis `titre → title (keyword, facette)`.

  ⚠️ Le contrôle porte sur les **nouvelles** écritures. Une source
  enregistrée avant lui garde son mapping en double : la corriger demande
  de supprimer le mappage inutile **et** de recréer l'index, le type d'un
  champ déjà en place ne se changeant pas.

- **Ajouter une colonne à une source déjà indexée** ne demande pas de
  recréer l'index : le mapping est réappliqué à chaque passage, donc le
  champ nouveau est déclaré avant le premier document qui le porte
  (ajouter un champ est additif — pas de réindexation, aucune donnée
  touchée). Jusqu'au 2026-08-14 le mapping n'était posé qu'à la création
  de l'index : la colonne ajoutée n'était jamais déclarée, Elasticsearch
  la mappait dynamiquement en `text`, et une facette déclarée `keyword`
  dessus passait le contrôle ci-dessus — qui valide le type *déclaré* —
  pour échouer ensuite à l'agrégation, shard en échec et recherche
  fédérée refusée.

  ⚠️ **Changer le type d'un champ déjà mappé reste impossible** :
  Elasticsearch refuse alors la requête entière, y compris les autres
  champs qu'elle porte. Le conflit est **journalisé, pas levé** —
  `journalctl -u docsearch-sql-worker`, le nom du champ fautif y figure —
  car cette pose de mapping ouvre chaque passage : lever y arrêterait
  toute l'indexation de la source jusqu'à intervention. Conséquence : un
  type corrigé dans le formulaire n'a **aucun effet visible** tant que
  l'index n'est pas recréé, ou la source pointée vers un nouvel
  `es_index`. Une source SQL étant intégralement reconstruite au passage
  suivant, rien n'est perdu.

- Le mapping est `"dynamic": "strict"` : un document portant un champ non
  déclaré échoue à l'indexation au lieu d'être mappé au jugé. En
  fonctionnement normal aucun document n'est concerné — une ligne SQL ne
  porte que les champs déclarés, plus `source` et `indexed_at`.

Exemple de mapping :

```json
[
  {"column": "id",    "es_field": "id",    "es_type": "keyword"},
  {"column": "nom",   "es_field": "nom",   "es_type": "text", "analyzer": "french"},
  {"column": "email", "es_field": "email", "es_type": "keyword"},
  {"column": "actif", "es_field": "actif", "es_type": "boolean", "facet": true, "facet_label": "Actif"}
]
```

## 3. Enregistrer la source

### a. Script `manage.sh`

```bash
cd docsearch-infra
sudo ./manage.sh add-sql-source clients postgresql CLIENTS_DB_DSN \
  "SELECT id, nom, email, actif FROM clients WHERE actif = true" id clients_sql \
  '[{"column":"id","es_field":"id","es_type":"keyword"},
    {"column":"nom","es_field":"nom","es_type":"text","analyzer":"french"},
    {"column":"email","es_field":"email","es_type":"keyword"},
    {"column":"actif","es_field":"actif","es_type":"boolean","facet":true,"facet_label":"Actif"}]' \
  --poll-interval 300 --label Clients
```

```text
Usage : sudo ./manage.sh add-sql-source <nom> <postgresql|mysql> <connection_ref> <requête_sql> <id_column> <index_es> <fields_json> [--poll-interval secondes] [--label <libellé>]
```

### b. Panneau admin "Sources SQL" (`admin.html`)

Formulaire complet : nom, type de base, `connection_ref` (autocomplété
avec les DSN dynamiques déjà enregistrés), index ES, colonne ID,
intervalle de polling, libellé/description, requête SQL (zone de
texte), puis le tableau de mapping colonnes → champs ES ligne par
ligne (bouton "+ Ajouter une colonne") — plus besoin d'écrire le JSON
du mapping à la main. Le même formulaire sert à la création et à la
modification d'une source existante.

Une ligne de mapping **à moitié remplie** (colonne SQL ou champ ES
manquant) bloque l'enregistrement et est désignée par son numéro ; une
ligne entièrement vide reste ignorée. Auparavant la ligne incomplète
était écartée en silence : l'API répondait 200, le formulaire se
fermait, et la colonne saisie avait disparu sans un mot.

### c. API directement

```bash
curl -X POST http://localhost:8000/admin/sql-sources \
  -b ~/.docsearch-cookies -H "Content-Type: application/json" \
  -d '{
    "name": "clients", "db_type": "postgresql", "connection_ref": "CLIENTS_DB_DSN",
    "query": "SELECT id, nom, email, actif FROM clients WHERE actif = true",
    "id_column": "id", "es_index": "clients_sql",
    "fields": [
      {"column": "id", "es_field": "id", "es_type": "keyword"},
      {"column": "nom", "es_field": "nom", "es_type": "text", "analyzer": "french"},
      {"column": "email", "es_field": "email", "es_type": "keyword"},
      {"column": "actif", "es_field": "actif", "es_type": "boolean", "facet": true, "facet_label": "Actif"}
    ],
    "poll_interval_seconds": 300, "label": "Clients"
  }'
```

Règles de validation (`sql_sources_config.add_source()`), valables
pour les trois méthodes :

- **nom** et **index ES** : mêmes contraintes que les sources fichiers
  (minuscules, chiffres, `-`/`_`, jamais vide).
- **index ES** : ne doit être utilisé par aucune autre source SQL **ni
  par aucune source fichier** (un même index avec deux mappings
  incompatibles serait incohérent) — erreur 400 sinon.
- **`poll_interval_seconds` >= 10** — évite de marteler la base.
- `db_type` doit correspondre au préfixe réel du DSN résolu
  (`postgresql://`/`postgresql+...` ou `mysql://`/`mysql+...`),
  vérifié avant même de tenter la connexion.

⚠️ Même piège que pour les sources fichiers : `add_source()`
**remplace entièrement** l'entrée si le nom existe déjà — modifier une
source existante en ligne de commande nécessite de retransmettre
`fields`/`poll_interval_seconds`/etc. en entier (l'API relit
`searchable`/`collectable` au préalable pour ne pas les réinitialiser,
mais rien d'autre).

La source est prise en compte par `sql-worker` sous ~10s
(`SQL_SOURCES_CACHE_TTL`), sans redémarrage.

## 4. Déclencher un premier passage

Pas besoin d'attendre `poll_interval_seconds` pour tester une source
qui vient d'être ajoutée :

```bash
sudo ./manage.sh run-sql-source clients
```

Chaque passage (manuel ou automatique) fait **deux choses** en une
seule lecture de la requête (`sql_indexer.py`) :

1. **Upsert** de chaque ligne — jamais de "skip if exists" : contrairement
   à un fichier, une ligne SQL peut changer de contenu sans changer
   d'identité (`id_column`).
2. **Réconciliation** : tout `_id` présent dans l'index ES mais absent
   du nouveau résultat est supprimé (ligne supprimée côté SQL depuis le
   dernier passage).

⚠️ Garde-fou intégré : un passage ne supprime jamais plus de la moitié
d'un index déjà significatif — un résultat vide ou tronqué (DSN cassé,
permissions révoquées, requête qui échoue silencieusement côté driver)
ne purge donc jamais tout un index d'un coup.

## 5. Vérifier

```bash
sudo ./manage.sh list-sql-sources
curl -s http://localhost:9200/clients_sql/_count?pretty
```

⚠️ `./manage.sh status` / `GET /admin/status` ne couvrent que les
sources **fichiers** (`_sources_status()` ne boucle que sur
`file_sources_config`). Pour voir le nombre de documents d'une source
SQL, utiliser `list-sql-sources` ci-dessus ou la vue unifiée :

```bash
curl -b ~/.docsearch-cookies http://localhost:8000/admin/all-sources | jq
```

(fusionne fichier/SQL/web avec compte de documents + taille sur disque
— aussi visible dans le panneau admin "Toutes les sources").

## Réglages optionnels, une fois la source créée

- **Libellé / description** : `POST /admin/sql-sources/{name}/label`
  ou `/description`, ou directement dans le tableau du panneau "Sources
  SQL".
- **searchable / collectable** : panneau "Toutes
  les sources", ou
  `POST /admin/all-sources/{name}/{searchable,collectable}?type=sql`.
  `searchable=false` retire la source de la consultation sans arrêter le
  sql-worker — ses lignes disparaissent de `/search` **et** de l'accès
  direct par identifiant (`/document/{id}`).
- **Changer la requête, le mapping ou `poll_interval_seconds`** : pas
  de route dédiée — repasser par le formulaire d'édition de l'admin UI
  (pré-rempli) ou réappeler `add-sql-source`/`POST /admin/sql-sources`
  avec l'ensemble des champs (l'entrée est remplacée en entier, voir
  l'avertissement à l'étape 3). Une **colonne ajoutée** prend effet
  seule, au passage suivant ; **changer le type** d'un champ déjà mappé
  demande de recréer l'index — voir l'étape 2.

## Retirer une source SQL

```bash
sudo ./manage.sh remove-sql-source clients
```

Retire uniquement l'entrée du registre (`sql-worker` arrête de
l'interroger) — **ne supprime ni l'index Elasticsearch ni les
documents déjà indexés**.

Si le DSN dynamique (méthode 2) associé n'est plus utilisé par aucune
autre source, le retirer aussi :

```bash
curl -X DELETE http://localhost:8000/admin/sql-dsns/CLIENTS_PG_DSN -b ~/.docsearch-cookies
```

⚠️ Ni `remove-sql-source` ni `DELETE /admin/sql-dsns/{name}` ne
vérifient les dépendances inverses — retirer un DSN encore référencé
par une autre source SQL la fera simplement échouer à son prochain
passage (sauf variable d'environnement de secours du même nom).

## Voir aussi

- [HOWTO-creer-source-fichier.md](HOWTO-creer-source-fichier.md) —
  équivalent pour les sources fichiers
- [HOWTO-creer-source-web.md](HOWTO-creer-source-web.md) — équivalent
  pour les sources web
- [HOWTO-commandes-utiles.md](HOWTO-commandes-utiles.md) — démarrer,
  vérifier, rebuilder
