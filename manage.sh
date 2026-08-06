#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  manage.sh — Gestion du stack DocSearch (podman + systemd)
#  Usage : ./manage.sh [start|stop|restart|status|logs|init|reset]
#
#  Les services sont des unités systemd générées par Quadlet (voir
#  quadlet/) : ce script ne fait que les piloter et exécuter les tâches
#  ponctuelles d'administration dans un conteneur jetable.
#
#  Installation des unités — une fois par machine, AVANT tout démarrage :
#    sudo ./quadlet/install-units.sh dev        (poste de développement)
#    sudo ./quadlet/install-units.sh <rôle>     (serveurs de production)
#
#  Il n'y a plus de "start-prod" : le mode d'une machine est déterminé
#  par les unités qui y sont installées, pas par une option au démarrage.
# ─────────────────────────────────────────────────────────────
set -euo pipefail

PODMAN="podman"
TARGET="docsearch.target"

# Configuration de la machine — remplace l'ancien .env de Compose.
CONFIG_DIR="${DOCSEARCH_CONFIG_DIR:-/etc/docsearch}"
ENV_FILE="$CONFIG_DIR/docsearch.env"

# Images construites localement (voir ./manage.sh build)
IMAGE_INGESTION="localhost/docsearch/ingestion:latest"
IMAGE_API="localhost/docsearch/api:latest"
IMAGE_UI="localhost/docsearch/ui-vue:latest"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

# Charge la configuration de la machine dans le shell de manage.sh :
# les conteneurs la reçoivent par --env-file, mais les commandes curl
# ci-dessous (status, get-config...) tournent sur l'hôte et ont besoin
# de ces variables explicitement.
#
# Test de LISIBILITÉ, pas d'existence : ce fichier porte le mot de passe
# LDAP et les DSN SQL, il est donc en 0600 root. Un utilisateur ordinaire
# ne peut pas le lire, et le script doit continuer avec les valeurs par
# défaut plutôt que d'échouer sur une redirection refusée — "status" et
# "logs" restent utilisables sans sudo.
if [ -f "$ENV_FILE" ] && [ ! -r "$ENV_FILE" ]; then
    echo -e "\033[1;33m[WARN]\033[0m $ENV_FILE illisible (0600 root) — valeurs par défaut utilisées. Passer par sudo pour la configuration réelle." >&2
fi
if [ -r "$ENV_FILE" ]; then
    # Ne JAMAIS faire "source" : bash exécuterait le fichier comme un
    # script, et toute valeur contenant un espace non protégé par des
    # guillemets (ex: ES_JAVA_OPTS=-Xms1g -Xmx1g) casse tout — bash lit
    # "-Xmx1g" comme une commande à exécuter après l'assignation, d'où
    # l'erreur "-Xmx1g : commande introuvable".
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
    done < "$ENV_FILE"
fi
ES_INDEX="${ES_INDEX:-documents}"
ES_SEARCH_ALIAS="${ES_SEARCH_ALIAS:-docsearch-all}"

log()  { echo -e "${GREEN}[DocSearch]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERREUR]${NC} $*"; exit 1; }

check_deps() {
    command -v podman    >/dev/null 2>&1 || err "podman n'est pas installé."
    command -v systemctl >/dev/null 2>&1 || err "systemd est requis (unités Quadlet)."
    [ -f "$ENV_FILE" ] || err "$ENV_FILE introuvable — installer d'abord les unités :
  sudo ./quadlet/install-units.sh dev        (poste de développement)
  sudo ./quadlet/install-units.sh <rôle>     (serveurs de production)"
}

# systemctl start/stop/restart exige les droits root (podman rootful).
require_root() {
    [ "$(id -u)" -eq 0 ] || err "Cette commande doit être lancée avec sudo."
}

# Nom réel du réseau podman. Quadlet le préfixe ("systemd-docsearch-net")
# quand la clé NetworkName= n'est pas prise en compte — ce qui dépend de
# la version de podman. On le retrouve au lieu de le supposer.
net_name() {
    $PODMAN network ls --format '{{.Name}}' 2>/dev/null \
      | grep -E '^(systemd-)?docsearch-net$' | head -1
}

# Exécute une tâche ponctuelle d'administration dans un conteneur
# jetable, sur le réseau et avec la configuration de la pile.
#
# Remplace les 22 "docker compose --profile init run --rm indexer-init"
# de la version Compose : même image que les workers, mêmes variables,
# mêmes sources montées en lecture seule.
#
# Les options "-e VAR" éventuelles sont consommées en tête d'appel et
# transmises à podman : elles font passer au conteneur une variable de
# l'environnement de ce script (paramètres d'add-sql-source /
# add-web-source), qui ne vit pas dans le fichier de configuration.
init_run() {
    local net
    local passthrough=()
    while [ "${1:-}" = "-e" ]; do
        passthrough+=("-e" "$2")
        shift 2
    done
    # Le réseau, les images et le fichier de configuration appartiennent
    # tous à root (podman rootful) : sans sudo, le conteneur jetable ne
    # trouverait ni le réseau ni les images. Autant le dire clairement
    # plutôt que de laisser échouer sur "réseau introuvable".
    [ "$(id -u)" -eq 0 ] || err "Cette commande doit être lancée avec sudo (réseau et images appartiennent à root)."
    net="$(net_name)"
    [ -n "$net" ] || err "Réseau podman introuvable — la pile a-t-elle déjà démarré ? (sudo ./manage.sh start)"
    $PODMAN image exists "$IMAGE_INGESTION" \
      || err "Image $IMAGE_INGESTION absente — la construire (sudo ./manage.sh build) ou la charger (sudo podman load), voir HOWTO-deploiement-hors-ligne.md."
    $PODMAN run --rm \
        --network "$net" \
        --env-file "$ENV_FILE" \
        ${passthrough[@]+"${passthrough[@]}"} \
        -v "${SOURCES_HOST_PATH:-/data/docsearch-sources}:${SOURCES_MOUNT:-/sources}:ro" \
        "$IMAGE_INGESTION" "$@"
}

