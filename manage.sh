#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  manage.sh — Gestion du stack DocSearch
#  Usage : ./manage.sh [start|stop|restart|status|logs|init|reset]
#
#  Deux modes via profils Docker Compose :
#    ./manage.sh start       → profil "dev"  (ES single-node, 1 GB)
#    ./manage.sh start-prod  → profil "production" (cluster 3 nœuds)
# ─────────────────────────────────────────────────────────────
set -euo pipefail

COMPOSE="docker compose"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

# Charge .env dans le shell de manage.sh lui-même (docker compose le lit
# déjà automatiquement pour les substitutions dans docker-compose.yml,
# mais les commandes curl directes ci-dessous — status, get-config...
# tournent sur l'hôte et ont besoin de ces variables explicitement).
if [ -f .env ]; then
    # Ne JAMAIS faire "source .env" : bash exécuterait le fichier comme
    # un script, et toute valeur contenant un espace non protégé par
    # des guillemets (ex: ES_JAVA_OPTS=-Xms1g -Xmx1g, courant et valide
    # pour Docker Compose) casse tout — bash lit "-Xmx1g" comme une
    # commande à exécuter après l'assignation, d'où l'erreur
    # ".env: ligne N: -Xmx1g: commande introuvable".
    # On analyse donc le fichier ligne par ligne sans jamais l'exécuter.
    while IFS='=' read -r key value; do
        # Ignorer commentaires et lignes vides
        case "$key" in
            ''|'#'*) continue ;;
        esac
        key="$(echo "$key" | xargs)"   # espaces éventuels autour de la clé
        [ -z "$key" ] && continue
        # Retirer des guillemets englobants s'il y en a (KEY="valeur")
        value="${value%\"}"; value="${value#\"}"
        value="${value%\'}"; value="${value#\'}"
        export "$key=$value"
    done < .env
fi
ES_INDEX="${ES_INDEX:-documents}"
ES_SEARCH_ALIAS="${ES_SEARCH_ALIAS:-docsearch-all}"

log()  { echo -e "${GREEN}[DocSearch]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERREUR]${NC} $*"; exit 1; }

check_deps() {
    command -v docker >/dev/null 2>&1 || err "Docker non installé"
    command -v openssl >/dev/null 2>&1 || warn "openssl absent — génération SSL ignorée"
}

generate_ssl() {
    if [ ! -f nginx/certs/cert.pem ]; then
        log "Génération du certificat SSL auto-signé..."
        mkdir -p nginx/certs
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout nginx/certs/key.pem \
            -out    nginx/certs/cert.pem \
            -subj   "/CN=docsearch.local" 2>/dev/null
    fi
}

set_sysctl() {
    CURRENT=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
    if [ "$CURRENT" -lt 262144 ]; then
        log "Réglage vm.max_map_count=262144 (requis par Elasticsearch)..."
        sudo sysctl -w vm.max_map_count=262144
        echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf > /dev/null
    fi
}

