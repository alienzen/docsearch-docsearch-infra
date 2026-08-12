# HOWTO — Créer une source de type fichier

Une "source fichier" = un sous-dossier de `SOURCES_ROOT` (sur l'hôte,
monté dans les conteneurs sous `SOURCES_MOUNT`) indexé vers son propre
index Elasticsearch — voir `file_sources_config.py` (dupliqué à
l'identique dans `docsearch-ingestion/app/` et `docsearch-api/app/`). À
distinguer des sources SQL (`sql_sources_config.py`) et web
(`web_sources_config.py`), qui suivent un flux différent.

Contrainte à connaître avant de commencer : un montage est fixé à la
création du conteneur — impossible d'en ajouter un sans modifier l'unité
et recréer les conteneurs. C'est pourquoi toutes les sources fichier vivent
sous ce seul point de montage parent : ajouter une source ne nécessite
qu'un sous-dossier de `SOURCES_ROOT` + un enregistrement dynamique (dans
Redis, relu à chaud par watcher/worker/producer), jamais de toucher au
montage ni de redémarrer un conteneur.

Trois méthodes pour enregistrer la source, du plus rapide (script) au
plus visuel (UI). Les étapes 1, 3 et 4 sont les mêmes quelle que soit la
méthode choisie pour l'étape 2.

## 1. Créer le dossier sur l'hôte

```bash
mkdir -p "${SOURCES_ROOT:-/data/docsearch-sources}/finance"
```

L'ordre entre "créer le dossier" et "enregistrer la source" (étape 2)
n'a pas d'importance pour le registre — seul le premier scan/passage
watcher a besoin que le dossier existe réellement sur disque. En
pratique, autant le créer tout de suite pour ne pas l'oublier.

⚠️ Le dossier doit appartenir à l'UID déclaré dans `APP_UID` au moment de
la construction des images (défaut 1000, `id -u` sur l'hôte) — sinon les
conteneurs ne pourront ni le lire ni écrire dedans (verrous
d'indexation, etc.).

Les permissions du fichier/dossier sur l'hôte déterminent aussi l'ACL du
document une fois indexé (`acl_extractor.py`) — rien à configurer côté
source pour ça, c'est automatique et par fichier.

## 2. Enregistrer la source

### a. Script `manage.sh` (le plus rapide)

```bash
cd docsearch-infra
sudo ./manage.sh add-file-source finance finance_docs --label Finance
```

```text
Usage : sudo ./manage.sh add-file-source <nom> <index_es> [--subfolder <sous-dossier>] [--label <libellé>]
```

`--subfolder` par défaut au nom de la source (ici `finance`) — à
préciser seulement si le sous-dossier réel a un nom différent.

### b. Panneau admin "Sources fichiers" (`admin.html`)

Champs du formulaire : **nom** (ex. `finance`), **index ES** (ex.
`finance_docs`), **sous-dossier** (optionnel, défaut = nom), **libellé**
(optionnel), **description** (optionnel) — bouton "Ajouter". Le
libellé, la description et l'OCR restent modifiables après coup
directement depuis la liste, sans recréer la source.

### c. API directement

> Les commandes `/admin/*` ci-dessous exigent une session : ouvrir un
> bocal à cookies une fois pour toutes, voir « S'authentifier pour les
> commandes d'administration » dans
> [HOWTO-commandes-utiles.md](HOWTO-commandes-utiles.md).

```bash
curl -X POST http://localhost:8000/admin/file-sources \
  -b ~/.docsearch-cookies -H "Content-Type: application/json" \
  -d '{"name": "finance", "es_index": "finance_docs", "label": "Finance"}'
```

Règles de validation (`file_sources_config._validate_name` /
`_validate_subfolder`, voir `add_source()`) valables pour les trois
méthodes :

- **nom** et **index ES** : minuscules, chiffres, `-`/`_`, doivent
  commencer par une lettre/chiffre — jamais vides.
- **index ES** : ne doit être utilisé par aucune autre source déjà
  enregistrée (erreur 400 sinon).
- **sous-dossier** : doit résoudre sous `SOURCES_MOUNT`, aucune
  traversée de chemin (`../..`) acceptée.

⚠️ `add_source()` **remplace entièrement** l'entrée si le nom existe
déjà (pas de fusion partielle) — resoumettre le formulaire d'ajout sur
une source existante réinitialise `searchable`/`collectable`/
`ocr_enabled` à leurs valeurs par défaut sauf si on les repasse
explicitement (l'API `/admin/file-sources` le fait automatiquement en
relisant l'existant avant d'écrire, mais un appel `add_source()` direct
en script n'a pas ce filet).

La source est prise en compte par le watcher sous ~5s, sans
redémarrage d'aucun conteneur.

## 3. Lancer l'indexation initiale

Le watcher ne détecte que les fichiers créés/modifiés **après** son
démarrage — tout contenu déjà présent dans le dossier au moment de
l'enregistrement a besoin d'un passage explicite :

```bash
sudo ./manage.sh init finance
```

Équivalent dans l'admin UI : panneau "Indexation", choisir la source
dans le menu déroulant (sous-dossier optionnel pour ne réindexer qu'une
partie), bouton de lancement — suivre la progression dans "État des
composants".

`init` ne fait qu'écrire sur Kafka (topic `documents-to-index`) ;
l'indexation réelle est faite en arrière-plan par les réplicas du
service `worker`, qui doivent déjà tourner. `manage.sh` refuse de
continuer si Kafka ou aucun worker n'est détecté actif.

## 4. Vérifier

```bash
sudo ./manage.sh list-file-sources
curl -s http://localhost:9200/finance_docs/_count?pretty
```

Ou dans l'admin UI : le tableau "Sources fichiers" liste nom/libellé/
index/dossier/description, et "État des composants" (`/admin/status`)
donne le nombre de documents indexés par source.

## Réglages optionnels, une fois la source créée

- **OCR** (Tesseract via Tika, PDF scannés/images) : case à cocher par
  source dans le tableau "Sources fichiers", ou
  `POST /admin/file-sources/{name}/ocr`. Désactivé par défaut (coûteux
  en CPU) ; n'affecte que les documents indexés après activation, pas
  de réextraction rétroactive.
- **searchable / collectable** : panneau "Toutes
  les sources" (vue unifiée fichier/SQL/web), ou
  `POST /admin/all-sources/{name}/{searchable,collectable}?type=file`.
  `searchable=false` retire la source de la consultation sans arrêter
  l'ingestion — ses documents disparaissent de `/search` **et** de
  l'accès direct par identifiant (`/document/{id}`, `/api/preview/{id}`),
  y compris pour un lien copié ou un document laissé dans une
  collection avant la désactivation ; `collectable=false` bloque l'ajout
  à une collection sans effet sur la recherche.
- **Filtres de sous-dossiers** (inclure/exclure des motifs glob) : voir
  [HOWTO-filtres-sous-dossiers.md](HOWTO-filtres-sous-dossiers.md).

## Retirer une source

```bash
sudo ./manage.sh remove-file-source finance
```

Retire uniquement l'entrée du registre (le watcher arrête d'observer le
dossier) — **ne supprime ni l'index Elasticsearch ni les documents déjà
indexés**. Pour nettoyer l'existant, utiliser le panneau "Purger l'index
existant selon un motif" (dry-run disponible) ou supprimer l'index ES
directement.
