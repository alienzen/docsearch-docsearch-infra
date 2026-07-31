#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  transfer-images.sh — place dans le magasin d'images de ROOT
#  toutes les images dont les unités d'un rôle ont besoin.
#
#  Usage : sudo ./quadlet/transfer-images.sh [rôle] [--dry-run]
#          (rôle par défaut : dev)
#
#  Pourquoi ce script : podman sépare le magasin d'images de root de
#  celui de chaque utilisateur. Les unités systemd tournent en root et
#  ne voient PAS une image construite ou tirée sans sudo — le symptôme
#  est un "image not known" au démarrage alors que "podman images" la
#  montre. Voir README.md, section « Prérequis podman ».
#
#  Chaque image manquante est cherchée, dans l'ordre :
#    1. magasin podman de l'utilisateur qui a lancé sudo (images
#       construites par ./manage.sh build)
#    2. magasin Docker de la machine (images tirées du temps de Compose,
#       ce qui évite de retélécharger ~8 Go)
#  Les transferts se font par tube : aucune archive intermédiaire sur
#  disque, ce qui compte quand il ne reste que quelques Go libres.
# ─────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[transfert]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERREUR]${NC} $*"; exit 1; }

ROLE="dev"
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        dev|es-data|es-voting|kafka|frontend|ingest) ROLE="$arg" ;;
        *) err "Usage : sudo ./quadlet/transfer-images.sh [dev|es-data|es-voting|kafka|frontend|ingest] [--dry-run]" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || err "À lancer avec sudo : la destination est le magasin d'images de root."

# L'utilisateur d'origine, dont on lira le magasin podman rootless.
OWNER="${SUDO_USER:-}"
[ -n "$OWNER" ] || warn "SUDO_USER vide — le magasin rootless ne pourra pas être lu (connexion root directe ?)."

# ⚠️ Un magasin podman rootless est localisé par HOME et XDG_RUNTIME_DIR.
# Un simple "sudo -u $OWNER podman" garde HOME=/root : podman cherche
# alors le magasin dans /root, ne trouve rien, et TOUTES les images de
# l'utilisateur sont déclarées introuvables. D'où -H (bascule HOME sur
# celui de la cible) et XDG_RUNTIME_DIR explicite.
OWNER_UID="$(id -u "$OWNER" 2>/dev/null || echo '')"
as_owner() {
    [ -n "$OWNER" ] && [ -n "$OWNER_UID" ] || return 1
    sudo -u "$OWNER" -H env "XDG_RUNTIME_DIR=/run/user/$OWNER_UID" podman "$@"
}

# Contrôle immédiat : si le magasin de l'utilisateur est illisible, mieux
# vaut le dire tout de suite que de conclure "image introuvable" image
# par image.
if [ -n "$OWNER" ] && ! as_owner images >/dev/null 2>&1; then
    warn "Magasin podman de $OWNER illisible — seules les images Docker pourront être transférées."
fi

# ── Images réclamées par les unités du rôle ───────────────────
# Lues dans les fichiers du dépôt, jamais devinées.
SRC_DIR="$HERE/dev"
[ "$ROLE" = "dev" ] || SRC_DIR="$HERE/roles/$ROLE"
[ -d "$SRC_DIR" ] || err "Rôle inconnu : $SRC_DIR introuvable."

mapfile -t IMAGES < <(grep -h '^Image=' "$SRC_DIR"/*.container "$SRC_DIR"/*.in 2>/dev/null \
                      | sed 's/^Image=//' | sort -u)
[ "${#IMAGES[@]}" -gt 0 ] || err "Aucune image trouvée dans $SRC_DIR."

log "Rôle « $ROLE » : ${#IMAGES[@]} image(s) requise(s)."
echo

MISSING=()
for img in "${IMAGES[@]}"; do
    printf '  %-58s ' "$img"

    if podman image exists "$img" 2>/dev/null; then
        echo "déjà présente"
        continue
    fi

    # 1. Magasin podman de l'utilisateur
    if as_owner image exists "$img" 2>/dev/null; then
        if [ "$DRY_RUN" = true ]; then
            echo "à transférer depuis le magasin de $OWNER"
        else
            if as_owner save "$img" 2>/dev/null | podman load >/dev/null 2>&1; then
                echo "transférée depuis $OWNER"
            else
                echo "ÉCHEC du transfert depuis $OWNER"
                MISSING+=("$img")
            fi
        fi
        continue
    fi

    # 2. Magasin Docker — le nom court y suffit, podman load requalifie
    #    ("redis:7.2-alpine" → "docker.io/library/redis:7.2-alpine").
    DOCKER_REF="${img#docker.io/library/}"
    DOCKER_REF="${DOCKER_REF#docker.io/}"
    if command -v docker >/dev/null 2>&1 && docker image inspect "$DOCKER_REF" >/dev/null 2>&1; then
        if [ "$DRY_RUN" = true ]; then
            echo "à transférer depuis Docker ($DOCKER_REF)"
        else
            if docker save "$DOCKER_REF" 2>/dev/null | podman load >/dev/null 2>&1; then
                echo "transférée depuis Docker"
            else
                echo "ÉCHEC du transfert depuis Docker"
                MISSING+=("$img")
            fi
        fi
        continue
    fi

    echo "INTROUVABLE localement"
    MISSING+=("$img")
done

echo
if [ "${#MISSING[@]}" -eq 0 ]; then
    log "Toutes les images du rôle « $ROLE » sont dans le magasin de root."
    echo "  Vérifier : sudo podman images"
    echo "  Démarrer : sudo ./manage.sh start"
else
    warn "${#MISSING[@]} image(s) manquante(s) :"
    for m in "${MISSING[@]}"; do echo "    $m"; done
    echo
    echo "  Images maison  → ./manage.sh build all   (machine CONNECTÉE)"
    echo "  Images tierces → sudo podman pull <image>, ou transfert hors ligne"
    echo "                   (voir HOWTO-deploiement-hors-ligne.md)"
    exit 1
fi
