#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  install-units.sh — installe les unités Quadlet d'un rôle
#
#  Usage : sudo ./install-units.sh <rôle> [options]
#
#  Rôles :
#    dev         pile complète sur une seule machine (développement)
#    es-data     nœud de données Elasticsearch      (es-data-1, es-data-2)
#    es-voting   nœud voting-only + Kibana          (es-voting)
#    kafka       broker Kafka                       (kafka)
#    frontend    Redis + API + interface + Nginx    (frontend)
#    ingest      2 Tika + workers                   (ingest-1/2/3)
#
#  Options :
#    --workers N        nombre d'unités worker (défaut : 4 en dev, 3 en ingest)
#    --with-singletons  ajoute le watcher — ingest-1 UNIQUEMENT
#    --no-enable        n'active PAS le démarrage au boot (et respecte un
#                       "systemctl disable docsearch.target" déjà en place)
#    --dry-run          montre ce qui serait fait, n'écrit rien
#    --staging-root DIR installe réellement, mais sous DIR au lieu de la
#                       racine : DIR/etc/containers/systemd, DIR/etc/docsearch…
#                       Ni root ni systemctl. Sert à la validation en CI
#                       (voir valider-unites.sh) et à inspecter le résultat
#                       d'une installation sans toucher à la machine.
#
#  Les fichiers de configuration (/etc/docsearch/*.env) ne sont JAMAIS
#  écrasés : à la première installation ils sont copiés depuis les
#  .example, ensuite ils sont laissés tels quels.
# ─────────────────────────────────────────────────────────────
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$(dirname "$HERE")"

QUADLET_DIR=/etc/containers/systemd
SYSTEMD_DIR=/etc/systemd/system
CONFIG_DIR=/etc/docsearch
BIN_DIR=/usr/local/bin

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[install]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERREUR]${NC} $*"; exit 1; }

ROLE="${1:-}"
shift || true
WORKERS=""
SINGLETONS=false
DRY_RUN=false
ENABLE_BOOT=true
STAGING_ROOT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --workers)         WORKERS="${2:-}"; shift 2 ;;
        --with-singletons) SINGLETONS=true;  shift ;;
        --no-enable)       ENABLE_BOOT=false; shift ;;
        --dry-run)         DRY_RUN=true;     shift ;;
        --staging-root)    STAGING_ROOT="${2:-}"; shift 2 ;;
        *) err "Option inconnue : $1" ;;
    esac
done

# --staging-root déplace les quatre destinations sous une racine à part.
# Le reste du script est inchangé : c'est bien la même installation qui est
# jouée, au chemin près — sans quoi la validation ne prouverait rien.
if [ -n "$STAGING_ROOT" ]; then
    [ "${STAGING_ROOT:0:1}" = "/" ] || err "--staging-root exige un chemin absolu : $STAGING_ROOT"
    QUADLET_DIR="$STAGING_ROOT$QUADLET_DIR"
    SYSTEMD_DIR="$STAGING_ROOT$SYSTEMD_DIR"
    CONFIG_DIR="$STAGING_ROOT$CONFIG_DIR"
    BIN_DIR="$STAGING_ROOT$BIN_DIR"
fi

case "$ROLE" in
    dev|es-data|es-voting|kafka|frontend|ingest) ;;
    *) err "Usage : sudo ./install-units.sh <dev|es-data|es-voting|kafka|frontend|ingest> [--workers N] [--with-singletons] [--dry-run] [--staging-root DIR]" ;;
esac

# ── Contrôles préalables ──────────────────────────────────────
command -v podman >/dev/null 2>&1 || err "podman n'est pas installé."

# Quadlet existe depuis podman 4.4 ; la production tourne sur Debian 13,
# dont les dépôts stables livrent 5.4.2 (aucun backport nécessaire — il en
# fallait un sur Debian 12, restée en 4.3). Le seuil reste 4.4 : c'est la
# version qui fait exister Quadlet, pas celle qu'on vise. En dessous,
# aucune unité ne serait générée — autant le dire tout de suite plutôt que
# de laisser un systemctl start échouer.
PODMAN_VERSION="$(podman --version | awk '{print $3}')"
PODMAN_MAJOR="${PODMAN_VERSION%%.*}"
PODMAN_MINOR="$(echo "$PODMAN_VERSION" | cut -d. -f2)"
if [ "$PODMAN_MAJOR" -lt 4 ] || { [ "$PODMAN_MAJOR" -eq 4 ] && [ "$PODMAN_MINOR" -lt 4 ]; }; then
    err "podman $PODMAN_VERSION : Quadlet exige au moins 4.4 (voir HOWTO-deploiement-hors-ligne.md)."
