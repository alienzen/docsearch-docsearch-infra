#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  valider-unites.sh — vérifie que chaque rôle produit des unités valides
#
#  Usage : ./valider-unites.sh [rôle…]     (sans argument : tous les rôles)
#
#  Pour chaque rôle, le script rejoue install-units.sh dans un répertoire
#  temporaire (--staging-root), puis passe le générateur Quadlet en
#  -dryrun sur les unités obtenues. Ce qui est vérifié :
#
#    - la syntaxe des .container / .volume / .network (une clé mal
#      orthographiée fait échouer le générateur, donc échouer ici) ;
#    - les références croisées : une unité qui réclame un .volume ou un
#      .network absent du même rôle est une erreur ;
#    - la syntaxe des unités systemd classiques (docsearch.target,
#      docsearch-kafka-ready.service) via systemd-analyze verify ;
#    - la cohérence entre les fichiers du dépôt et ce que l'installateur
#      copie réellement : une unité ajoutée dans quadlet/ mais oubliée
#      dans install-units.sh ne serait jamais déployée ;
#    - la syntaxe de TOUS les scripts du dépôt, pas seulement ceux de
#      quadlet/ : les sondes Zabbix et le script d'attente Kafka sont des
#      commandes déposées sur les serveurs, où une faute de frappe ne se
#      voit qu'à l'exécution.
#
#  Ce qui n'est PAS vérifié : rien n'est téléchargé ni démarré. Les
#  images référencées ne sont pas résolues, la configuration
#  /etc/docsearch/*.env n'est pas relue. Un `Image=` pointant vers un
#  tag inexistant passe cette validation et échoue au démarrage.
# ─────────────────────────────────────────────────────────────
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[valide]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERREUR]${NC} $*" >&2; }

TOUS_LES_ROLES=(dev es-data es-voting kafka frontend ingest)
ROLES=("$@")
[ ${#ROLES[@]} -gt 0 ] || ROLES=("${TOUS_LES_ROLES[@]}")

ECHECS=0

# ── Le générateur Quadlet ─────────────────────────────────────
# Ce n'est pas une sous-commande de podman mais un binaire à part,
# installé comme générateur systemd. Son chemin varie selon la
# distribution, d'où la recherche.
QUADLET_BIN=""
for candidat in /usr/libexec/podman/quadlet /usr/lib/podman/quadlet \
                /usr/lib/systemd/system-generators/podman-system-generator; do
    if [ -x "$candidat" ]; then QUADLET_BIN="$candidat"; break; fi
done
if [ -z "$QUADLET_BIN" ]; then
    err "générateur Quadlet introuvable — installer podman (>= 4.6 pour -dryrun)."
    exit 1
fi

if command -v podman >/dev/null 2>&1; then
    # La version compte : la production vise podman 4.9, et une clé
    # apparue en 5.x passerait ici pour échouer là-bas. Elle est donc
    # journalisée, pas contrôlée — c'est au lecteur du journal de CI de
    # voir avec quoi la validation a été faite.
    log "générateur : $QUADLET_BIN (podman $(podman --version | awk '{print $3}'))"
else
    log "générateur : $QUADLET_BIN"
fi

# ── Syntaxe des scripts du dépôt ──────────────────────────────
# Repérage par shebang, et non par extension : ni les sondes Zabbix
# (zabbix/scripts/docsearch-zabbix-*) ni docsearch-wait-kafka ne portent
# de .sh — ce sont des commandes, appelées par leur nom. Un contrôle sur
# *.sh les manquerait toutes. Passer par git ls-files borne l'inspection
# aux fichiers suivis : ni .env local, ni sauvegarde, ni node_modules.
INFRA="$(cd "$HERE/.." && pwd)"
NB_SHELL=0
NB_PYTHON=0

if git -C "$INFRA" rev-parse --git-dir >/dev/null 2>&1; then
    liste_fichiers() { git -C "$INFRA" ls-files -z; }
else
    warn "hors dépôt git — inspection de l'arborescence complète."
    liste_fichiers() { (cd "$INFRA" && find . -path ./.git -prune -o -type f -print0); }
fi

while IFS= read -r -d '' fichier; do
    chemin="$INFRA/$fichier"
    [ -f "$chemin" ] || continue
    case "$(head -n 1 "$chemin" 2>/dev/null)" in
        '#!'*bash*|'#!'*/sh|'#!'*'/sh '*|'#!'*env\ sh)
            NB_SHELL=$((NB_SHELL + 1))
            if ! bash -n "$chemin"; then
                err "$fichier : erreur de syntaxe shell."
                ECHECS=$((ECHECS + 1))
            fi
            ;;
        '#!'*python*)
            # ast.parse plutôt que py_compile : même contrôle de syntaxe,
            # sans __pycache__ déposé à côté du source.
            NB_PYTHON=$((NB_PYTHON + 1))
            if command -v python3 >/dev/null 2>&1 &&
               ! python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$chemin"; then
                err "$fichier : erreur de syntaxe python."
                ECHECS=$((ECHECS + 1))
            fi
            ;;
    esac
