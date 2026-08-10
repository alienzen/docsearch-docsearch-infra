#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  deployer-sondes.sh — installe les sondes Zabbix sur UNE machine
#
#  Usage : sudo ./deployer-sondes.sh <rôle> [--dry-run]
#
#  Rôles (les mêmes que quadlet/install-units.sh) :
#    es-data     nœud de données Elasticsearch   (es-data-1, es-data-2)
#    es-voting   arbitre + Kibana                (es-voting)
#    kafka       broker Kafka                    (kafka)
#    frontend    Redis + API + interface + Nginx (frontend)
#    ingest      Tika + workers                  (ingest-1/2/3)
#
#  Les sondes communes (unités systemd, conteneurs, horloge) sont
#  installées quel que soit le rôle. Elasticsearch, Kibana et Tika
#  n'ajoutent RIEN ici : le serveur Zabbix les interroge directement sur
#  leurs ports publiés, sans passer par l'agent.
#
#  Ce script ne configure PAS l'agent lui-même (Server=, Hostname=) :
#  cela dépend de l'adresse du serveur Zabbix, pas de DocSearch. Voir
#  README.md §3.
# ─────────────────────────────────────────────────────────────
set -euo pipefail

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN_DIR=/usr/local/bin
# Agent 2 par défaut. Pour l'agent classique, qui convient tout aussi bien
# (aucune sonde n'utilise de clé propre à l'agent 2) :
#   AGENT_DIR=/etc/zabbix/zabbix_agentd.d sudo -E ./deployer-sondes.sh <rôle>
AGENT_DIR=${AGENT_DIR:-/etc/zabbix/zabbix_agent2.d}
CONF_DIR=/etc/zabbix
SUDOERS=/etc/sudoers.d/zabbix-docsearch
ETAT_DIR=/var/lib/zabbix/docsearch

VERT='\033[0;32m'; JAUNE='\033[1;33m'; ROUGE='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${VERT}[sondes]${NC} $*"; }
avert(){ echo -e "${JAUNE}[ATTENTION]${NC} $*"; }
err()  { echo -e "${ROUGE}[ERREUR]${NC} $*"; exit 1; }

ROLE="${1:-}"
DRY_RUN=false
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        *) err "Option inconnue : $1" ;;
    esac
done

case "$ROLE" in
    es-data|es-voting|kafka|frontend|ingest) ;;
    *) err "Usage : sudo ./deployer-sondes.sh <es-data|es-voting|kafka|frontend|ingest> [--dry-run]" ;;
esac

lancer() {
    if [ "$DRY_RUN" = true ]; then echo "  [dry-run] $*"; else "$@"; fi
}

if [ "$DRY_RUN" = false ] && [ "$(id -u)" -ne 0 ]; then
    err "À lancer avec sudo."
fi

id zabbix >/dev/null 2>&1 || avert "L'utilisateur zabbix n'existe pas encore : installer zabbix-agent2 d'abord."
[ -d "$AGENT_DIR" ] || avert "$AGENT_DIR absent : l'agent Zabbix n'est pas installé, ou n'est pas celui attendu (surcharger AGENT_DIR)."

# ── Scripts communs ───────────────────────────────────────────
# 0755 root:root, impérativement : trois d'entre eux sont lancés par
# sudo. Modifiables par zabbix, ils vaudraient un accès root.
communs=(docsearch-zabbix-unites docsearch-zabbix-podman docsearch-zabbix-horloge)
for s in "${communs[@]}"; do
    lancer install -o root -g root -m 0755 "$ICI/scripts/$s" "$BIN_DIR/$s"
done
log "Sondes communes installées dans $BIN_DIR."

lancer install -o root -g root -m 0644 \
    "$ICI/agent/docsearch-commun.conf" "$AGENT_DIR/docsearch-commun.conf"