fi
log "podman $PODMAN_VERSION détecté."

if [ "$DRY_RUN" = false ] && [ -z "$STAGING_ROOT" ] && [ "$(id -u)" -ne 0 ]; then
    err "À lancer avec sudo : les unités s'installent dans $QUADLET_DIR (podman rootful)."
fi

run() {
    if [ "$DRY_RUN" = true ]; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

# Copie un fichier de configuration SANS jamais écraser l'existant.
# Mode 0600 : ces fichiers portent le mot de passe LDAP, la clé de
# chiffrement des DSN et les DSN SQL eux-mêmes. Seul systemd (donc root)
# les lit, personne d'autre n'a besoin d'y accéder.
install_config() {
    local src="$1" dest="$2"
    if [ -e "$dest" ]; then
        warn "$dest existe déjà — laissé tel quel (modèle : $src)"
    else
        run install -m 0600 "$src" "$dest"
        log "$dest créé depuis le modèle — À COMPLÉTER"
    fi
}

# Génère N unités worker à partir du modèle .in
install_workers() {
    local template="$1" count="$2" i
    for i in $(seq 1 "$count"); do
        if [ "$DRY_RUN" = true ]; then
            echo "  [dry-run] génère $QUADLET_DIR/docsearch-worker-$i.container"
        else
            sed "s/@N@/$i/g" "$template" > "$QUADLET_DIR/docsearch-worker-$i.container"
        fi
    done
    log "$count unité(s) worker générée(s)."
}

# Retire les unités worker au-delà du compte demandé (réduction d'échelle)
prune_workers() {
    local count="$1" f n
    for f in "$QUADLET_DIR"/docsearch-worker-*.container; do
        [ -e "$f" ] || continue
        n="$(basename "$f" .container)"; n="${n##*-}"
        if [ "$n" -gt "$count" ] 2>/dev/null; then
            run rm -f "$f"
            log "unité worker $n retirée."
        fi
    done
}

run mkdir -p "$QUADLET_DIR" "$CONFIG_DIR" "$SYSTEMD_DIR" "$BIN_DIR"

# ── Cible commune ─────────────────────────────────────────────
# La même sur les 8 machines : seules les unités installées changent.
run install -m 0644 "$HERE/common/docsearch.target" "$SYSTEMD_DIR/docsearch.target"

# ── Réseau podman (rôles en réseau bridge uniquement) ─────────
# es-data, es-voting et kafka tournent en Network=host : pas de réseau
# podman à créer chez eux.
case "$ROLE" in
    dev|frontend|ingest)
        run install -m 0644 "$HERE/common/docsearch-net.network" "$QUADLET_DIR/"
        ;;
esac

# ── Verrou de disponibilité Kafka (consommateurs seulement) ───
case "$ROLE" in
    dev|ingest)
        run install -m 0755 "$HERE/common/bin/docsearch-wait-kafka" "$BIN_DIR/docsearch-wait-kafka"
        run install -m 0644 "$HERE/common/docsearch-kafka-ready.service" "$SYSTEMD_DIR/docsearch-kafka-ready.service"
        ;;
esac