# Nombre d'unités systemd actives correspondant à un motif
units_running() {
    systemctl list-units --state=running --no-legend "$1" 2>/dev/null | wc -l | tr -d ' '
}

generate_ssl() {
    local certs="$CONFIG_DIR/nginx/certs"
    if [ ! -f "$certs/cert.pem" ]; then
        command -v openssl >/dev/null 2>&1 || { warn "openssl absent — génération SSL ignorée"; return 0; }
        log "Génération du certificat SSL auto-signé..."
        mkdir -p "$certs"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$certs/key.pem" \
            -out    "$certs/cert.pem" \
            -subj   "/CN=docsearch.local" 2>/dev/null
    fi
}

set_sysctl() {
    CURRENT=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
    if [ "$CURRENT" -lt 262144 ]; then
        log "Réglage vm.max_map_count=262144 (requis par Elasticsearch)..."
        sudo sysctl -w vm.max_map_count=262144
        # Fichier dédié plutôt qu'un ajout en fin de /etc/sysctl.conf :
        # l'ancienne version y ajoutait une ligne à CHAQUE démarrage.
        echo "vm.max_map_count=262144" | sudo tee /etc/sysctl.d/99-docsearch.conf > /dev/null
    fi
}

case "${1:-help}" in

  start)
    check_deps
    require_root
    set_sysctl
    # Ne fait rien si le certificat existe déjà, et ne concerne que les
    # machines qui portent le reverse proxy.
    [ -f "$CONFIG_DIR/nginx/nginx.conf" ] && generate_ssl
    log "Démarrage des unités DocSearch ($TARGET)..."
    systemctl start "$TARGET"
    log "Pile démarrée :"
    echo "  🔍 Interface : http://localhost:8080"
    echo "  🔌 API       : http://localhost:8000/docs"
    echo "  📊 Kibana    : sudo systemctl start docsearch-kibana → http://localhost:5601"
    echo "  📋 État      : ./manage.sh status"
    ;;

  stop)
    require_root
    log "Arrêt des unités DocSearch..."
    systemctl stop "$TARGET"
    ;;

  restart)
    require_root
    log "Redémarrage des unités DocSearch..."
    systemctl restart "$TARGET"
    ;;

  status)
    log "État des services :"
    systemctl list-units 'docsearch-*' --all --no-pager || true
    echo ""
    log "Santé Elasticsearch :"
    curl -sf http://localhost:9200/_cluster/health?pretty 2>/dev/null \
      || warn "ES inaccessible"
    echo ""
    log "Documents indexés (toutes sources, alias '${ES_SEARCH_ALIAS}') :"
    curl -sf "http://localhost:9200/${ES_SEARCH_ALIAS}/_count?pretty" 2>/dev/null \
      || warn "Aucune source indexée pour l'instant"
    echo ""
    log "Détail par source : ./manage.sh list-file-sources"
    ;;

  logs)
    # Les journaux des conteneurs vont dans journald : "logs worker"
    # suit toutes les unités worker d'un coup (motif docsearch-worker-*),
    # ce que "docker compose logs worker" faisait pour les réplicas.
    SERVICE="${2:-}"
    if [ -n "$SERVICE" ]; then
        case "$SERVICE" in
            worker) journalctl -f -u 'docsearch-worker-*' ;;
            *)      journalctl -f -u "docsearch-${SERVICE#docsearch-}" ;;
        esac
    else
        journalctl -f -u 'docsearch-*'
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
    WORKER_COUNT=$(units_running 'docsearch-worker-*.service')
    # Kafka peut tourner sur CETTE machine (mono-hôte) ou sur une autre
    # (déploiement 8 machines) : dans le second cas, c'est le verrou de
    # disponibilité qui atteste que le broker répond.
    KAFKA_OK=0
    systemctl is-active --quiet docsearch-kafka.service       2>/dev/null && KAFKA_OK=1
    systemctl is-active --quiet docsearch-kafka-ready.service 2>/dev/null && KAFKA_OK=1

    if [ "$KAFKA_OK" -eq 0 ] || [ "$WORKER_COUNT" -eq 0 ]; then
        err "Aucun worker (ou Kafka) en cours d'exécution — les messages publiés ne seraient consommés par personne.
  Lancez d'abord la pile : sudo ./manage.sh start
  puis relancez          : ./manage.sh init"
    fi

    log "Publication des fichiers sur Kafka (source '${SOURCE}'${SOUS_DOSSIER:+, sous-dossier $SOUS_DOSSIER})..."
    init_run python producer.py "$SOURCE" "$SOUS_DOSSIER"
    log "Publication terminée. L'indexation se fait maintenant en arrière-plan par les $WORKER_COUNT worker(s) actifs."
    log "Suivre l'avancement : ./manage.sh logs worker"
    log "Vérifier le nombre de documents indexés : ./manage.sh list-file-sources"
    ;;

  scale-workers)
    # Une unité systemd par worker : la mise à l'échelle consiste à
    # régénérer les unités depuis le modèle (quadlet/*/…worker.container.in)
    # puis à les démarrer. install-units.sh sait faire les deux sens,
    # y compris retirer les unités excédentaires.
    require_root
    N="${2:-4}"
    ARGS_FILE="$CONFIG_DIR/install-args"
    [ -f "$ARGS_FILE" ] || err "$ARGS_FILE introuvable — réinstaller les unités :
  sudo ./quadlet/install-units.sh <rôle>"

    # Arrêter d'abord les workers qui vont disparaître : leurs unités
    # sont sur le point d'être supprimées, systemd n'en aurait plus la
    # trace pour les arrêter ensuite.
    for unit in $(systemctl list-units --no-legend 'docsearch-worker-*.service' 2>/dev/null | awk '{print $1}'); do
        n="${unit%.service}"; n="${n##*-}"
        if [ "$n" -gt "$N" ] 2>/dev/null; then
            log "Arrêt de $unit..."
            systemctl stop "$unit" || true
        fi
    done

    log "Mise à l'échelle des workers : $N unités..."
    # shellcheck disable=SC2046  # découpage voulu : rôle + options
    "$(dirname "$0")/quadlet/install-units.sh" $(cat "$ARGS_FILE") --workers "$N"
    systemctl start "$TARGET"
    log "Workers actifs : $(units_running 'docsearch-worker-*.service')"
    ;;

  build)
    # Construction des images applicatives. À faire sur une machine
    # CONNECTÉE (apt-get / pip install / npm ci dans les Dockerfiles) —
    # voir HOWTO-deploiement-hors-ligne.md pour le transfert vers une
    # machine isolée.
    WHAT="${2:-all}"
    REPOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
    # ⚠️ podman sépare le magasin d'images de root de celui de chaque
    # utilisateur : une image construite SANS sudo est invisible pour les
    # unités systemd, qui tournent en root. Le symptôme est un
    # "image not known" au démarrage alors que "podman images" la montre.
    if [ "$(id -u)" -ne 0 ]; then
        warn "Construction dans le magasin de $USER (podman rootless).
  Les unités systemd tournent en ROOT et ne verront pas ces images.
  Au choix :
    sudo ./manage.sh build $WHAT                        (construire directement en root)
    podman save -m <images> | sudo podman load          (transférer après coup)"
    fi
    # APP_UID : UID de l'utilisateur DANS les conteneurs, à aligner sur le
    # propriétaire des dossiers montés depuis l'hôte (ex-DOCKER_UID).
    #   APP_UID=$(id -u) ./manage.sh build all
    build_one() {
        local ctx="$1" tag="$2"
        [ -d "$ctx" ] || err "Dépôt introuvable : $ctx (les dépôts doivent être clonés côte à côte)"
        log "Construction de $tag depuis $ctx..."
        $PODMAN build --build-arg APP_UID="${APP_UID:-1000}" -t "$tag" "$ctx"
    }
    case "$WHAT" in
      api)       build_one "$REPOS_DIR/docsearch-api"       "$IMAGE_API" ;;
      ingestion) build_one "$REPOS_DIR/docsearch-ingestion" "$IMAGE_INGESTION" ;;
      ui)        build_one "$REPOS_DIR/docsearch-ui-vue"    "$IMAGE_UI" ;;
      all)
        build_one "$REPOS_DIR/docsearch-api"       "$IMAGE_API"
        build_one "$REPOS_DIR/docsearch-ingestion" "$IMAGE_INGESTION"
        build_one "$REPOS_DIR/docsearch-ui-vue"    "$IMAGE_UI"
        ;;
      *) err "Usage : sudo ./manage.sh build [all|api|ingestion|ui]" ;;
    esac
    log "Terminé. Redémarrer les unités concernées : sudo ./manage.sh restart"
    ;;

  dev-user)
    # Régénère la configuration du proxy de simulation d'utilisateur.
    # La substitution se fait ICI (et non au démarrage du conteneur) :
    # une unité Quadlet ne peut pas porter proprement un "sh -c" avec
    # sed et guillemets imbriqués.
    require_root
    USER_NAME="${2:-}"
    [ -n "$USER_NAME" ] || err "Usage : sudo ./manage.sh dev-user <login>
  Exemple : sudo ./manage.sh dev-user alice.admin
  Puis http://localhost:8090/ (ou http://192.168.56.101:8090/)"
    TEMPLATE="$CONFIG_DIR/nginx/dev-user-proxy.conf.template"
    [ -f "$TEMPLATE" ] || err "$TEMPLATE introuvable (rôle « dev » uniquement)."
    sed -e "s/__TEST_X_USER__/$USER_NAME/g" \
        -e "s/__TEST_UI_TARGET__/ui-vue/g" \
        "$TEMPLATE" > "$CONFIG_DIR/nginx/dev-user-proxy.conf"
    log "Utilisateur simulé : $USER_NAME"
    systemctl restart docsearch-dev-user-proxy 2>/dev/null \
      || systemctl start docsearch-dev-user-proxy
    log "Proxy prêt : http://localhost:8090/"
    # L'API ignore l'en-tête X-User sauf harnais explicite (elle refuse
    # même de démarrer si API_ENV=production). Sans ce rappel, le proxy
    # semble marcher et toutes les pages répondent 401 sans expliquer
    # pourquoi.
    if ! grep -qE '^TRUST_X_USER_HEADER=true' "$CONFIG_DIR/docsearch.env" 2>/dev/null; then
      log "⚠️  TRUST_X_USER_HEADER n'est pas à true dans $CONFIG_DIR/docsearch.env :"
      log "    l'API ignorera l'identité injectée par ce proxy et répondra 401."
      log "    Poser TRUST_X_USER_HEADER=true et API_ENV=development, puis :"
      log "    sudo systemctl restart docsearch-api"
    fi
    ;;

  add-file-source)
    NAME="${2:-}"
    INDEX="${3:-}"
    if [ -z "$NAME" ] || [ -z "$INDEX" ]; then
        err "Usage : sudo ./manage.sh add-file-source <nom> <index_es> [--subfolder <sous-dossier>] [--label <libellé>]
  Exemple : mkdir -p \${SOURCES_ROOT:-/data/docsearch-sources}/finance
            ./manage.sh add-file-source finance finance_docs --label Finance
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

    init_run python3 -c "