case "${1:-help}" in

  start)
    check_deps
    set_sysctl
    log "Démarrage en mode DÉVELOPPEMENT (ES single-node)..."
    $COMPOSE --profile dev up -d --build
    log "Stack démarré :"
    echo "  🔍 Recherche : http://localhost:8000"
    echo "  📊 Kibana    : http://localhost:5601"
    echo "  🔌 API       : http://localhost:8000/docs"
    ;;

  start-prod)
    check_deps
    set_sysctl
    generate_ssl
    log "Démarrage en mode PRODUCTION (cluster ES 3 nœuds)..."
    $COMPOSE --profile production up -d --build
    log "Stack production démarré."
    ;;

  stop)
    log "Arrêt du stack..."
    $COMPOSE --profile dev --profile production down
    ;;

  restart)
    $COMPOSE --profile dev --profile production down
    $COMPOSE --profile dev up -d
    ;;

  status)
    log "État des services :"
    $COMPOSE --profile dev --profile production ps
    echo ""
    log "Santé Elasticsearch :"
    curl -sf http://localhost:9200/_cluster/health?pretty 2>/dev/null \
      || warn "ES inaccessible"
    echo ""
    log "Documents indexés (toutes sources, alias '${ES_SEARCH_ALIAS}') :"
    curl -sf "http://localhost:9200/${ES_SEARCH_ALIAS}/_count?pretty" 2>/dev/null \
      || warn "Aucune source indexée pour l'instant"
    echo ""
    log "Détail par source : ./manage.sh list-sources"
    ;;

  logs)
    SERVICE="${2:-}"
    if [ -n "$SERVICE" ]; then
        $COMPOSE --profile dev --profile production logs -f "$SERVICE"
    else
        $COMPOSE --profile dev logs -f
    fi
    ;;

  init)
    # Positionnel, comme producer.py : premier argument = nom de la
    # source (défaut "documents"), second = sous-dossier optionnel de
    # cette source. Pas de cas particulier "un seul argument = sous-
    # dossier" : ça entrait en conflit avec le sens normal du premier
    # argument (nom de source) et provoquait un "Dossier introuvable"
    # trompeur quand on tapait juste './manage.sh init <source>'.
    SOURCE="${2:-documents}"
    SOUS_DOSSIER="${3:-}"

    # Garde-fou : depuis le passage au pipeline producer/workers,
    # './manage.sh init' ne fait plus qu'écrire sur Kafka — ce sont
    # les réplicas du service "worker" qui font l'indexation réelle.
    # S'ils ne tournent pas déjà (stack jamais démarré, ou arrêté
    # depuis), le topic se remplit mais rien ne le consomme : l'index
    # est créé mais reste vide, sans aucune erreur visible.
    WORKER_COUNT=$($COMPOSE ps --status running --format '{{.Name}}' worker 2>/dev/null | wc -l | tr -d ' ')
    KAFKA_RUNNING=$($COMPOSE ps --status running --format '{{.Name}}' kafka 2>/dev/null | wc -l | tr -d ' ')

    if [ "$KAFKA_RUNNING" -eq 0 ] || [ "$WORKER_COUNT" -eq 0 ]; then
        err "Aucun worker (ou Kafka) en cours d'exécution — les messages publiés ne seraient consommés par personne.
  Lancez d'abord le stack : sudo ./manage.sh start   (ou start-prod)
  puis relancez              : sudo ./manage.sh init"
    fi

    log "Publication des fichiers sur Kafka (source '${SOURCE}'${SOUS_DOSSIER:+, sous-dossier $SOUS_DOSSIER})..."
    $COMPOSE --profile init run --build --rm indexer-init python producer.py "$SOURCE" "$SOUS_DOSSIER"
    log "Publication terminée. L'indexation se fait maintenant en arrière-plan par les $WORKER_COUNT worker(s) actifs."
    log "Suivre l'avancement : ./manage.sh logs worker"
    log "Vérifier le nombre de documents indexés : ./manage.sh list-sources"
    ;;

  scale-workers)
    N="${2:-8}"
    log "Mise à l'échelle des workers : $N instances..."
    $COMPOSE --profile dev up -d --scale worker="$N"
    ;;

  add-source)
    NAME="${2:-}"
    INDEX="${3:-}"
    if [ -z "$NAME" ] || [ -z "$INDEX" ]; then
        err "Usage : ./manage.sh add-source <nom> <index_es> [--subfolder <sous-dossier>] [--label <libellé>]
  Exemple : mkdir -p \${SOURCES_ROOT:-/data/docsearch-sources}/finance
            ./manage.sh add-source finance finance_docs --label Finance
            ./manage.sh init finance"
    fi
    shift 3
    SUBFOLDER_ARG=""
    LABEL_ARG=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --subfolder) SUBFOLDER_ARG="$2"; shift 2 ;;
            --label)     LABEL_ARG="$2"; shift 2 ;;
            *) err "Option inconnue : $1" ;;
        esac
    done

    PY_ARGS="name=\"$NAME\", es_index=\"$INDEX\""
    [ -n "$SUBFOLDER_ARG" ] && PY_ARGS="$PY_ARGS, subfolder=\"$SUBFOLDER_ARG\""
    [ -n "$LABEL_ARG" ]     && PY_ARGS="$PY_ARGS, label=\"$LABEL_ARG\""

    $COMPOSE --profile init run --build --rm indexer-init python3 -c "
