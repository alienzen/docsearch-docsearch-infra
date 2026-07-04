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
    curl -sf "http://localhost:9200/documents/_count?pretty" 2>/dev/null \
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
    if [ -n "$SOUS_DOSSIER" ]; then
        log "Réindexation du sous-dossier : $SOUS_DOSSIER"
        $COMPOSE --profile init run --build --rm indexer-init python producer.py "$SOUS_DOSSIER"
    else
        log "Lancement de l'indexation initiale (dossier complet)..."
        $COMPOSE --profile init up --build indexer-init
    fi
    log "Publication terminée — suivre l'avancement avec : ./manage.sh logs worker"
    ;;

  scale-workers)
    N="${2:-8}"
    log "Mise à l'échelle des workers : $N instances..."
    $COMPOSE --profile dev up -d --scale worker="$N"
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
    echo "    backup          Snapshot Elasticsearch"
    echo "    reset           Supprimer toutes les données (irréversible)"
    echo ""
    ;;
esac
