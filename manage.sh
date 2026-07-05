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
    set -a
    source .env
    set +a
fi
ES_INDEX="${ES_INDEX:-documents}"

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
    log "Documents indexés :"
    curl -sf "http://localhost:9200/${ES_INDEX}/_count?pretty" 2>/dev/null \
      || warn "Index non trouvé"
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
    SOUS_DOSSIER="${2:-}"

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

    if [ -n "$SOUS_DOSSIER" ]; then
        log "Réindexation du sous-dossier : $SOUS_DOSSIER"
        $COMPOSE --profile init run --build --rm indexer-init python producer.py "$SOUS_DOSSIER"
    else
        log "Publication des fichiers sur Kafka (dossier complet)..."
        $COMPOSE --profile init up --build indexer-init
    fi
    log "Publication terminée. L'indexation se fait maintenant en arrière-plan par les $WORKER_COUNT worker(s) actifs."
    log "Suivre l'avancement : ./manage.sh logs worker"
    log "Vérifier le nombre de documents indexés : curl http://localhost:9200/${ES_INDEX}/_count?pretty"
    ;;

  scale-workers)
    N="${2:-8}"
    log "Mise à l'échelle des workers : $N instances..."
    $COMPOSE --profile dev up -d --scale worker="$N"
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
    if [ -z "$PATTERN" ]; then
        err "Usage : ./manage.sh exclude-path <motif>
  Exemples : ./manage.sh exclude-path finance/confidentiel
             ./manage.sh exclude-path '*/tmp'
             ./manage.sh exclude-path '*.cache'"
    fi
    $COMPOSE --profile init run --build --rm indexer-init python3 -c "
from path_filter import add_excluded
import json
print(json.dumps(add_excluded('$PATTERN'), indent=2, ensure_ascii=False))
"
    log "Motif d'exclusion ajouté : '$PATTERN' — effectif sous 10s pour les scans/watcher déjà en cours."
    warn "Les documents déjà indexés dans ce sous-dossier NE SONT PAS supprimés automatiquement."
    ;;

  include-path)
    PATTERN="${2:-}"
    if [ -z "$PATTERN" ]; then
        err "Usage : ./manage.sh include-path <motif>
  Bascule en liste blanche : si au moins un motif est inclus, SEULS
  les chemins correspondants sont indexés (l'exclusion reste prioritaire)."
    fi
    $COMPOSE --profile init run --build --rm indexer-init python3 -c "
from path_filter import add_included
import json
print(json.dumps(add_included('$PATTERN'), indent=2, ensure_ascii=False))
"
    log "Motif d'inclusion ajouté : '$PATTERN'."
    ;;

  remove-path-filter)
    PATTERN="${2:-}"
    if [ -z "$PATTERN" ]; then
        err "Usage : ./manage.sh remove-path-filter <motif>"
    fi
    $COMPOSE --profile init run --build --rm indexer-init python3 -c "
from path_filter import remove_filter
import json
print(json.dumps(remove_filter('$PATTERN'), indent=2, ensure_ascii=False))
"
    log "Motif '$PATTERN' retiré (des deux listes s'il y était)."
    ;;

  list-path-filters)
    $COMPOSE --profile init run --build --rm indexer-init python3 -c "
from path_filter import get_config
import json
print(json.dumps(get_config(), indent=2, ensure_ascii=False))
"
    ;;

  purge-path)
    PATTERN="${2:-}"
    if [ -z "$PATTERN" ]; then
        err "Usage : ./manage.sh purge-path <motif>
  Supprime de l'INDEX (pas du disque) les documents déjà indexés dont
  le chemin correspond au motif — même syntaxe glob que exclude-path.
  Utile après un exclude-path : ce dernier n'agit que sur les futurs
  passages, purge-path nettoie l'existant.
  Exemples :
    ./manage.sh purge-path finance/confidentiel
    ./manage.sh purge-path '*/tmp'"
    fi

    log "Aperçu (aucune suppression) — documents déjà indexés correspondant à '$PATTERN' :"
    $COMPOSE --profile init run --build --rm indexer-init python3 -c "
from indexer import purge_path
n = purge_path('$PATTERN', dry_run=True)
print(f'{n} document(s) correspondent au motif.')
"

    warn "Cette suppression est IRRÉVERSIBLE (seul l'index est purgé, les fichiers sur le disque ne sont pas touchés — une réindexation les retrouvera si le filtre est retiré ensuite)."
    read -rp "Confirmer la suppression ? (oui/non) : " REPLY_CONFIRM
    if [ "$REPLY_CONFIRM" != "oui" ]; then
        log "Annulé."
        exit 0
    fi

    $COMPOSE --profile init run --build --rm indexer-init python3 -c "
from indexer import purge_path
n = purge_path('$PATTERN', dry_run=False)
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
    echo "    init [sous-dossier]  Indexation (complète, ou d'un sous-dossier de /documents)"
    echo "    scale-workers N Ajuster le nombre de workers"
    echo "    set-filetype <ext> [--enabled true|false] [--max-size Mo]"
    echo "                    Activer/désactiver un type de fichier ou fixer sa taille max"
    echo "                    (effectif immédiatement, sans redémarrage — cache 10s max)"
    echo "    get-filetypes   Afficher la configuration actuelle par type de fichier"
    echo "    set-config <clé> <valeur>"
    echo "                    Modifier un paramètre opérationnel (archive_max_depth,"
    echo "                    worker_flush_interval, watcher_poll_interval, etc.)"
    echo "    get-config      Afficher tous les paramètres opérationnels actuels"
    echo "    exclude-path <motif>       Exclure un sous-dossier de l'indexation (glob)"
    echo "    include-path <motif>       Passer en liste blanche (n'indexer QUE ces chemins)"
    echo "    remove-path-filter <motif> Retirer un motif d'inclusion/exclusion"
    echo "    list-path-filters          Afficher les filtres de chemin actuels"
    echo "    purge-path <motif>         Supprimer de l'index les documents déjà"
    echo "                               indexés correspondant au motif (avec confirmation)"
    echo "    backup          Snapshot Elasticsearch"
    echo "    reset           Supprimer toutes les données (irréversible)"
    echo ""
    ;;
esac