# ── Sondes propres au rôle ────────────────────────────────────
case "$ROLE" in

    frontend)
        for s in docsearch-zabbix-api docsearch-zabbix-redis docsearch-zabbix-montage; do
            lancer install -o root -g root -m 0755 "$ICI/scripts/$s" "$BIN_DIR/$s"
        done
        lancer install -o root -g root -m 0644 \
            "$ICI/agent/docsearch-frontend.conf" "$AGENT_DIR/docsearch-frontend.conf"

        # Répertoire d'état des sessions de sonde (pot à biscuits, verrou).
        lancer install -d -o zabbix -g zabbix -m 0700 "$ETAT_DIR"

        # Le fichier de configuration porte le mot de passe du compte de
        # supervision : jamais écrasé s'il existe déjà.
        if [ -e "$CONF_DIR/docsearch-supervision.conf" ]; then
            avert "$CONF_DIR/docsearch-supervision.conf existe — laissé tel quel."
        else
            lancer install -o root -g zabbix -m 0640 \
                "$ICI/agent/docsearch-supervision.conf.example" \
                "$CONF_DIR/docsearch-supervision.conf"
            avert "$CONF_DIR/docsearch-supervision.conf créé depuis le modèle — À COMPLÉTER."
        fi
        ;;

    ingest)
        lancer install -o root -g root -m 0755 \
            "$ICI/scripts/docsearch-zabbix-montage" "$BIN_DIR/docsearch-zabbix-montage"
        lancer install -o root -g root -m 0644 \
            "$ICI/agent/docsearch-ingest.conf" "$AGENT_DIR/docsearch-ingest.conf"
        ;;

    kafka)
        lancer install -o root -g root -m 0755 \
            "$ICI/scripts/docsearch-zabbix-kafka" "$BIN_DIR/docsearch-zabbix-kafka"
        lancer install -o root -g root -m 0644 \
            "$ICI/agent/docsearch-kafka.conf" "$AGENT_DIR/docsearch-kafka.conf"
        avert "Poser Timeout=30 dans zabbix_agent2.conf : kafka-consumer-groups met plusieurs secondes."
        ;;

    es-data|es-voting)
        # Rien de spécifique : Elasticsearch et Kibana sont interrogés en
        # HTTP par le serveur Zabbix (9200 et 5601, déjà ouverts §3 du
        # guide d'installation).
        log "Rôle $ROLE : sondes communes seulement, ES/Kibana sont interrogés sans agent."
        ;;
esac

# ── sudoers ───────────────────────────────────────────────────
# Posé quel que soit le rôle : docsearch-zabbix-podman est commun aux 8
# machines et a besoin du podman rootful.
if [ "$DRY_RUN" = true ]; then
    echo "  [dry-run] visudo -cf $ICI/sudoers/zabbix-docsearch && install → $SUDOERS"
else
    visudo -cf "$ICI/sudoers/zabbix-docsearch" >/dev/null \
        || err "Le fichier sudoers est invalide — rien n'a été installé."
    install -o root -g root -m 0440 "$ICI/sudoers/zabbix-docsearch" "$SUDOERS"
    log "Règle sudo installée dans $SUDOERS."
fi

# ── Vérification ──────────────────────────────────────────────
if [ "$DRY_RUN" = false ]; then
    log "Vérification des sondes, sous l'identité de l'utilisateur zabbix :"
    for cle in docsearch-zabbix-unites docsearch-zabbix-horloge; do
        printf '  %-28s ' "$cle"
        if runuser -u zabbix -- "$BIN_DIR/$cle" >/dev/null 2>&1; then
            echo "ok"
        else
            echo "ÉCHEC"
        fi
    done
    printf '  %-28s ' "podman (via sudo)"
    runuser -u zabbix -- sudo -n "$BIN_DIR/docsearch-zabbix-podman" >/dev/null 2>&1 \
        && echo "ok" || echo "ÉCHEC"

    echo
    log "Redémarrer l'agent : systemctl restart zabbix-agent2"
    log "Puis, depuis le serveur Zabbix : zabbix_get -s <ip> -k docsearch.unites"
fi