done < <(liste_fichiers)

log "syntaxe : $NB_SHELL script(s) shell, $NB_PYTHON python"

# ── Unités systemd classiques (hors Quadlet) ──────────────────
# docsearch.target et le verrou Kafka ne passent pas par le générateur :
# ce sont des unités écrites à la main, que systemd-analyze sait relire.
#
# ⚠️ systemd-analyze exige que l'ExecStart existe et soit exécutable sur
# la machine qui valide. Vérifier les unités telles quelles ne marchait
# donc que sur un hôte où la pile est DÉJÀ déployée (le script est en
# /usr/local/bin, copié par install-units.sh) et échouait partout
# ailleurs, CI comprise — validation dépendante de la machine, donc
# inutilisable. On vérifie des copies dont les chemins de déploiement
# sont ramenés à ceux du dépôt : la syntaxe est la même, et l'existence
# du script embarqué est au passage contrôlée.
if command -v systemd-analyze >/dev/null 2>&1; then
    UNITES_TMP="$(mktemp -d)"
    cp "$HERE/common/docsearch.target" "$UNITES_TMP/"
    sed -e "s|^ExecStart=/usr/local/bin/|ExecStart=$HERE/common/bin/|" \
        -e "s|^EnvironmentFile=/etc/docsearch/|EnvironmentFile=-/etc/docsearch/|" \
        "$HERE/common/docsearch-kafka-ready.service" \
        > "$UNITES_TMP/docsearch-kafka-ready.service"
    if ! systemd-analyze verify \
            "$UNITES_TMP/docsearch.target" \
            "$UNITES_TMP/docsearch-kafka-ready.service" 2>&1; then
        err "docsearch.target / docsearch-kafka-ready.service : unité invalide."
        ECHECS=$((ECHECS + 1))
    else
        log "unités systemd communes : OK"
    fi
    rm -rf "$UNITES_TMP"
else
    warn "systemd-analyze absent — docsearch.target non vérifié."
fi

# Fichiers source attendus pour un rôle : le répertoire dont
# install-units.sh tire ses unités. Sert au contrôle d'exhaustivité.
source_du_role() {
    case "$1" in
        dev) echo "$HERE/dev" ;;
        *)   echo "$HERE/roles/$1" ;;
    esac
}

