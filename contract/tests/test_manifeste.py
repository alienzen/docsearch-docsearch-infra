# test_manifeste.py — Déclaration d'un module complémentaire installable.
#
# Aucun service requis. C'est la porte d'entrée : tout ce qui est validé
# ici l'est AVANT que `manage.sh plugin install` ne charge une image ou
# n'écrive une unité systemd. Un manifeste refusé ne doit rien laisser
# derrière lui.

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from docsearch_contract import CONTRACT_VERSION, ContratInvalide, manifeste  # noqa: E402


def base(**surcharges) -> dict:
    m = {
        "nom": "jira",
        "version": "1.2.0",
        "contract_version": CONTRACT_VERSION,
        "image": "registre.interne/docsearch-plugins/jira:1.2.0",
        "capacites": ["ingestion"],
        "sources": [{
            "nom": "tickets", "es_index": "tickets_jira",
            "acl_policy": "groupes", "acl_groups": ["DL-SUPPORT"],
        }],
    }
    return {**m, **surcharges}


def test_manifeste_minimal_accepte():
    m = manifeste.valider_manifeste(base())
    assert m["nom"] == "jira"
    assert m["ressources"] == manifeste.RESSOURCES_DEFAUT
    assert m["secrets"] == []


def test_le_module_possede_ses_sources():
    """Le propriétaire d'une source est le module qui la déclare — c'est
    ce que `verifier_emetteur` comparera ensuite à chaque message."""
    m = manifeste.valider_manifeste(base())
    assert m["sources"][0]["plugin"] == "jira"


def test_une_source_ne_peut_pas_declarer_son_module():
    """Sinon un manifeste revendiquerait la source d'un autre module, et
    tout le contrôle d'émetteur du lot 1 tomberait."""
    mauvais = base()
    mauvais["sources"][0]["plugin"] = "confluence"
    with pytest.raises(ContratInvalide, match="ne peut pas déclarer 'plugin'"):
        manifeste.valider_manifeste(mauvais)


@pytest.mark.parametrize("clef", ["nom", "version", "contract_version", "image"])
def test_champ_obligatoire_manquant(clef):
    m = base()
    del m[clef]
    with pytest.raises(ContratInvalide, match=clef):
        manifeste.valider_manifeste(m)


def test_cle_inconnue_refusee():
    """Presque toujours une faute de frappe sur une clé qui comptait —
    l'ignorer produirait un module qui s'installe en faisant autre chose
    que ce que son auteur croit avoir écrit."""
    with pytest.raises(ContratInvalide, match="capacite"):
        manifeste.valider_manifeste(base(capacite=["ingestion"]))


def test_version_de_contrat_incompatible_refusee():
    with pytest.raises(ContratInvalide, match="vise le contrat"):
        manifeste.valider_manifeste(base(contract_version="9.9.9"))


def test_version_de_module_non_semantique_refusee():
    with pytest.raises(ContratInvalide, match="Version de module"):
        manifeste.valider_manifeste(base(version="1.2"))


def test_etiquette_latest_refusee():
    """La production reçoit ses images par transfert manuel : une
    étiquette flottante rend impossible de savoir quelle version
    transférer, et fait diverger les machines."""
    with pytest.raises(ContratInvalide, match="latest"):
        manifeste.valider_manifeste(base(image="registre.interne/jira:latest"))


def test_image_sans_etiquette_refusee():
    with pytest.raises(ContratInvalide, match="étiquette explicite"):
        manifeste.valider_manifeste(base(image="registre.interne/jira"))


def test_capacite_non_servie_refusee():
    """Une capacité que le cœur ne sait pas router produirait un module à
    moitié installé : il s'annonce, rien ne l'écoute, et rien ne le dit.
    (`service_web` l'a été jusqu'au lot 3 — c'est ainsi que la liste
    fermée gagne sa place.)"""
    with pytest.raises(ContratInvalide, match="non servie"):
        manifeste.valider_manifeste(base(capacites=["ingestion", "ordonnancement"]))


def test_capacites_vides_refusees():
    with pytest.raises(ContratInvalide, match="capacites"):
        manifeste.valider_manifeste(base(capacites=[]))