from file_sources_config import add_source
import json
cfg = add_source($PY_ARGS)
print(json.dumps(cfg, indent=2, ensure_ascii=False))
"
    log "Source '$NAME' enregistrée — le watcher commence à l'observer sous ~5s (sans redémarrage)."
    log "Lancer l'indexation initiale : ./manage.sh init $NAME"
    ;;

  list-file-sources)
    init_run python3 -c "
from file_sources_config import get_sources
import json
print(json.dumps({n: {'es_index': s.es_index, 'folder': s.folder, 'label': s.label} for n, s in get_sources().items()}, indent=2, ensure_ascii=False))
"
    ;;

  remove-file-source)
    NAME="${2:-}"
    if [ -z "$NAME" ]; then
        err "Usage : sudo ./manage.sh remove-file-source <nom>
  Retire la source du registre (le watcher arrête de l'observer) — NE
  supprime PAS l'index Elasticsearch ni les documents déjà indexés.
  Utiliser ensuite 'purge-path' pour nettoyer l'existant si besoin."
    fi
    init_run python3 -c "
from file_sources_config import remove_source
import json
print(json.dumps(remove_source('$NAME'), indent=2, ensure_ascii=False))
"
    log "Source '$NAME' retirée du registre."
    warn "L'index Elasticsearch associé n'a PAS été supprimé (voir purge-path pour nettoyer)."
    ;;

  add-sql-source)
    NAME="${2:-}"
    DB_TYPE="${3:-}"
    CONN_REF="${4:-}"
    QUERY="${5:-}"
    ID_COLUMN="${6:-}"
    ES_INDEX_ARG="${7:-}"
    FIELDS_JSON="${8:-}"
    if [ -z "$NAME" ] || [ -z "$DB_TYPE" ] || [ -z "$CONN_REF" ] || [ -z "$QUERY" ] \
       || [ -z "$ID_COLUMN" ] || [ -z "$ES_INDEX_ARG" ] || [ -z "$FIELDS_JSON" ]; then
        err "Usage : sudo ./manage.sh add-sql-source <nom> <postgresql|mysql> <connection_ref> <requête_sql> <id_column> <index_es> <fields_json> [--poll-interval secondes] [--label <libellé>]

  connection_ref : NOM d'une variable d'environnement contenant le DSN
                    complet (définie dans .env), JAMAIS le DSN lui-même
                    (le mot de passe ne doit jamais transiter par Redis).
  fields_json    : mapping colonnes -> champs ES (JSON), ex :
                    '[{\"column\":\"id\",\"es_field\":\"id\",\"es_type\":\"keyword\"},
                      {\"column\":\"nom\",\"es_field\":\"nom\",\"es_type\":\"text\",\"analyzer\":\"french\"}]'
                    es_type possibles : keyword, text, long, double, date, boolean.
                    Toute colonne renvoyée par la requête mais absente de ce mapping est ignorée.

  Exemple :
    echo 'CLIENTS_DB_DSN=postgresql+psycopg2://user:pass@host:5432/db' >> .env
    ./manage.sh add-sql-source clients postgresql CLIENTS_DB_DSN \\
      \"SELECT id, nom, email FROM clients WHERE actif = true\" id clients_sql \\
      '[{\"column\":\"id\",\"es_field\":\"id\",\"es_type\":\"keyword\"},{\"column\":\"nom\",\"es_field\":\"nom\",\"es_type\":\"text\"},{\"column\":\"email\",\"es_field\":\"email\",\"es_type\":\"keyword\"}]' \\
      --poll-interval 300"
    fi
    shift 8
    POLL_ARG=""
    LABEL_ARG=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --poll-interval) POLL_ARG="$2"; shift 2 ;;
            --label)         LABEL_ARG="$2"; shift 2 ;;
            *) err "Option inconnue : $1" ;;
        esac
    done

    # Passage par variables d'environnement plutôt que par interpolation
    # directe dans le script python -c : QUERY et FIELDS_JSON contiennent
    # des guillemets et espaces qui casseraient toute tentative
    # d'interpolation shell dans une chaîne python littérale.
    export SQL_SRC_NAME="$NAME" SQL_SRC_DB_TYPE="$DB_TYPE" SQL_SRC_CONN_REF="$CONN_REF" \
           SQL_SRC_QUERY="$QUERY" SQL_SRC_ID_COLUMN="$ID_COLUMN" SQL_SRC_ES_INDEX="$ES_INDEX_ARG" \
           SQL_SRC_FIELDS_JSON="$FIELDS_JSON" SQL_SRC_POLL_INTERVAL="${POLL_ARG:-300}" \
           SQL_SRC_LABEL="$LABEL_ARG"

    init_run \
      -e SQL_SRC_NAME -e SQL_SRC_DB_TYPE -e SQL_SRC_CONN_REF -e SQL_SRC_QUERY \
      -e SQL_SRC_ID_COLUMN -e SQL_SRC_ES_INDEX -e SQL_SRC_FIELDS_JSON -e SQL_SRC_POLL_INTERVAL \
      -e SQL_SRC_LABEL \
      python3 -c "
