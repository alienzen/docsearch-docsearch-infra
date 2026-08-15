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

# ── Contrat partagé (contract/) ──────────────────────────────
# La source de vérité vit ici, dans docsearch-infra ; les dépôts
# consommateurs en portent une COPIE, versionnée avec eux. Pourquoi une
# copie plutôt qu'une dépendance installée :
#
#   - le contexte de `podman build` est le dépôt consommateur, qui ne
#     peut donc pas atteindre ../docsearch-infra au moment du build ;
#   - la production n'a pas Internet : il n'y a pas de registre de
#     paquets interne à interroger, et une roue vendorisée serait un
#     artefact binaire de plus à committer ;
#   - `podman build .` lancé à la main dans un dépôt consommateur doit
#     continuer de produire une image qui fonctionne.
#
# La copie est donc assumée — mais elle est GÉNÉRÉE et VÉRIFIÉE, ce qui
# est exactement ce qui manquait aux six copies de *_sources_config.py
# tenues à la main. Toute construction d'image contrôle la dérive avant
# de démarrer.
CONTRACT_SRC="$(cd "$(dirname "$0")" && pwd)/contract/docsearch_contract"
# Où chaque dépôt attend sa copie, relativement au dossier parent commun.
# `app/` et non `vendor/` : les modules Python de ces dépôts sont à plat
# dans l'image (COPY app/ .), un paquet déposé là est importable sans
# toucher ni au Dockerfile ni au sys.path des tests.
CONTRACT_CIBLES="docsearch-api/app/docsearch_contract docsearch-ingestion/app/docsearch_contract docsearch-plugin-assistant/app/docsearch_contract"

# Empreinte du contenu du contrat — sert à comparer source et copies.
# `find | sort` pour un ordre stable, le nom de fichier compte dans
# l'empreinte (un fichier renommé est une dérive).
contract_hash() {
    local dir="$1"
    [ -d "$dir" ] || { echo "ABSENT"; return 0; }
    (cd "$dir" && find . -name '*.py' -type f | sort | xargs sha256sum | sha256sum | cut -d' ' -f1)
}