def test_ingestion_sans_source_refusee():
    """Sans source déclarée, ce que le module pousserait serait refusé
    par le worker — autant le dire à l'installation."""
    with pytest.raises(ContratInvalide, match="au moins une"):
        manifeste.valider_manifeste(base(sources=[]))


def test_source_invalide_remonte_l_erreur_du_registre():
    """La validation d'une source est la MÊME qu'à l'enregistrement par
    manage.sh : une seule règle, deux points d'entrée."""
    mauvais = base()
    mauvais["sources"][0]["acl_policy"] = "fournie"
    del mauvais["sources"][0]["acl_groups"]
    with pytest.raises(ContratInvalide, match="liste blanche"):
        manifeste.valider_manifeste(mauvais)


def test_source_declaree_deux_fois_refusee():
    m = base()
    m["sources"].append(dict(m["sources"][0]))
    with pytest.raises(ContratInvalide, match="deux fois"):
        manifeste.valider_manifeste(m)


def test_secrets_sont_des_noms_pas_des_valeurs():
    m = manifeste.valider_manifeste(base(secrets=["jira-token"]))
    assert m["secrets"] == ["jira-token"]
    with pytest.raises(ContratInvalide, match="secret"):
        manifeste.valider_manifeste(base(secrets=[{"nom": "x", "valeur": "s3cr3t"}]))


@pytest.mark.parametrize("ressources,motif", [
    ({"cpus": "beaucoup"}, "cpus"),
    ({"memoire": "512"}, "memoire"),
    ({"disque": "1g"}, "inconnue"),
])
def test_ressources_invalides(ressources, motif):
    with pytest.raises(ContratInvalide, match=motif):
        manifeste.valider_manifeste(base(ressources=ressources))


def test_ressources_partielles_completees_par_defaut():
    """Un module tiers qui part en boucle ne doit pas emporter la machine
    d'ingestion : les bornes existent même quand le manifeste se tait."""
    m = manifeste.valider_manifeste(base(ressources={"memoire": "256m"}))
    assert m["ressources"] == {"cpus": manifeste.RESSOURCES_DEFAUT["cpus"], "memoire": "256m"}


# ── Capacité service_web (lot 3) ─────────────────────────────

def test_service_web_exige_un_port():
    """C'est vers ce port que le proxy enverra /ext/<nom>/ — sans lui, le
    module s'installerait sans être joignable."""
    with pytest.raises(ContratInvalide, match="'port'"):
        manifeste.valider_manifeste(base(capacites=["service_web"], sources=[]))


def test_service_web_avec_port_accepte():
    m = manifeste.valider_manifeste(base(capacites=["service_web"], sources=[], port=8080))
    assert m["port"] == 8080


def test_port_sans_service_web_refuse():
    with pytest.raises(ContratInvalide, match="n'a de sens"):
        manifeste.valider_manifeste(base(port=8080))


@pytest.mark.parametrize("port", [80, 70000, "huit-mille"])
def test_port_invalide_refuse(port):
    with pytest.raises(ContratInvalide, match="port"):
        manifeste.valider_manifeste(base(capacites=["service_web"], sources=[], port=port))


def test_les_deux_capacites_ensemble():
    """Un module peut très bien pousser des documents ET exposer un
    écran — l'assistant de recherche ne fait que le second."""
    m = manifeste.valider_manifeste(base(capacites=["ingestion", "service_web"], port=8080))
    assert m["capacites"] == ["ingestion", "service_web"]
    assert m["sources"][0]["plugin"] == "jira"


def test_entree_de_menu_exige_le_service_web():
    """Une entrée de menu mène sous /ext/<nom>/ : sans la capacité qui
    route ce préfixe, le lien du menu rendrait 404."""
    with pytest.raises(ContratInvalide, match="service_web"):
        manifeste.valider_manifeste(base(
            interface={"nav": [{"libelle": "X", "chemin": "/ext/jira/x"}]},
        ))


def test_manifeste_sans_interface_rend_une_interface_vide():
    assert manifeste.valider_manifeste(base())["interface"] == {"nav": [], "admin_panel": []}
