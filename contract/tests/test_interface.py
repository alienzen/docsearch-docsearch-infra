# test_interface.py — Accroches d'interface déclarées par un module.
#
# Aucun service requis. Ce qui est éprouvé ici est ce qu'un module peut
# ajouter à l'écran de TOUS les utilisateurs — et surtout ce qu'il ne peut
# pas y ajouter.

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from docsearch_contract import ContratInvalide, interface  # noqa: E402

ENTREE = {"libelle": "Assistant", "chemin": "/ext/assistant/", "icone": "fr-icon-chat-3-line"}


def test_entree_de_menu_valide():
    r = interface.valider_interface({"nav": [ENTREE]}, "assistant")
    assert r["nav"] == [ENTREE]


def test_interface_vide_acceptee():
    assert interface.valider_interface({}, "assistant") == {"nav": []}


def test_accroche_non_servie_refusee():
    """`result_action`, `admin_panel` et `page` sont prévues par le plan
    et ne sont pas rendues : les accepter ferait s'installer un module qui
    promet un écran que rien n'affiche."""
    with pytest.raises(ContratInvalide, match="non servie"):
        interface.valider_interface({"result_action": []}, "assistant")


def test_lien_vers_un_autre_module_refuse():
    """LE contrôle de ce lot : sans lui, un module poserait dans le menu
    de tout le monde un lien vers n'importe où."""
    with pytest.raises(ContratInvalide, match="hors de /ext/assistant/"):
        interface.valider_interface(
            {"nav": [{**ENTREE, "chemin": "/ext/autre-module/page"}]}, "assistant",
        )


@pytest.mark.parametrize("chemin", ["/admin.html", "https://exterieur.example/x", "/", "ext/assistant/"])
def test_chemin_hors_ext_refuse(chemin):
    with pytest.raises(ContratInvalide, match="Chemin"):
        interface.valider_interface({"nav": [{**ENTREE, "chemin": chemin}]}, "assistant")


def test_icone_libre_refusee():
    """Le cœur rend cette valeur comme une classe CSS : une chaîne libre
    permettrait d'injecter n'importe quel nom de classe dans la page."""
    with pytest.raises(ContratInvalide, match="Icône"):
        interface.valider_interface({"nav": [{**ENTREE, "icone": "ma-classe"}]}, "assistant")


def test_icone_facultative():
    entree = {"libelle": "Assistant", "chemin": "/ext/assistant/"}
    assert interface.valider_interface({"nav": [entree]}, "assistant")["nav"][0]["icone"] is None


def test_libelle_vide_refuse():
    with pytest.raises(ContratInvalide, match="sans libellé"):
        interface.valider_interface({"nav": [{**ENTREE, "libelle": "  "}]}, "assistant")


def test_libelle_demesure_refuse():
    """Une entrée de menu vit dans un en-tête partagé : un libellé de 200
    caractères ne tronque pas, il casse la mise en page de tous."""
    with pytest.raises(ContratInvalide, match="trop long"):
        interface.valider_interface({"nav": [{**ENTREE, "libelle": "x" * 60}]}, "assistant")


def test_entree_declaree_deux_fois_refusee():
    with pytest.raises(ContratInvalide, match="deux fois"):
        interface.valider_interface({"nav": [ENTREE, dict(ENTREE)]}, "assistant")