from sources_config import add_source
import json
cfg = add_source($PY_ARGS)
print(json.dumps(cfg, indent=2, ensure_ascii=False))
"
    log "Source '$NAME' enregistrée — le watcher commence à l'observer sous ~5s (sans redémarrage)."
    log "Lancer l'indexation initiale : ./manage.sh init $NAME"
    ;;

  list-sources)
    $COMPOSE --profile init run --build --rm indexer-init python3 -c "
from sources_config import get_sources
import json
print(json.dumps({n: {'es_index': s.es_index, 'folder': s.folder, 'label': s.label} for n, s in get_sources().items()}, indent=2, ensure_ascii=False))
"
    ;;

  remove-source)
    NAME="${2:-}"
    if [ -z "$NAME" ]; then
        err "Usage : ./manage.sh remove-source <nom>
  Retire la source du registre (le watcher arrête de l'observer) — NE
  supprime PAS l'index Elasticsearch ni les documents déjà indexés.
  Utiliser ensuite 'purge-path' pour nettoyer l'existant si besoin."
    fi
    $COMPOSE --profile init run --build --rm indexer-init python3 -c "
from sources_config import remove_source
import json
print(json.dumps(remove_source('$NAME'), indent=2, ensure_ascii=False))
"
    log "Source '$NAME' retirée du registre."
    warn "L'index Elasticsearch associé n'a PAS été supprimé (voir purge-path pour nettoyer)."
    ;;

  set-config)
    KEY="${2:-}"
    VALUE="${3:-}"
    if [ -z "$KEY" ] || [ -z "$VALUE" ]; then
        err "Usage : ./manage.sh set-config <clé> <valeur>
  Clés disponibles : archive_max_files, archive_max_total_size_mb,
                      archive_max_depth, worker_batch_size,
                      worker_flush_interval, watcher_poll_interval"
    fi
    $COMPOSE --profile init run --build --rm indexer-init python3 -c "
from runtime_config import set_param
import json
cfg = set_param('$KEY', '$VALUE')
print(json.dumps(cfg, indent=2, ensure_ascii=False))
"
    log "Paramètre '$KEY' mis à jour. Pris en compte sous 10s par worker/producer,"
    log "sous 5s par watcher (watcher_poll_interval redémarre son observateur automatiquement)."
    warn "worker_batch_size (Kafka max_poll_records) nécessite un redémarrage du worker pour être pleinement effectif."
    ;;

  get-config)
    $COMPOSE --profile init run --build --rm indexer-init python3 -c "
from runtime_config import get_runtime_config
import json
print(json.dumps(get_runtime_config(), indent=2, ensure_ascii=False))
"
    ;;

  exclude-path)
    PATTERN="${2:-}"
    SOURCE="${3:-documents}"
    if [ -z "$PATTERN" ]; then
        err "Usage : ./manage.sh exclude-path <motif> [source]
  Exemples : ./manage.sh exclude-path finance/confidentiel
             ./manage.sh exclude-path '*/tmp' finance
             ./manage.sh exclude-path '*.cache'"
    fi
    $COMPOSE --profile init run --build --rm indexer-init python3 -c "