import os, json
from sql_sources_config import add_source
cfg = add_source(
    name=os.environ['SQL_SRC_NAME'],
    db_type=os.environ['SQL_SRC_DB_TYPE'],
    connection_ref=os.environ['SQL_SRC_CONN_REF'],
    query=os.environ['SQL_SRC_QUERY'],
    id_column=os.environ['SQL_SRC_ID_COLUMN'],
    es_index=os.environ['SQL_SRC_ES_INDEX'],
    fields=json.loads(os.environ['SQL_SRC_FIELDS_JSON']),
    poll_interval_seconds=int(os.environ['SQL_SRC_POLL_INTERVAL']),
    label=os.environ['SQL_SRC_LABEL'] or None,
)
print(json.dumps(cfg, indent=2, ensure_ascii=False))
"
    log "Source SQL '$NAME' enregistrée — sql-worker commence à l'interroger sous ~5s (sans redémarrage)."
    warn "Vérifiez que '$CONN_REF' est bien défini dans .env (DSN complet) — jamais stocké dans Redis."
    log "Déclencher un premier passage sans attendre poll_interval_seconds : ./manage.sh run-sql-source $NAME"
    ;;

  list-sql-sources)
    init_run python3 -c "
from sql_sources_config import get_sources
import json
print(json.dumps({n: {
    'db_type':               s.db_type,
    'connection_ref':        s.connection_ref,
    'es_index':               s.es_index,
    'id_column':              s.id_column,
    'poll_interval_seconds':  s.poll_interval_seconds,
    'label':                  s.label,
    'fields':                 [f.__dict__ for f in s.fields],
} for n, s in get_sources().items()}, indent=2, ensure_ascii=False))
"
    ;;

  remove-sql-source)
    NAME="${2:-}"
    if [ -z "$NAME" ]; then
        err "Usage : sudo ./manage.sh remove-sql-source <nom>
  Retire la source du registre (sql-worker arrête de l'interroger) — NE
  supprime PAS l'index Elasticsearch ni les documents déjà indexés."
    fi
    init_run python3 -c "
from sql_sources_config import remove_source
import json
print(json.dumps(remove_source('$NAME'), indent=2, ensure_ascii=False))
"
    log "Source SQL '$NAME' retirée du registre."
    warn "L'index Elasticsearch associé n'a PAS été supprimé."
    ;;

  run-sql-source)
    NAME="${2:-}"
    if [ -z "$NAME" ]; then
        err "Usage : sudo ./manage.sh run-sql-source <nom>
  Déclenche immédiatement un passage complet pour cette source (upsert +
  réconciliation), sans attendre poll_interval_seconds — utile pour
  tester une source qui vient d'être ajoutée."
    fi
    log "Passage manuel [$NAME]..."
    # Le DSN référencé par connection_ref (ex: CLIENTS_DB_DSN) doit être
    # visible DANS le conteneur : c'est le --env-file de init_run, qui
    # injecte tout /etc/docsearch/docsearch.env, qui le rend disponible.
    init_run python3 sql_indexer.py "$NAME"
    ;;

  add-web-source)
    NAME="${2:-}"
    CRAWL_INDEX="${3:-}"
    ES_INDEX_ARG="${4:-}"
    if [ -z "$NAME" ] || [ -z "$CRAWL_INDEX" ] || [ -z "$ES_INDEX_ARG" ]; then
        err "Usage : sudo ./manage.sh add-web-source <nom> <crawl_index> <index_es> [--poll-interval secondes] [--private] [--label <libellé>]

  crawl_index : index ES intermédiaire dans lequel Elastic Open Web Crawler
                écrit (son 'output_index' à lui, schéma brut du crawler :
                url, title, body...) — DIFFÉRENT de <index_es>.
  index_es    : index ES final DocSearch (schéma commun filepath/content/
                acl), rejoint automatiquement ES_SEARCH_ALIAS.
  --private   : marque les pages acl.public=false au lieu de true (défaut :
                public — adapté à un site web accessible sans authentification).

  Exemple :
    ./manage.sh add-web-source cc_decisions cc_decisions_raw cc_decisions --poll-interval 3600"
    fi
    shift 4
    POLL_ARG=""
    PUBLIC_ARG="true"
    LABEL_ARG=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --poll-interval) POLL_ARG="$2"; shift 2 ;;
            --private) PUBLIC_ARG="false"; shift ;;
            --label) LABEL_ARG="$2"; shift 2 ;;
            *) err "Option inconnue : $1" ;;
        esac
    done

    export WEB_SRC_NAME="$NAME" WEB_SRC_CRAWL_INDEX="$CRAWL_INDEX" WEB_SRC_ES_INDEX="$ES_INDEX_ARG" \
           WEB_SRC_POLL_INTERVAL="${POLL_ARG:-3600}" WEB_SRC_PUBLIC="$PUBLIC_ARG" \
           WEB_SRC_LABEL="$LABEL_ARG"

    init_run \
      -e WEB_SRC_NAME -e WEB_SRC_CRAWL_INDEX -e WEB_SRC_ES_INDEX -e WEB_SRC_POLL_INTERVAL -e WEB_SRC_PUBLIC \
      -e WEB_SRC_LABEL \
      python3 -c "