# ── Un rôle ───────────────────────────────────────────────────
valider_role() {
    local role="$1"
    local racine unites journal source attendu
    racine="$(mktemp -d)"
    journal="$(mktemp)"
    # shellcheck disable=SC2064  # racine doit être développée maintenant
    trap "rm -rf '$racine' '$journal'" RETURN

    # --with-singletons pour ingest : sans lui le watcher n'est pas
    # installé et échapperait à la validation (il ne tourne que sur
    # ingest-1, mais son unité doit être correcte partout).
    local options=(--staging-root "$racine")
    [ "$role" = "ingest" ] && options+=(--with-singletons)

    if ! "$HERE/install-units.sh" "$role" "${options[@]}" >"$journal" 2>&1; then
        err "rôle « $role » : install-units.sh a échoué."
        cat "$journal" >&2
        return 1
    fi

    unites="$racine/etc/containers/systemd"
    if [ ! -d "$unites" ] || [ -z "$(ls -A "$unites" 2>/dev/null)" ]; then
        err "rôle « $role » : aucune unité installée dans $unites."
        return 1
    fi

    # Le générateur écrit les unités produites dans un répertoire de
    # sortie même en -dryrun sur certaines versions : on lui en donne un
    # jetable plutôt que de le laisser choisir.
    if ! QUADLET_UNIT_DIRS="$unites" "$QUADLET_BIN" -dryrun -no-kmsg-log \
            >"$journal" 2>&1; then
        err "rôle « $role » : le générateur Quadlet rejette les unités."
        cat "$journal" >&2
        return 1
    fi

    # Exhaustivité : tout .container / .volume du répertoire source doit
    # se retrouver installé. Le modèle .in produit docsearch-worker-N,
    # il est donc exclu du contrôle nom à nom.
    source="$(source_du_role "$role")"
    local manquantes=()
    for attendu in "$source"/*.container "$source"/*.volume; do
        [ -e "$attendu" ] || continue
        [ -e "$unites/$(basename "$attendu")" ] || manquantes+=("$(basename "$attendu")")
    done
    if [ ${#manquantes[@]} -gt 0 ]; then
        err "rôle « $role » : présentes dans $(realpath --relative-to="$HERE/.." "$source") mais jamais installées par install-units.sh — ${manquantes[*]}"
        return 1
    fi

    log "rôle « $role » : $(find "$unites" -type f | wc -l) unités générées, OK"
}

for role in "${ROLES[@]}"; do
    valider_role "$role" || ECHECS=$((ECHECS + 1))
done

# ── Le modèle d'unité des modules complémentaires ─────────────
# Il n'appartient à aucun rôle : « ./manage.sh plugin install » l'instancie
# à la demande, à partir d'un manifeste. Sans ce contrôle, une faute de
# frappe dans le modèle ne se verrait qu'au premier module installé — sur
# la machine du client, pas ici.
valider_modele_plugin() {
    local modele="$HERE/plugin.container.in"
    [ -f "$modele" ] || { err "Modèle de module complémentaire introuvable : $modele"; return 1; }

    local tmp; tmp="$(mktemp -d)"
    # shellcheck disable=SC2064  # expansion voulue à la définition
    trap "rm -rf '$tmp'" RETURN
    mkdir -p "$tmp/unites" "$tmp/sortie"
    # Mêmes substitutions que ecrire_unite_plugin() dans manage.sh, avec
    # deux secrets pour éprouver la répétition de ligne.
    sed -e 's/@NOM@/exemple/g' \
        -e 's|@IMAGE@|registre.interne/docsearch-plugins/exemple:1.0.0|g' \
        -e 's/@CPUS@/1.0/g' -e 's/@MEMOIRE@/512m/g' \
        -e 's/@KAFKA_BOOTSTRAP@/kafka:9092/g' -e 's/@TOPIC@/documents-ready/g' \
        -e 's/@SECRETS@/Secret=exemple-jeton\nSecret=exemple-second/' \
        "$modele" > "$tmp/unites/docsearch-plugin-exemple.container"

    # Le modèle référence docsearch-net.network, qui vit dans common/ :
    # sans lui, le générateur signale une référence croisée manquante.
    cp "$HERE/common/docsearch-net.network" "$tmp/unites/"

    if ! QUADLET_UNIT_DIRS="$tmp/unites" "$QUADLET_BIN" -dryrun -no-kmsg-log \
            >"$tmp/erreurs" 2>&1; then
        err "modèle de module complémentaire : le générateur Quadlet le refuse."
        sed 's/^/    /' "$tmp/erreurs" >&2
        return 1
    fi
    # Hors commentaires : l'en-tête du modèle parle légitimement des
    # marqueurs, ce sont les lignes de CONFIGURATION qui ne doivent plus
    # en porter.
    if grep -v '^[[:space:]]*#' "$tmp/unites/docsearch-plugin-exemple.container" \
         | grep -q '@[A-Z_]*@'; then
        err "modèle de module complémentaire : marqueur @…@ non substitué — ajouter sa
    substitution dans ecrire_unite_plugin() (manage.sh) ET ici."
        return 1
    fi
    log "modèle de module complémentaire : OK"
}

valider_modele_plugin || ECHECS=$((ECHECS + 1))

echo
if [ "$ECHECS" -gt 0 ]; then
    err "$ECHECS validation(s) en échec."
    exit 1
fi
log "Toutes les validations passent."
