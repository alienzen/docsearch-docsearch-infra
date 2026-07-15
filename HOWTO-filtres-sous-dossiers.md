# HOWTO — Motifs glob pour les filtres de sous-dossiers

Chaque source fichier (voir `file_sources_config.py`) peut restreindre ce
qui est indexé sous son dossier via deux listes de motifs glob, gérées
dans le panneau admin **"Filtres de sous-dossiers"** (ou via l'API
`/admin/path-filters/*`, voir plus bas) :

- **Liste noire (`excluded`)** : les chemins qui matchent sont ignorés.
- **Liste blanche (`included`)** : si elle contient au moins un motif,
  *seuls* les chemins qui matchent sont indexés — sinon (liste vide),
  tout est indexé sauf ce qu'exclut la liste noire.

Logique complète dans `docsearch-api/app/path_filter.py` (dupliquée à
l'identique dans `docsearch-ingestion/app/path_filter.py` — les deux
copies doivent rester synchronisées).

## Deux formes de motifs

### 1. Sans `/` — nom de fichier/dossier, à n'importe quelle profondeur

Comme une entrée de `.gitignore` sans slash : le motif est comparé à
**chaque composant** du chemin, indépendamment de sa profondeur.

| Motif       | Matche                                              | Ne matche pas                    |
|-------------|------------------------------------------------------|-----------------------------------|
| `tmp`       | `tmp/`, `finance/tmp/`, `a/b/tmp/fichier.txt`         | `tmp2/`, `mestmp/`                |
| `*.tmp`     | `x.tmp`, `finance/2024/rapport.tmp`                   | `x.tmp.bak`                       |
| `~$*`       | `~$rapport.docx` (verrous Office temporaires)         | —                                  |

### 2. Avec `/` — chemin ancré, relatif à la racine de la source

Le motif est comparé au **chemin complet depuis la racine de la
source** — jamais un chemin absolu du disque. Exclure (ou inclure) un
dossier s'applique automatiquement à tout son contenu, pas seulement
aux fichiers directement dedans.

| Motif                     | Matche                                                        |
|---------------------------|------------------------------------------------------------------|
| `finance/confidentiel`    | `finance/confidentiel/`, et tout ce qui est dessous              |
| `*/archives`              | `finance/archives/`, `rh/archives/` — mais pas `archives/` (racine) |
| `projets/*/brouillons`    | `projets/2024/brouillons/`, `projets/x/brouillons/`               |

⚠️ Les chemins comparés sont **toujours relatifs au dossier de la
source concernée** (`source.folder`), jamais à `SOURCES_MOUNT` — deux
sources différentes ont des filtres totalement indépendants, même si
elles partagent un motif identique.

## Priorité : la liste noire gagne toujours

Un chemin qui matche à la fois un motif exclu et un motif inclus reste
**exclu** — `excluded` est vérifié en premier et court-circuite le
reste (voir `is_path_allowed()`). C'est ce qui permet le cas d'usage le
plus courant : une liste blanche large + une liste noire qui découpe
des exceptions dedans.

```text
included = ["finance"]
excluded = ["finance/confidentiel"]

finance/rapport_2024.pdf        → indexé (dans le périmètre, pas exclu)
finance/confidentiel/salaires.xlsx → PAS indexé (l'exclusion gagne)
rh/note.txt                      → PAS indexé (hors liste blanche)
```

Nuance pour les **dossiers** : la liste blanche ne sert jamais à élaguer
un parcours de dossier (`os.walk`), seulement à décider si un *fichier*
doit être indexé. Un dossier `finance` ne correspond pas littéralement
au motif inclus `finance/rapports`, mais le parcours doit quand même y
descendre pour atteindre `finance/rapports/` — sinon rien en dessous ne
serait jamais indexé. Voir la docstring de `is_dir_excluded()`.

## Exemples courants

```text
# Exclure les fichiers temporaires Office et les miniatures système
Exclure : ~$*
Exclure : Thumbs.db
Exclure : .DS_Store        (déjà filtré nativement, voir plus bas)

# N'indexer qu'un sous-dossier précis d'une grosse source
Inclure : rapports_publics

# Indexer une source sauf ses archives et son dossier RH
Exclure : archives
Exclure : rh
```

Les fichiers/dossiers dont le nom commence par `.` (`.git`, `.DS_Store`,
fichiers cachés) sont de toute façon jamais proposés à l'indexation ni
affichés dans l'arborescence — inutile de les exclure explicitement.

## Où les gérer

- **Admin UI** : panneau "Filtres de sous-dossiers" (`admin.html`) —
  ajoute/retire un motif par source, effectif sous ~10s sans
  redémarrage (cache local `PATHFILTER_CACHE_TTL`).
- **API** : `GET /admin/path-filters?source=<nom>`,
  `POST /admin/path-filters/exclude`, `/include`, `/remove` — chacun
  avec `{"pattern": "...", "source": "..."}`.

## Vérifier un motif avant/après l'avoir posé

Le panneau **"Arborescence des sources"** (juste en dessous) permet de
naviguer dans le dossier réel d'une source et de voir immédiatement
quels dossiers/fichiers sont barrés en rouge (exclus) ou marqués en
vert "liste blanche" (inclus) — le moyen le plus direct de vérifier
qu'un motif fait ce qu'on attend avant de lancer un scan.

Pour vérifier l'effet sur des documents **déjà indexés** (pas
seulement les futurs), utiliser "Purger l'index existant selon un
motif" dans le même panneau : le bouton "Aperçu" liste ce qui matche
en base (`dry_run`) sans rien supprimer, avant confirmation explicite.