import os, json
from web_sources_config import add_source
cfg = add_source(
    name=os.environ['WEB_SRC_NAME'],
    crawl_index=os.environ['WEB_SRC_CRAWL_INDEX'],
    es_index=os.environ['WEB_SRC_ES_INDEX'],
    acl_public=(os.environ['WEB_SRC_PUBLIC'] == 'true'),
    poll_interval_seconds=int(os.environ['WEB_SRC_POLL_INTERVAL']),
    label=os.environ['WEB_SRC_LABEL'] or None,
)
print(json.dumps(cfg, indent=2, ensure_ascii=False))
"
    log "Source web '$NAME' enregistrée — web-worker commence à la synchroniser sous ~5s (sans redémarrage)."
    warn "Vérifiez que Elastic Open Web Crawler est bien configuré avec output_index: $CRAWL_INDEX pour ce site."
    log "Déclencher un premier passage sans attendre poll_interval_seconds : ./manage.sh run-web-source $NAME"
    ;;

  list-web-sources)
    init_run python3 -c "
from web_sources_config import get_sources
import json
print(json.dumps({n: {
    'crawl_index':            s.crawl_index,
    'es_index':               s.es_index,
    'acl_public':             s.acl_public,
    'poll_interval_seconds':  s.poll_interval_seconds,
    'label':                  s.label,
} for n, s in get_sources().items()}, indent=2, ensure_ascii=False))
"
    ;;

  remove-web-source)
    NAME="${2:-}"
    if [ -z "$NAME" ]; then
        err "Usage : sudo ./manage.sh remove-web-source <nom>
  Retire la source du registre (web-worker arrête de la synchroniser) — NE
  supprime PAS les index Elasticsearch (crawl_index ni es_index) ni les
  documents déjà indexés."
    fi
    init_run python3 -c "