from path_filter import add_excluded
import json
print(json.dumps(add_excluded('$PATTERN', '$SOURCE'), indent=2, ensure_ascii=False))
"
    log "Motif d'exclusion ajouté à la source '$SOURCE' : '$PATTERN' — effectif sous 10s pour les scans/watcher déjà en cours."
    warn "Les documents déjà indexés dans ce sous-dossier NE SONT PAS supprimés automatiquement."
    ;;

  include-path)
    PATTERN="${2:-}"
    SOURCE="${3:-documents}"
    if [ -z "$PATTERN" ]; then
        err "Usage : ./manage.sh include-path <motif> [source]
  Bascule en liste blanche : si au moins un motif est inclus, SEULS
  les chemins correspondants sont indexés (l'exclusion reste prioritaire)."
    fi
    $COMPOSE --profile init run --build --rm indexer-init python3 -c "
from path_filter import add_included
import json
print(json.dumps(add_included('$PATTERN', '$SOURCE'), indent=2, ensure_ascii=False))
"
    log "Motif d'inclusion ajouté à la source '$SOURCE' : '$PATTERN'."
    ;;

  remove-path-filter)
    PATTERN="${2:-}"
    SOURCE="${3:-documents}"
    if [ -z "$PATTERN" ]; then
        err "Usage : ./manage.sh remove-path-filter <motif> [source]"
    fi
    $COMPOSE --profile init run --build --rm indexer-init python3 -c "
from path_filter import remove_filter
import json
print(json.dumps(remove_filter('$PATTERN', '$SOURCE'), indent=2, ensure_ascii=False))
"
    log "Motif '$PATTERN' retiré de la source '$SOURCE' (des deux listes s'il y était)."
    ;;

  list-path-filters)
    SOURCE="${2:-documents}"
    $COMPOSE --profile init run --build --rm indexer-init python3 -c "
from path_filter import get_config
import json
print(json.dumps(get_config('$SOURCE'), indent=2, ensure_ascii=False))
"
    ;;

  purge-path)
    PATTERN="${2:-}"
    SOURCE="${3:-documents}"
    if [ -z "$PATTERN" ]; then
        err "Usage : ./manage.sh purge-path <motif> [source]
  Supprime de l'INDEX (pas du disque) les documents déjà indexés dont
  le chemin correspond au motif — même syntaxe glob que exclude-path.
  Utile après un exclude-path : ce dernier n'agit que sur les futurs
  passages, purge-path nettoie l'existant.
  Exemples :
    ./manage.sh purge-path finance/confidentiel
    ./manage.sh purge-path '*/tmp' finance"
    fi

    log "Aperçu (aucune suppression) — documents déjà indexés (source '$SOURCE') correspondant à '$PATTERN' :"
    $COMPOSE --profile init run --build --rm indexer-init python3 -c "
from sources_config import get_source
from indexer import purge_path
n = purge_path('$PATTERN', get_source('$SOURCE'), dry_run=True)
print(f'{n} document(s) correspondent au motif.')
"

    warn "Cette suppression est IRRÉVERSIBLE (seul l'index est purgé, les fichiers sur le disque ne sont pas touchés — une réindexation les retrouvera si le filtre est retiré ensuite)."
    read -rp "Confirmer la suppression ? (oui/non) : " REPLY_CONFIRM
    if [ "$REPLY_CONFIRM" != "oui" ]; then
        log "Annulé."
        exit 0
    fi

    $COMPOSE --profile init run --build --rm indexer-init python3 -c "
from sources_config import get_source
from indexer import purge_path
n = purge_path('$PATTERN', get_source('$SOURCE'), dry_run=False)
print(f'{n} document(s) supprimé(s) de l\'index.')
"
    log "Purge terminée."
    ;;

  set-filetype)
    EXT="${2:-}"
    if [ -z "$EXT" ]; then
        err "Usage : ./manage.sh set-filetype <extension> [--enabled true|false] [--max-size Mo]"
    fi
    shift 2
    ENABLED_ARG=""
    MAXSIZE_ARG=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --enabled)  ENABLED_ARG="$2"; shift 2 ;;
            --max-size) MAXSIZE_ARG="$2"; shift 2 ;;
            *) err "Option inconnue : $1" ;;
        esac
    done

    PY_ARGS="extension=\"$EXT\""
    [ -n "$ENABLED_ARG" ]  && PY_ARGS="$PY_ARGS, enabled=$([ "$ENABLED_ARG" = "true" ] && echo True || echo False)"
    [ -n "$MAXSIZE_ARG" ]  && PY_ARGS="$PY_ARGS, max_size_mb=$MAXSIZE_ARG"

    $COMPOSE --profile init run --build --rm indexer-init python3 -c "