sync_contract() {
    local mode="${1:-apply}"   # apply | check
    local repos_dir divergences=0
    repos_dir="$(cd "$(dirname "$0")/.." && pwd)"
    [ -d "$CONTRACT_SRC" ] || err "Contrat introuvable : $CONTRACT_SRC"

    local src_hash; src_hash="$(contract_hash "$CONTRACT_SRC")"

    for cible in $CONTRACT_CIBLES; do
        local dest="$repos_dir/$cible"
        local depot="${cible%%/*}"
        if [ ! -d "$repos_dir/$depot" ]; then
            warn "Dépôt absent, copie ignorée : $repos_dir/$depot"
            continue
        fi
        if [ "$(contract_hash "$dest")" = "$src_hash" ]; then
            [ "$mode" = "check" ] || log "Contrat déjà à jour : $cible"
            continue
        fi
        if [ "$mode" = "check" ]; then
            warn "Contrat DIVERGENT : $cible"
            divergences=$((divergences + 1))
            continue
        fi
        rm -rf "$dest"
        mkdir -p "$dest"
        cp "$CONTRACT_SRC"/*.py "$dest/"
        log "Contrat copié vers $cible"
    done

    if [ "$divergences" -gt 0 ]; then
        err "$divergences copie(s) du contrat divergent de docsearch-infra/contract/.
  La source de vérité est docsearch-infra/contract/docsearch_contract/ :
  y porter la modification, puis ./manage.sh sync-contract"
    fi
}

# ── Modules complémentaires (plugins) ────────────────────────
# Un module se livre en archive tar contenant deux fichiers :
#
#   manifeste.json   déclaration validée par le contrat partagé
#   image.tar        sortie de « podman save » de son image
#
# Le manifeste est un fichier SÉPARÉ et non une étiquette OCI de l'image,
# pour qu'il soit validé AVANT de charger quoi que ce soit : un manifeste
# refusé ne laisse rien derrière lui.
#
# Ce qui est machine-locale (l'image, l'unité systemd, le manifeste
# installé) vit sous /etc ; ce qui est commun à la grappe (les sources
# déclarées) va dans Redis, comme les autres registres. La distinction
# compte : réinstaller un module sur une seconde machine d'ingestion ne
# doit pas redéclarer ses sources.
PLUGINS_DIR="$CONFIG_DIR/plugins"
QUADLET_DIR="${DOCSEARCH_QUADLET_DIR:-/etc/containers/systemd}"
CONTRACT_DIR="$(cd "$(dirname "$0")" && pwd)/contract"

# Valide un manifeste avec le contrat partagé, SANS conteneur ni pile
# démarrée : la source de vérité du contrat est dans ce dépôt, à côté.
# Rend le manifeste normalisé sur la sortie standard.
valider_manifeste_json() {
    local fichier="$1"
    command -v python3 >/dev/null 2>&1 || err "python3 est requis pour valider un manifeste."
    MANIFESTE_FICHIER="$fichier" PYTHONPATH="$CONTRACT_DIR" python3 -c "
import json, os, sys
from docsearch_contract import valider_manifeste
try:
    with open(os.environ['MANIFESTE_FICHIER'], encoding='utf-8') as f:
        brut = json.load(f)
except json.JSONDecodeError as e:
    print(f'manifeste.json illisible : {e}', file=sys.stderr)
    sys.exit(1)
try:
    print(json.dumps(valider_manifeste(brut), ensure_ascii=False))
except ValueError as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
"
}

# Lit une clé du manifeste normalisé (JSON sur une ligne).
manifeste_lire() {
    MANIFESTE_JSON="$1" MANIFESTE_CLE="$2" python3 -c "
import json, os
m = json.loads(os.environ['MANIFESTE_JSON'])
v = m[os.environ['MANIFESTE_CLE']]
print(' '.join(v) if isinstance(v, list) else v)
"
}

# Noms des sources déclarées par un module installé, en JSON.
sources_du_manifeste() {
    MANIFESTE_FICHIER="$PLUGINS_DIR/$1.json" python3 -c "
import json, os
m = json.load(open(os.environ['MANIFESTE_FICHIER'], encoding='utf-8'))
print(json.dumps([s['nom'] for s in m['sources']]))
"
}

# ── Routage /ext/<nom>/ des modules à capacité service_web ────
# Un fragment nginx par module, dans un répertoire monté en lecture seule
# dans les conteneurs nginx. Pourquoi des fragments générés plutôt qu'un
# `location` générique avec variable : un proxy_pass qui contient une
# variable oblige nginx à résoudre le nom À CHAQUE REQUÊTE, donc à
# connaître un `resolver` — l'adresse du DNS de podman, qui change avec le
# réseau. Un fragment statique par module ne dépend de rien, et se relit
# en clair pour diagnostiquer.
NGINX_PLUGINS_DIR="$CONFIG_DIR/nginx/plugins"

ecrire_fragment_nginx() {
    local nom="$1" port="$2"
    mkdir -p "$NGINX_PLUGINS_DIR"
    cat > "$NGINX_PLUGINS_DIR/$nom.conf" <<EOF
# Généré par « ./manage.sh plugin install » — ne pas modifier à la main,
# la prochaine installation du module $nom écraserait ce fichier.
location /ext/$nom/ {
    # La barre oblique finale de proxy_pass RETIRE le préfixe : le module
    # reçoit /ask, pas /ext/$nom/ask. Il n'a donc pas à connaître son
    # point de montage — et le changer ne casse pas son code.
    proxy_pass http://plugin-$nom:$port/;
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    # Le cookie de session traverse (comportement par défaut) : c'est lui
    # que le module vérifie contre le JWKS de l'API. Aucun en-tête
    # d'identité n'est posé ici — le proxy n'authentifie pas.
}
EOF
}

recharger_nginx() {
    local recharge=0
    for conteneur in docsearch-ui-vue docsearch-nginx; do
        $PODMAN container exists "$conteneur" 2>/dev/null || continue
        if $PODMAN exec "$conteneur" nginx -s reload >/dev/null 2>&1; then
            log "$conteneur rechargé."
            recharge=1
        else
            warn "$conteneur : rechargement à chaud refusé — redémarrage."
            systemctl restart "$conteneur" 2>/dev/null && recharge=1
        fi
    done
    [ "$recharge" -eq 1 ] || warn "Aucun conteneur nginx en fonctionnement : le routage /ext/ prendra effet au prochain démarrage."
}

# Écrit l'unité Quadlet du module depuis quadlet/plugin.container.in.
# awk et non sed : la liste des secrets produit un nombre variable de
# lignes, ce qu'une substitution sed ne sait pas faire lisiblement.
ecrire_unite_plugin() {
    local nom="$1" image="$2" cpus="$3" memoire="$4" secrets="$5"
    local modele="$(dirname "$0")/quadlet/plugin.container.in"
    [ -f "$modele" ] || err "Modèle d'unité introuvable : $modele"
    awk -v nom="$nom" -v image="$image" -v cpus="$cpus" -v memoire="$memoire" \
        -v secrets="$secrets" -v bootstrap="${KAFKA_BOOTSTRAP:-kafka:9092}" \
        -v topic="${PLUGIN_TOPIC:-documents-ready}" '
        /@SECRETS@/ {
            n = split(secrets, liste, " ")
            for (i = 1; i <= n; i++) if (liste[i] != "") print "Secret=" liste[i]
            next
        }
        {
            gsub(/@NOM@/, nom); gsub(/@IMAGE@/, image)
            gsub(/@CPUS@/, cpus); gsub(/@MEMOIRE@/, memoire)
            gsub(/@KAFKA_BOOTSTRAP@/, bootstrap); gsub(/@TOPIC@/, topic)
            print
        }
    ' "$modele" > "$QUADLET_DIR/docsearch-plugin-$nom.container"
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
    # Le contrat partagé est copié dans les dépôts consommateurs : une
    # copie périmée produirait une image qui tourne avec d'anciennes
    # règles, sans que rien ne le signale. On refuse de construire, plutôt
    # que de synchroniser d'autorité — la copie est versionnée avec son
    # dépôt, la mettre à jour est un commit, pas un effet de bord de build.
    #
    # Seulement pour les cibles concernées : `build ui` n'a pas à échouer
    # parce que la copie de docsearch-api a dérivé.
    case "$WHAT" in
      api|ingestion|all) sync_contract check ;;
    esac
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

        # ── Identité de la livraison ──────────────────────────
        # La version PRODUIT est déclarée dans le fichier VERSION du
        # dépôt, la même dans les trois. L'estampille de build (commit +
        # date) est relevée ICI parce que la machine de construction est
        # le seul endroit à connaître git : le dépôt .git n'est pas copié
        # dans les images.
        local version commit dirty build_date
        version="$(tr -d '[:space:]' < "$ctx/VERSION" 2>/dev/null || true)"
        [ -n "$version" ] || err "$ctx/VERSION absent ou vide — c'est la source de la version produit."
        commit="$(git -C "$ctx" rev-parse --short HEAD 2>/dev/null || echo inconnu)"
        # Suffixe « +modifie » quand le dépôt porte des modifications non
        # commitées. C'est ce qui rend l'estampille réellement utile : une
        # image construite depuis un dépôt sale est un cas fréquent en
        # préparation de livraison, et strictement indiagnosticable après
        # coup si rien ne le signale.
        #
        # `status --porcelain` et non `diff --quiet` : les fichiers NON
        # SUIVIS comptent, puisque le `COPY app/ .` des Containerfile les
        # embarque dans l'image comme les autres.
        dirty=""
        [ -z "$(git -C "$ctx" status --porcelain 2>/dev/null)" ] || dirty="+modifie"
        build_date="$(date -Is)"

        log "Construction de $tag depuis $ctx (version $version, commit ${commit}${dirty})..."
        $PODMAN build \
            --build-arg APP_UID="${APP_UID:-1000}" \
            --build-arg DOCSEARCH_VERSION="$version" \
            --build-arg DOCSEARCH_COMMIT="${commit}${dirty}" \
            --build-arg DOCSEARCH_BUILD_DATE="$build_date" \
            -t "$tag" -t "${tag%:latest}:$version" \
            "$ctx"

        # Double tag : les unités Quadlet continuent de viser ":latest" —
        # le vecteur de déploiement est un `podman load` d'une archive
        # précise, pas un `pull` depuis un registre, donc le tag flottant
        # ne provoque pas ici la dérive que proscrit la règle « aucun tag
        # flottant » de HOWTO-deploiement-hors-ligne.md (laquelle vise les
        # images TIERCES, tirées d'un registre). Le tag versionné existe à
        # côté pour que `podman images` garde une trace auditable de ce
        # qui a été chargé sur chaque machine.
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

  add-plugin-source)
    NAME="${2:-}"
    PLUGIN_ARG="${3:-}"
    ES_INDEX_ARG="${4:-}"
    ACL_POLICY_ARG="${5:-}"
    if [ -z "$NAME" ] || [ -z "$PLUGIN_ARG" ] || [ -z "$ES_INDEX_ARG" ] || [ -z "$ACL_POLICY_ARG" ]; then
        err "Usage : sudo ./manage.sh add-plugin-source <nom> <module> <index_es> <public|groupes|fournie> [options]

  <module>    nom du module complémentaire AUTORISÉ à pousser sur cette source.
              C'est le seul contrôle qui empêche un module d'écrire dans la
              source d'un autre : un message émis par un autre module est refusé.
  <politique> comment l'ACL des documents est décidée — par l'ADMINISTRATEUR,
              jamais par le module :
                public   tous les documents sont publics
                groupes  ACL fixe, exige --groupes
                fournie  le module fournit users/groups par document, filtrés
                         contre --principaux (obligatoire, une liste vide est
                         REFUSÉE — elle se lirait comme « aucune restriction »)
              'acl.public' proposé par un module est ignoré dans les trois cas.

  Options :
    --groupes g1,g2       groupes de la politique 'groupes'
    --principaux p1,p2    liste blanche de la politique 'fournie' (users ET groups)
    --fields JSON         champs supplémentaires, ex :
                          '[{\"nom\":\"bureau\",\"es_type\":\"keyword\",\"facet\":true}]'
    --label <libellé>     libellé affiché dans la recherche
    --description <texte>

  Exemple :
    ./manage.sh add-plugin-source tickets jira tickets_jira groupes --groupes DL-SUPPORT --label Tickets"
    fi
    shift 5
    GROUPES_ARG=""; PRINCIPAUX_ARG=""; FIELDS_ARG="[]"; LABEL_ARG=""; DESC_ARG=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --groupes)     GROUPES_ARG="$2"; shift 2 ;;
            --principaux)  PRINCIPAUX_ARG="$2"; shift 2 ;;
            --fields)      FIELDS_ARG="$2"; shift 2 ;;
            --label)       LABEL_ARG="$2"; shift 2 ;;
            --description) DESC_ARG="$2"; shift 2 ;;
            *) err "Option inconnue : $1" ;;
        esac
    done

    export PLG_NAME="$NAME" PLG_PLUGIN="$PLUGIN_ARG" PLG_ES_INDEX="$ES_INDEX_ARG" \
           PLG_ACL_POLICY="$ACL_POLICY_ARG" PLG_GROUPES="$GROUPES_ARG" \
           PLG_PRINCIPAUX="$PRINCIPAUX_ARG" PLG_FIELDS="$FIELDS_ARG" \
           PLG_LABEL="$LABEL_ARG" PLG_DESC="$DESC_ARG"

    init_run \
      -e PLG_NAME -e PLG_PLUGIN -e PLG_ES_INDEX -e PLG_ACL_POLICY -e PLG_GROUPES \
      -e PLG_PRINCIPAUX -e PLG_FIELDS -e PLG_LABEL -e PLG_DESC \
      python3 -c "
import os, json, sys
from plugin_sources_config import add_source

def liste(valeur):
    return [x.strip() for x in valeur.split(',') if x.strip()]

try:
    cfg = add_source(
        name=os.environ['PLG_NAME'],
        plugin=os.environ['PLG_PLUGIN'],
        es_index=os.environ['PLG_ES_INDEX'],
        acl_policy=os.environ['PLG_ACL_POLICY'],
        acl_groups=liste(os.environ['PLG_GROUPES']),
        acl_principaux=liste(os.environ['PLG_PRINCIPAUX']),
        fields=json.loads(os.environ['PLG_FIELDS'] or '[]'),
        label=os.environ['PLG_LABEL'] or None,
        description=os.environ['PLG_DESC'] or None,
    )
except ValueError as e:
    # ContratInvalide hérite de ValueError : le message dit quoi corriger.
    print(f'❌ {e}', file=sys.stderr)
    sys.exit(1)
print(json.dumps(cfg[os.environ['PLG_NAME']], indent=2, ensure_ascii=False))
"
    log "Source plugin '$NAME' enregistrée (module « $PLUGIN_ARG », politique « $ACL_POLICY_ARG »)."
    log "Le worker indexera ce que « $PLUGIN_ARG » poussera sur le topic documents-ready, sans redémarrage."
    ;;

  list-plugin-sources)
    init_run python3 -c "
from plugin_sources_config import get_sources
import json
print(json.dumps({n: {
    'plugin':         s.plugin,
    'es_index':       s.es_index,
    'acl_policy':     s.acl_policy,
    'acl_groups':     list(s.acl_groups),
    'acl_principaux': list(s.acl_principaux),
    'fields':         [c.nom for c in s.fields],
    'label':          s.label,
    'searchable':     s.searchable,
} for n, s in get_sources().items()}, indent=2, ensure_ascii=False))
"
    ;;

  remove-plugin-source)
    NAME="${2:-}"
    if [ -z "$NAME" ]; then
        err "Usage : sudo ./manage.sh remove-plugin-source <nom>
  Retire la source du registre — le worker cesse d'accepter ce que le module
  pousse dessus. NE supprime PAS l'index Elasticsearch ni les documents déjà
  indexés (mais ils sortent de la recherche : plus aucune source ne les
  déclare)."
    fi
    init_run python3 -c "
from plugin_sources_config import remove_source
import json
print(json.dumps(remove_source('$NAME'), indent=2, ensure_ascii=False))
"
    log "Source plugin '$NAME' retirée du registre."
    warn "L'index Elasticsearch associé n'a PAS été supprimé."
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

  migrer-synonymes)
    SOURCE="${2:-}"
    log "Application de l'analyseur de synonymes aux index de documents."
    warn "Chaque index est FERMÉ quelques secondes puis rouvert — la recherche y est indisponible pendant ce temps. AUCUNE réindexation n'a lieu."
    init_run python3 -c "
from file_sources_config import get_sources, get_source
from indexer import migrer_analyse
import json
sources = {'$SOURCE': get_source('$SOURCE')} if '$SOURCE' else get_sources()
for nom, source in sources.items():
    print(json.dumps({'source': nom, **migrer_analyse(source)}, ensure_ascii=False))
"
    log "Terminé. Le thésaurus se règle ensuite depuis le panneau d'administration, à chaud."
    ;;

  migrer-exact)
    SOURCE=""
    APPLY=""
    for arg in "${@:2}"; do
        case "$arg" in
          --apply) APPLY="1" ;;
          *)       SOURCE="$arg" ;;
        esac
    done
    if [ -z "$APPLY" ]; then
        log "Simulation (aucune écriture). Ajouter --apply pour migrer."
    else
        warn "Chaque index est FERMÉ quelques secondes puis rouvert, puis ses documents sont RÉÉCRITS SUR PLACE pour remplir les sous-champs de recherche exacte."
        warn "La réécriture est lancée en tâche de fond côté Elasticsearch : la commande rend la main avant sa fin. Suivre avec GET _tasks/<tâche>."
    fi
    init_run python3 -c "
import json
from indexer import migrer_exact
from file_sources_config import get_sources as sources_fichiers
from sql_sources_config import get_sources as sources_sql
from web_sources_config import get_sources as sources_web

# Les trois familles, pas seulement les sources fichiers : elles
# partagent l'alias de recherche fédérée, et un index oublié ici serait
# simplement muet en recherche exacte, sans la moindre erreur.
toutes = {}
for famille in (sources_fichiers, sources_sql, sources_web):
    for nom, source in famille().items():
        toutes[nom] = source
if '$SOURCE':
    toutes = {'$SOURCE': toutes['$SOURCE']}
for nom, source in toutes.items():
    print(json.dumps(
        {'source': nom, **migrer_exact(source.es_index, appliquer=bool('$APPLY'))},
        ensure_ascii=False,
    ))
"
    ;;

  backfill-hashes)
    SOURCE=""
    APPLY=""
    for arg in "${@:2}"; do
        case "$arg" in
          --apply) APPLY="--apply" ;;
          *)       SOURCE="$arg" ;;
        esac
    done
    if [ -z "$APPLY" ]; then
        log "Simulation (aucune écriture). Ajouter --apply pour écrire."
    fi
    init_run python3 backfill_hashes.py $SOURCE $APPLY
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

  plugin)
    SOUS="${2:-}"
    case "$SOUS" in

      install)
        require_root
        ARCHIVE="${3:-}"
        [ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ] \
          || err "Usage : sudo ./manage.sh plugin install <archive.tar>

  L'archive contient deux fichiers, à sa racine :
    manifeste.json   déclaration du module (voir contract/docsearch_contract/manifeste.py)
    image.tar        sortie de « podman save » de son image

  Le manifeste est validé AVANT tout chargement : un module refusé ne
  laisse ni image, ni unité, ni source enregistrée."

        TMP_PLUGIN="$(mktemp -d)"
        # shellcheck disable=SC2064  # expansion voulue à la définition
        trap "rm -rf '$TMP_PLUGIN'" EXIT
        tar -xf "$ARCHIVE" -C "$TMP_PLUGIN" || err "Archive illisible : $ARCHIVE"
        [ -f "$TMP_PLUGIN/manifeste.json" ] || err "manifeste.json absent de l'archive."
        [ -f "$TMP_PLUGIN/image.tar" ]      || err "image.tar absent de l'archive."

        MANIFESTE="$(valider_manifeste_json "$TMP_PLUGIN/manifeste.json")" \
          || err "Manifeste refusé — rien n'a été installé."
        PLG_NOM="$(manifeste_lire "$MANIFESTE" nom)"
        PLG_VERSION="$(manifeste_lire "$MANIFESTE" version)"
        PLG_IMAGE="$(manifeste_lire "$MANIFESTE" image)"
        PLG_SECRETS="$(manifeste_lire "$MANIFESTE" secrets)"
        PLG_CPUS="$(MANIFESTE_JSON="$MANIFESTE" python3 -c "import json,os; print(json.loads(os.environ['MANIFESTE_JSON'])['ressources']['cpus'])")"
        PLG_MEM="$(MANIFESTE_JSON="$MANIFESTE" python3 -c "import json,os; print(json.loads(os.environ['MANIFESTE_JSON'])['ressources']['memoire'])")"

        # Secrets déclarés mais absents : l'unité démarrerait puis
        # échouerait, avec un message de podman qui ne dit pas quoi créer.
        for secret in $PLG_SECRETS; do
            $PODMAN secret exists "$secret" 2>/dev/null \
              || err "Secret podman '$secret' absent, exigé par le module « $PLG_NOM ».
  Le créer d'abord :  printf '%s' '<valeur>' | sudo podman secret create $secret -"
        done

        # Noms de sources libres ? Vérifié AVANT le chargement de
        # l'image, et l'enregistrement ne se fait qu'après.
        export MANIFESTE_JSON="$MANIFESTE"
        init_run -e MANIFESTE_JSON python3 -c "
import os, json, sys
import file_sources_config, sql_sources_config, web_sources_config
from plugin_sources_config import get_sources

m = json.loads(os.environ['MANIFESTE_JSON'])
natives = {}
for registre in (file_sources_config, sql_sources_config, web_sources_config):
    natives.update(registre.get_sources())
plugins = get_sources()

conflits = []
for source in m['sources']:
    nom = source['nom']
    if nom in natives:
        conflits.append(f\"'{nom}' est déjà une source native\")
    elif nom in plugins and plugins[nom].plugin != m['nom']:
        conflits.append(f\"'{nom}' appartient déjà au module '{plugins[nom].plugin}'\")
if conflits:
    print('Noms de source déjà pris : ' + ' ; '.join(conflits), file=sys.stderr)
    sys.exit(1)
" || err "Installation refusée — rien n'a été chargé."

        log "Chargement de l'image du module « $PLG_NOM » $PLG_VERSION..."
        $PODMAN load -i "$TMP_PLUGIN/image.tar" >/dev/null \
          || err "Chargement de l'image impossible."
        $PODMAN image exists "$PLG_IMAGE" \
          || err "L'archive ne contient pas l'image annoncée par le manifeste ($PLG_IMAGE)."

        # Enregistrement des sources. Une source déjà connue de CE module
        # conserve searchable/collectable/allowed_groups : une mise à jour
        # ne doit pas rallumer une source qu'un administrateur avait
        # éteinte (add_source remplace l'entrée en entier, voir son
        # avertissement).
        init_run -e MANIFESTE_JSON python3 -c "
import os, json
from plugin_sources_config import add_source, get_sources

m = json.loads(os.environ['MANIFESTE_JSON'])
existantes = get_sources()
for source in m['sources']:
    nom = source['nom']
    ancienne = existantes.get(nom)
    add_source(
        name=nom, plugin=source['plugin'], es_index=source['es_index'],
        acl_policy=source['acl_policy'], acl_groups=source['acl_groups'],
        acl_principaux=source['acl_principaux'], fields=source['fields'],
        label=source['label'] or None, description=source['description'] or None,
        searchable=(ancienne.searchable if ancienne else source['searchable']),
        collectable=(ancienne.collectable if ancienne else source['collectable']),
        allowed_groups=(list(ancienne.allowed_groups) if ancienne else source['allowed_groups']),
    )
    print(f\"source '{nom}' enregistrée (index {source['es_index']}, ACL {source['acl_policy']})\")
" || err "Enregistrement des sources impossible — l'image est chargée, l'unité n'est PAS écrite."

        mkdir -p "$PLUGINS_DIR"
        printf '%s\n' "$MANIFESTE" > "$PLUGINS_DIR/$PLG_NOM.json"
        ecrire_unite_plugin "$PLG_NOM" "$PLG_IMAGE" "$PLG_CPUS" "$PLG_MEM" "$PLG_SECRETS"
        systemctl daemon-reload

        PLG_PORT="$(MANIFESTE_JSON="$MANIFESTE" python3 -c "import json,os; print(json.loads(os.environ['MANIFESTE_JSON'])['port'] or '')")"
        if [ -n "$PLG_PORT" ]; then
            ecrire_fragment_nginx "$PLG_NOM" "$PLG_PORT"
            recharger_nginx
            log "Routage : /ext/$PLG_NOM/ → plugin-$PLG_NOM:$PLG_PORT"
        fi

        log "Module « $PLG_NOM » $PLG_VERSION installé."
        log "Démarrer : sudo ./manage.sh plugin enable $PLG_NOM"
        warn "Ce conteneur est sur docsearch-net, où Elasticsearch et Redis répondent sans
  authentification : le contrat empêche un module d'écrire n'importe quoi, le réseau
  ne l'en empêche pas encore. Voir PLAN-PLUGINS.md avant d'installer du code tiers."
        ;;

      list)
        [ -d "$PLUGINS_DIR" ] || { log "Aucun module installé."; exit 0; }
        for fichier in "$PLUGINS_DIR"/*.json; do
            [ -e "$fichier" ] || { log "Aucun module installé."; exit 0; }
            MANIFESTE_FICHIER="$fichier" python3 -c "
import json, os, subprocess
m = json.load(open(os.environ['MANIFESTE_FICHIER'], encoding='utf-8'))
etat = subprocess.run(
    ['systemctl', 'is-active', f\"docsearch-plugin-{m['nom']}\"],
    capture_output=True, text=True,
).stdout.strip() or 'inconnu'
sources = ', '.join(s['nom'] for s in m['sources']) or '(aucune)'
print(f\"{m['nom']:<16} {m['version']:<10} {etat:<10} {m['image']}\")
print(f\"{'':<16} sources : {sources}\")
"
        done
        ;;

      enable|disable)
        require_root
        PLG_NOM="${3:-}"
        [ -n "$PLG_NOM" ] || err "Usage : sudo ./manage.sh plugin $SOUS <nom>"
        [ -f "$PLUGINS_DIR/$PLG_NOM.json" ] || err "Module inconnu : '$PLG_NOM' (voir ./manage.sh plugin list)"

        if [ "$SOUS" = "enable" ]; then
            PLG_ACTIF="true"
            systemctl enable --now "docsearch-plugin-$PLG_NOM" 2>/dev/null \
              || systemctl start "docsearch-plugin-$PLG_NOM"
        else
            PLG_ACTIF="false"
            systemctl stop "docsearch-plugin-$PLG_NOM" 2>/dev/null || true
        fi

        # Les sources suivent l'état du module : un module arrêté qui
        # laisserait ses sources cherchables afficherait un contenu que
        # plus rien n'alimente ni ne met à jour. Rien n'est détruit — le
        # réglage se rallume et tout revient.
        SOURCES_JSON="$(sources_du_manifeste "$PLG_NOM")"
        export SOURCES_JSON PLG_ACTIF
        init_run -e SOURCES_JSON -e PLG_ACTIF python3 -c "
import os, json
from plugin_sources_config import set_searchable
actif = os.environ['PLG_ACTIF'] == 'true'
for nom in json.loads(os.environ['SOURCES_JSON']):
    set_searchable(nom, actif)
    print(f\"source '{nom}' : cherchable = {actif}\")
"
        if [ "$SOUS" = "enable" ]; then
            log "Module « $PLG_NOM » activé."
        else
            log "Module « $PLG_NOM » arrêté — ses sources sortent de la recherche, rien n'est supprimé."
        fi
        ;;

      remove)
        require_root
        PLG_NOM="${3:-}"
        [ -n "$PLG_NOM" ] || err "Usage : sudo ./manage.sh plugin remove <nom>"
        [ -f "$PLUGINS_DIR/$PLG_NOM.json" ] || err "Module inconnu : '$PLG_NOM' (voir ./manage.sh plugin list)"

        warn "Le module « $PLG_NOM » va être retiré : unité systemd, manifeste installé et
  sources désenregistrées. Les INDEX Elasticsearch et leurs documents ne sont PAS
  supprimés — même choix que remove-*-source. L'image reste chargée."
        read -rp "Confirmer ? (oui/non) : " CONFIRM
        [ "$CONFIRM" = "oui" ] || { log "Annulé."; exit 0; }

        systemctl disable --now "docsearch-plugin-$PLG_NOM" 2>/dev/null || true
        rm -f "$QUADLET_DIR/docsearch-plugin-$PLG_NOM.container"
        systemctl daemon-reload
        # Le fragment nginx d'abord : un `location` qui pointe vers un
        # conteneur disparu rend 502 au lieu de 404, ce qui se diagnostique
        # bien plus mal.
        if [ -f "$NGINX_PLUGINS_DIR/$PLG_NOM.conf" ]; then
            rm -f "$NGINX_PLUGINS_DIR/$PLG_NOM.conf"
            recharger_nginx
        fi

        SOURCES_JSON="$(sources_du_manifeste "$PLG_NOM")"
        export SOURCES_JSON
        init_run -e SOURCES_JSON python3 -c "
import os, json
from plugin_sources_config import remove_source
for nom in json.loads(os.environ['SOURCES_JSON']):
    try:
        remove_source(nom)
        print(f\"source '{nom}' retirée du registre\")
    except KeyError:
        print(f\"source '{nom}' déjà absente du registre\")
"
        rm -f "$PLUGINS_DIR/$PLG_NOM.json"
        log "Module « $PLG_NOM » retiré."
        warn "Index Elasticsearch conservés. Image toujours chargée : sudo podman rmi <image> pour la retirer."
        ;;

      *)
        err "Usage : ./manage.sh plugin <install|list|enable|disable|remove> [...]

    install <archive.tar>  Valider le manifeste, charger l'image, enregistrer les
                           sources, écrire l'unité systemd (sudo)
    list                   Modules installés, leur version et leur état
    enable <nom>           Démarrer le module et rendre ses sources cherchables (sudo)
    disable <nom>          L'arrêter et retirer ses sources de la recherche — ne
                           détruit rien (sudo)
    remove <nom>           Retirer l'unité, le manifeste et les sources (sudo) —
                           ne supprime NI les index NI l'image"
        ;;
    esac
    ;;

  sync-contract)
    # Sans sudo : ne touche qu'à des fichiers de dépôt, jamais aux
    # unités, aux images ni à /etc/docsearch.
    if [ "${2:-}" = "--check" ]; then
        sync_contract check
        log "Contrat à jour dans tous les dépôts consommateurs."
    else
        sync_contract apply
        log "Penser à committer la copie mise à jour dans le dépôt concerné."
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
    echo "    add-plugin-source <nom> <module> <index_es> <public|groupes|fournie> [--groupes ...]"
    echo "                      [--principaux ...] [--fields JSON] [--label ...]"
    echo "                    Enregistrer une source alimentée par un module complémentaire"
    echo "                    (documents poussés sur le topic Kafka documents-ready)"
    echo "    list-plugin-sources        Lister les sources de modules complémentaires"
    echo "    remove-plugin-source <nom> Retirer une source plugin (ne supprime PAS son index)"
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
    echo "    migrer-synonymes [source]           Poser l'analyseur de synonymes sur les index"
    echo "                                        existants (close/open, PAS de réindexation)"
    echo "    migrer-exact [source] [--apply]     Ouvrir la recherche exacte sur les index"
    echo "                                        existants (close/open + réécriture sur place)"
    echo "    backfill-hashes [source] [--apply]  Calculer l'empreinte de contenu des documents"
    echo "                                        déjà indexés (détection de doublons)"
    echo "    plugin <sous-commande>   Modules complémentaires :"
    echo "      install <archive.tar>  Valider le manifeste, charger l'image, enregistrer"
    echo "                             les sources, écrire l'unité systemd (sudo)"
    echo "      list                   Modules installés, version et état"
    echo "      enable <nom>           Démarrer le module, rendre ses sources cherchables (sudo)"
    echo "      disable <nom>          L'arrêter et le retirer de la recherche — sans rien"
    echo "                             détruire (sudo)"
    echo "      remove <nom>           Retirer unité, manifeste et sources (sudo) — ne"
    echo "                             supprime NI les index NI l'image"
    echo "    sync-contract [--check]"
    echo "                    Recopier le contrat partagé (contract/) dans les dépôts"
    echo "                    consommateurs — --check se contente de signaler une dérive"
    echo "                    (contrôle exécuté automatiquement avant chaque build)"
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