from web_sources_config import remove_source
import json
print(json.dumps(remove_source('$NAME'), indent=2, ensure_ascii=False))
"
    log "Source web '$NAME' retirée du registre."
    warn "Les index Elasticsearch associés n'ont PAS été supprimés."
    ;;

  run-web-source)
    NAME="${2:-}"
    if [ -z "$NAME" ]; then
        err "Usage : sudo ./manage.sh run-web-source <nom>
  Déclenche immédiatement un passage complet pour cette source (upsert +
  réconciliation depuis crawl_index), sans attendre poll_interval_seconds —
  utile pour tester une source qui vient d'être ajoutée, une fois qu'Elastic
  Open Web Crawler a terminé au moins un crawl."
    fi
    log "Passage manuel [$NAME]..."
    init_run python3 web_indexer.py "$NAME"
    ;;

  set-config)
    KEY="${2:-}"
    VALUE="${3:-}"
    if [ -z "$KEY" ] || [ -z "$VALUE" ]; then
        err "Usage : sudo ./manage.sh set-config <clé> <valeur>
  Clés disponibles : archive_max_files, archive_max_total_size_mb,
                      archive_max_depth, worker_batch_size,
                      worker_flush_interval, watcher_poll_interval,
                      ocr_languages, ocr_strategy"
    fi
    init_run python3 -c "
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
    init_run python3 -c "