from filetype_config import set_filetype
import json
cfg = set_filetype($PY_ARGS)
print(json.dumps(cfg, indent=2, ensure_ascii=False))
"
    log "Configuration mise à jour — effective immédiatement (cache de ${FILETYPE_CONFIG_CACHE_TTL:-10}s max) sur les workers/watcher/producer déjà démarrés."
    ;;

  get-filetypes)
    $COMPOSE --profile init run --build --rm indexer-init python3 -c "
from filetype_config import get_config
import json
print(json.dumps(get_config(), indent=2, ensure_ascii=False))
"
    ;;

  reset)
    warn "⚠️  Cette commande supprime TOUTES les données."
    read -rp "Confirmer ? (oui/non) : " CONFIRM
    [ "$CONFIRM" = "oui" ] || { log "Annulé."; exit 0; }
    $COMPOSE --profile dev --profile production down -v
    log "Volumes supprimés."
    ;;

  backup)
    BACKUP_DIR="./backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    curl -sf -X PUT "http://localhost:9200/_snapshot/backup_repo" \
         -H "Content-Type: application/json" \
         -d '{"type":"fs","settings":{"location":"/backup"}}' > /dev/null
    curl -sf -X PUT \
         "http://localhost:9200/_snapshot/backup_repo/snap_$(date +%s)?wait_for_completion=true" \
         > "$BACKUP_DIR/snapshot.json"
    log "Snapshot créé : $BACKUP_DIR/snapshot.json"
    ;;

  help|*)
    echo ""
    echo "  Usage : ./manage.sh <commande>"
    echo ""
    echo "  Commandes :"
    echo "    start           Démarrer en mode développement (ES single-node)"
    echo "    start-prod      Démarrer en mode production (cluster 3 nœuds)"
    echo "    stop            Arrêter tous les services"
    echo "    restart         Redémarrer en mode dev"
    echo "    status          État + stats Elasticsearch"
    echo "    logs [service]  Logs en temps réel"
    echo "    init [source] [sous-dossier]"
    echo "                    Indexation d'une source (défaut : 'documents'), complète"
    echo "                    ou restreinte à un sous-dossier de son répertoire"
    echo "    scale-workers N Ajuster le nombre de workers"
    echo "    add-source <nom> <index_es> [--subfolder ...] [--label ...]"
    echo "                    Enregistrer une nouvelle source à indexer — sans"
    echo "                    redémarrage ni rebuild, voir SOURCES_ROOT dans .env"
    echo "    list-sources    Lister les sources enregistrées"
    echo "    remove-source <nom>"
    echo "                    Retirer une source du registre (ne supprime PAS son index)"
    echo "    set-filetype <ext> [--enabled true|false] [--max-size Mo]"
    echo "                    Activer/désactiver un type de fichier ou fixer sa taille max"
    echo "                    (effectif immédiatement, sans redémarrage — cache 10s max)"
    echo "    get-filetypes   Afficher la configuration actuelle par type de fichier"
    echo "    set-config <clé> <valeur>"
    echo "                    Modifier un paramètre opérationnel (archive_max_depth,"
    echo "                    worker_flush_interval, watcher_poll_interval, etc.)"
    echo "    get-config      Afficher tous les paramètres opérationnels actuels"
    echo "    exclude-path <motif> [source]       Exclure un sous-dossier de l'indexation (glob)"
    echo "    include-path <motif> [source]       Passer en liste blanche (n'indexer QUE ces chemins)"
    echo "    remove-path-filter <motif> [source] Retirer un motif d'inclusion/exclusion"
    echo "    list-path-filters [source]          Afficher les filtres de chemin actuels"
    echo "    purge-path <motif> [source]         Supprimer de l'index les documents déjà"
    echo "                                        indexés correspondant au motif (avec confirmation)"
    echo "    backup          Snapshot Elasticsearch"
    echo "    reset           Supprimer toutes les données (irréversible)"
    echo ""
    ;;
esac