# ── Unités et configuration du rôle ───────────────────────────
case "$ROLE" in
  dev)
      for f in "$HERE"/dev/*.container "$HERE"/dev/*.volume; do
          run install -m 0644 "$f" "$QUADLET_DIR/"
      done
      install_workers "$HERE/dev/docsearch-worker.container.in" "${WORKERS:-4}"
      prune_workers "${WORKERS:-4}"
      install_config "$HERE/common/docsearch.env.example"      "$CONFIG_DIR/docsearch.env"
      install_config "$HERE/common/elasticsearch.env.example"  "$CONFIG_DIR/elasticsearch.env"
      # Configurations de crawl + modèle du proxy de simulation
      run mkdir -p "$CONFIG_DIR/crawlers" "$CONFIG_DIR/nginx"
      run cp -r "$INFRA/crawlers/." "$CONFIG_DIR/crawlers/"
      run install -m 0644 "$INFRA/nginx/dev-user-proxy.conf.template" "$CONFIG_DIR/nginx/dev-user-proxy.conf.template"
      ;;

  es-data)
      run install -m 0644 "$HERE/roles/es-data/docsearch-es.container" "$QUADLET_DIR/"
      install_config "$HERE/roles/es-data/elasticsearch.env.example" "$CONFIG_DIR/elasticsearch.env"
      warn "Vérifier node.name dans $CONFIG_DIR/elasticsearch.env : es01 sur es-data-1, es02 sur es-data-2."
      ;;

  es-voting)
      for f in "$HERE"/roles/es-voting/*.container "$HERE"/roles/es-voting/*.volume; do
          run install -m 0644 "$f" "$QUADLET_DIR/"
      done
      install_config "$HERE/roles/es-voting/elasticsearch.env.example" "$CONFIG_DIR/elasticsearch.env"
      install_config "$HERE/roles/es-voting/kibana.env.example"        "$CONFIG_DIR/kibana.env"
      ;;

  kafka)
      for f in "$HERE"/roles/kafka/*.container "$HERE"/roles/kafka/*.volume; do
          run install -m 0644 "$f" "$QUADLET_DIR/"
      done
      install_config "$HERE/roles/kafka/kafka.env.example" "$CONFIG_DIR/kafka.env"
      warn "Renseigner l'IP RÉELLE de cette machine dans $CONFIG_DIR/kafka.env (KAFKA_ADVERTISED_LISTENERS)."
      ;;

  frontend)
      for f in "$HERE"/roles/frontend/*.container "$HERE"/roles/frontend/*.volume; do
          run install -m 0644 "$f" "$QUADLET_DIR/"
      done
      install_config "$HERE/common/docsearch.env.example" "$CONFIG_DIR/docsearch.env"
      run mkdir -p "$CONFIG_DIR/nginx/certs"
      install_config "$INFRA/nginx/nginx.conf" "$CONFIG_DIR/nginx/nginx.conf"
      warn "Déposer le certificat TLS dans $CONFIG_DIR/nginx/certs (cert.pem, key.pem)."
      ;;

  ingest)
      run install -m 0644 "$HERE/roles/ingest/docsearch-tika-a.container" "$QUADLET_DIR/"
      run install -m 0644 "$HERE/roles/ingest/docsearch-tika-b.container" "$QUADLET_DIR/"
      install_workers "$HERE/roles/ingest/docsearch-worker.container.in" "${WORKERS:-3}"
      prune_workers "${WORKERS:-3}"
      if [ "$SINGLETONS" = true ]; then
          run install -m 0644 "$HERE/roles/ingest/docsearch-watcher.container" "$QUADLET_DIR/"
          log "watcher installé (machine ingest-1)."
      else
          run rm -f "$QUADLET_DIR/docsearch-watcher.container"
      fi
      install_config "$HERE/roles/ingest/docsearch.env.example" "$CONFIG_DIR/docsearch.env"
      ;;
esac

# ── Mémorisation du rôle ──────────────────────────────────────
# "manage.sh scale-workers N" rejoue cette installation avec un nombre
# de workers différent : il doit retrouver le rôle ET ses options, sans
# quoi un ingest-1 perdrait son watcher à la première mise à l'échelle.
if [ "$DRY_RUN" = true ]; then
    echo "  [dry-run] écrit $CONFIG_DIR/install-args : $ROLE$([ "$SINGLETONS" = true ] && echo ' --with-singletons')"
else
    printf '%s%s\n' "$ROLE" "$([ "$SINGLETONS" = true ] && echo ' --with-singletons')" \
        > "$CONFIG_DIR/install-args"
fi

# ── Prise en compte ───────────────────────────────────────────
# Sous --staging-root, rien n'a été écrit à un emplacement que systemd
# regarde : recharger ou activer la cible n'aurait aucun sens.
if [ -n "$STAGING_ROOT" ]; then
    log "Rôle « $ROLE » préparé sous $STAGING_ROOT (aucun systemctl exécuté)."
    exit 0
fi

run systemctl daemon-reload

# Le démarrage au boot n'est activé que s'il est demandé. Sans cette
# précaution, réinstaller les unités (mise à jour, scale-workers)
# réactiverait silencieusement un docsearch.target volontairement
# désactivé.
if [ "$ENABLE_BOOT" = true ]; then
    run systemctl enable docsearch.target
else
    log "Démarrage au boot NON activé (--no-enable) — état actuel : $(systemctl is-enabled docsearch.target 2>/dev/null || echo inconnu)"
fi

log "Rôle « $ROLE » installé."
echo
echo "  1. Compléter la configuration : $CONFIG_DIR/*.env"
echo "  2. Vérifier que les images sont présentes : podman images"
echo "  3. Démarrer : sudo systemctl start docsearch.target"
echo "     (ou, depuis docsearch-infra : sudo ./manage.sh start)"
echo