from runtime_config import get_runtime_config
import json
print(json.dumps(get_runtime_config(), indent=2, ensure_ascii=False))
"
    ;;

  exclude-path)
    PATTERN="${2:-}"
    SOURCE="${3:-documents}"
    if [ -z "$PATTERN" ]; then
        err "Usage : sudo ./manage.sh exclude-path <motif> [source]
  Exemples : ./manage.sh exclude-path finance/confidentiel
             ./manage.sh exclude-path '*/tmp' finance
             ./manage.sh exclude-path '*.cache'"
    fi
    init_run python3 -c "
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
        err "Usage : sudo ./manage.sh include-path <motif> [source]
  Bascule en liste blanche : si au moins un motif est inclus, SEULS
  les chemins correspondants sont indexés (l'exclusion reste prioritaire)."
    fi
    init_run python3 -c "
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
        err "Usage : sudo ./manage.sh remove-path-filter <motif> [source]"
    fi
    init_run python3 -c "
from path_filter import remove_filter
import json
print(json.dumps(remove_filter('$PATTERN', '$SOURCE'), indent=2, ensure_ascii=False))
"
    log "Motif '$PATTERN' retiré de la source '$SOURCE' (des deux listes s'il y était)."
    ;;

  list-path-filters)
    SOURCE="${2:-documents}"
    init_run python3 -c "
from path_filter import get_config
import json
print(json.dumps(get_config('$SOURCE'), indent=2, ensure_ascii=False))
"
    ;;

  purge-path)
    PATTERN="${2:-}"
    SOURCE="${3:-documents}"
    if [ -z "$PATTERN" ]; then
        err "Usage : sudo ./manage.sh purge-path <motif> [source]
  Supprime de l'INDEX (pas du disque) les documents déjà indexés dont
  le chemin correspond au motif — même syntaxe glob que exclude-path.
  Utile après un exclude-path : ce dernier n'agit que sur les futurs
  passages, purge-path nettoie l'existant.
  Exemples :
    ./manage.sh purge-path finance/confidentiel
    ./manage.sh purge-path '*/tmp' finance"
    fi

    log "Aperçu (aucune suppression) — documents déjà indexés (source '$SOURCE') correspondant à '$PATTERN' :"
    init_run python3 -c "
from file_sources_config import get_source
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

    init_run python3 -c "
from file_sources_config import get_source
from indexer import purge_path
n = purge_path('$PATTERN', get_source('$SOURCE'), dry_run=False)
print(f'{n} document(s) supprimé(s) de l\'index.')
"
    log "Purge terminée."
    ;;

  set-filetype)
    EXT="${2:-}"
    if [ -z "$EXT" ]; then
        err "Usage : sudo ./manage.sh set-filetype <extension> [--enabled true|false] [--max-size Mo] [--source <nom>]
  Sans --source, s'applique à la source par défaut ('documents') — chaque
  source a sa propre configuration de types de fichiers, indépendante."
    fi
    shift 2
    ENABLED_ARG=""
    MAXSIZE_ARG=""
    SOURCE_ARG="documents"
    while [ $# -gt 0 ]; do
        case "$1" in
            --enabled)  ENABLED_ARG="$2"; shift 2 ;;
            --max-size) MAXSIZE_ARG="$2"; shift 2 ;;
            --source)   SOURCE_ARG="$2"; shift 2 ;;
            *) err "Option inconnue : $1" ;;
        esac
    done

    PY_ARGS="extension=\"$EXT\", source=\"$SOURCE_ARG\""
    [ -n "$ENABLED_ARG" ]  && PY_ARGS="$PY_ARGS, enabled=$([ "$ENABLED_ARG" = "true" ] && echo True || echo False)"
    [ -n "$MAXSIZE_ARG" ]  && PY_ARGS="$PY_ARGS, max_size_mb=$MAXSIZE_ARG"

    init_run python3 -c "
from filetype_config import set_filetype
import json
cfg = set_filetype($PY_ARGS)
print(json.dumps(cfg, indent=2, ensure_ascii=False))
"
    log "Configuration mise à jour pour la source '$SOURCE_ARG' — effective immédiatement (cache de ${FILETYPE_CONFIG_CACHE_TTL:-10}s max) sur les workers/watcher/producer déjà démarrés."
    ;;

  get-filetypes)
    SOURCE="${2:-documents}"
    init_run python3 -c "
from filetype_config import get_config
import json
print(json.dumps(get_config('$SOURCE'), indent=2, ensure_ascii=False))
"
    ;;

  reset)
    require_root
    warn "⚠️  Cette commande supprime TOUTES les données."
    read -rp "Confirmer ? (oui/non) : " CONFIRM
    [ "$CONFIRM" = "oui" ] || { log "Annulé."; exit 0; }
    systemctl stop "$TARGET"
    # Les volumes créés par Quadlet portent selon la version un préfixe
    # "systemd-" : on les retrouve au lieu de les supposer. Les données
    # montées depuis l'hôte (/data/es) ne sont PAS touchées ici.
    VOLUMES=$($PODMAN volume ls --format '{{.Name}}' 2>/dev/null \
              | grep -E '^(systemd-)?(es01|es-voting|kafka|redis)-data$' || true)
    if [ -n "$VOLUMES" ]; then
        # shellcheck disable=SC2086  # liste de noms, découpage voulu
        $PODMAN volume rm -f $VOLUMES
        log "Volumes supprimés : $(echo "$VOLUMES" | tr '\n' ' ')"
    else
        warn "Aucun volume DocSearch trouvé."
    fi
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
    echo "    start           Démarrer la pile (sudo — systemctl start docsearch.target)"
    echo "    stop            Arrêter la pile (sudo)"
    echo "    restart         Redémarrer la pile (sudo)"
    echo "    status          État des unités + stats Elasticsearch"
    echo "    logs [service]  Journaux en temps réel (journalctl) — 'logs worker'"
    echo "                    suit toutes les unités worker à la fois"
    echo "    build [cible]   Construire les images (all|api|ingestion|ui) — machine CONNECTÉE (sudo)"
    echo "    dev-user <login>  Régler l'utilisateur simulé du proxy de développement (sudo)"
    echo "    init [source] [sous-dossier]"
    echo "                    Indexation d'une source (défaut : 'documents'), complète"
    echo "                    ou restreinte à un sous-dossier de son répertoire"
    echo "    scale-workers N Ajuster le nombre d'unités worker (sudo)"
    echo "    add-file-source <nom> <index_es> [--subfolder ...] [--label ...]"
    echo "                    Enregistrer une nouvelle source à indexer — sans"
    echo "                    redémarrage ni reconstruction, voir SOURCES_HOST_PATH"
    echo "                    dans /etc/docsearch/docsearch.env"
    echo "    list-file-sources    Lister les sources fichiers enregistrées"
    echo "    remove-file-source <nom>"
    echo "                    Retirer une source du registre (ne supprime PAS son index)"
    echo "    add-sql-source <nom> <postgresql|mysql> <connection_ref> <requête> <id_column> <index_es> <fields_json> [--poll-interval s] [--label ...]"
    echo "                    Enregistrer une source SQL (résultat de requête indexé dans ES)"
    echo "    list-sql-sources        Lister les sources SQL enregistrées"
    echo "    remove-sql-source <nom> Retirer une source SQL du registre (ne supprime PAS son index)"
    echo "    run-sql-source <nom>    Déclencher un passage manuel immédiat (sans attendre poll_interval)"
    echo "    add-web-source <nom> <crawl_index> <index_es> [--poll-interval s] [--private] [--label ...]"
    echo "                    Enregistrer une source web (crawl_index = output_index d'Elastic"
    echo "                    Open Web Crawler pour ce site, index_es = index DocSearch final)"
    echo "    list-web-sources        Lister les sources web enregistrées"
    echo "    remove-web-source <nom> Retirer une source web du registre (ne supprime PAS ses index)"
    echo "    run-web-source <nom>    Déclencher un passage manuel immédiat (sans attendre poll_interval)"
    echo "    set-filetype <ext> [--enabled true|false] [--max-size Mo] [--source <nom>]"
    echo "                    Activer/désactiver un type de fichier ou fixer sa taille max,"
    echo "                    pour une source donnée (défaut 'documents' — chaque source a"
    echo "                    sa propre config, effectif immédiatement — cache 10s max)"
    echo "    get-filetypes [source]"
    echo "                    Afficher la configuration par type de fichier d'une source"
    echo "    set-config <clé> <valeur>"
    echo "                    Modifier un paramètre opérationnel (archive_max_depth,"
    echo "                    worker_flush_interval, watcher_poll_interval, ocr_languages,"
    echo "                    ocr_strategy, etc.) — l'ACTIVATION de l'OCR (Tesseract via Tika)"
    echo "                    se fait par source, via l'admin UI ou POST"
    echo "                    /admin/file-sources/<nom>/ocr (pas de flag manage.sh dédié,"
    echo "                    même convention que searchable/collectable)"
    echo "    get-config      Afficher tous les paramètres opérationnels actuels"
    echo "    exclude-path <motif> [source]       Exclure un sous-dossier de l'indexation (glob)"
    echo "    include-path <motif> [source]       Passer en liste blanche (n'indexer QUE ces chemins)"
    echo "    remove-path-filter <motif> [source] Retirer un motif d'inclusion/exclusion"
    echo "    list-path-filters [source]          Afficher les filtres de chemin actuels"
    echo "    purge-path <motif> [source]         Supprimer de l'index les documents déjà"
    echo "                                        indexés correspondant au motif (avec confirmation)"
    echo "    backup          Snapshot Elasticsearch"
    echo "    reset           Supprimer toutes les données (irréversible, sudo)"
    echo ""
    echo "  ⚠️  Toutes les commandes d'administration (init, add-*-source,"
    echo "     set-config, set-filetype, exclude-path, purge-path...) lancent un"
    echo "     conteneur jetable sur le réseau de la pile : elles exigent sudo,"
    echo "     comme start/stop/restart. Seules status, logs, get-config et les"
    echo "     list-* fonctionnent sans."
    echo ""
    echo "  Installation des unités (une fois par machine) :"
    echo "    sudo ./quadlet/install-units.sh dev                    poste de développement"
    echo "    sudo ./quadlet/install-units.sh <rôle> [--workers N]   serveurs de production"
    echo "                    rôles : es-data, es-voting, kafka, frontend, ingest"
    echo ""
    echo "  Machine sans accès Internet :"
    echo "    Aucune construction n'a lieu au démarrage — les images doivent"
    echo "    déjà être présentes (podman load). Voir HOWTO-deploiement-hors-ligne.md"
    echo ""
    ;;
esac
