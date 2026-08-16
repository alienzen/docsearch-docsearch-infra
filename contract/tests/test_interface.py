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
    assert interface.valider_interface({}, "assistant") == {
        "nav": [], "admin_panel": [], "result_action": [], "page": [],
    }


def test_accroche_inconnue_refusee():
    """Le vocabulaire est fermé : une accroche que le cœur ne rend pas
    ferait s'installer un module qui promet un écran que rien n'affiche.
    Les quatre du plan sont servies — c'est une CINQUIÈME qui est refusée
    ici, et ce contrôle reste utile pour la suivante."""
    with pytest.raises(ContratInvalide, match="non servie"):
        interface.valider_interface({"widget_barre_laterale": []}, "assistant")


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


# ── Panneau d'administration (accroche admin_panel) ──────────

def panneau(*reglages):
    return interface.valider_interface({"admin_panel": list(reglages)}, "jira")["admin_panel"]


def test_reglage_texte():
    r = panneau({"cle": "url", "type": "texte", "libelle": "Adresse", "defaut": "https://x"})[0]
    assert r["defaut"] == "https://x"
    assert r["variable"] == "DOCSEARCH_OPT_URL"


def test_le_nom_de_variable_est_prefixe():
    """Sans préfixe, un module déclarant `kafka_bootstrap` ou
    `docsearch_api_url` réécrirait la configuration que le cœur lui
    impose. C'est le contrôle qui compte le plus de cette accroche."""
    for cle in ("kafka_bootstrap", "docsearch_api_url", "path"):
        r = panneau({"cle": cle, "type": "texte", "libelle": "X"})[0]
        assert r["variable"].startswith("DOCSEARCH_OPT_")
        assert r["variable"] != cle.upper()


@pytest.mark.parametrize("valeur,attendu", [(True, "true"), (False, "false"), (None, "false"), ("true", "true")])
def test_booleen_normalise_en_texte(valeur, attendu):
    """systemd ne porte que du texte : un module reçoit « true » ou
    « false », jamais autre chose, pour n'avoir aucune convention à
    deviner."""
    assert panneau({"cle": "actif", "type": "booleen", "libelle": "Actif", "defaut": valeur})[0]["defaut"] == attendu


def test_booleen_refuse_autre_chose():
    with pytest.raises(ContratInvalide, match="booléen attendu"):
        panneau({"cle": "actif", "type": "booleen", "libelle": "Actif", "defaut": "peut-être"})


def test_liste_jointe_par_virgules():
    r = panneau({"cle": "bureaux", "type": "liste", "libelle": "Bureaux", "defaut": ["Paris", " Reims "]})[0]
    assert r["defaut"] == "Paris,Reims"


def test_virgule_dans_une_valeur_de_liste_refusee():
    """La virgule est le séparateur : l'accepter dans un élément ferait
    relire deux valeurs là où le module en attend une."""
    with pytest.raises(ContratInvalide, match="virgule"):
        panneau({"cle": "x", "type": "liste", "libelle": "X", "defaut": ["a,b"]})


def test_saut_de_ligne_refuse():
    """Une valeur multiligne casserait le fichier d'unité systemd, qui
    est en clé=valeur par ligne."""
    with pytest.raises(ContratInvalide, match="saut de ligne"):
        panneau({"cle": "x", "type": "texte", "libelle": "X", "defaut": "a\nb"})


@pytest.mark.parametrize("cle", ["Majuscule", "avec-tiret", "1chiffre", ""])
def test_cle_invalide_refusee(cle):
    with pytest.raises(ContratInvalide, match="Clé de réglage"):
        panneau({"cle": cle, "type": "texte", "libelle": "X"})


def test_type_inconnu_refuse():
    with pytest.raises(ContratInvalide, match="Type de réglage"):
        panneau({"cle": "x", "type": "entier", "libelle": "X"})


def test_reglage_declare_deux_fois_refuse():
    with pytest.raises(ContratInvalide, match="deux fois"):
        panneau({"cle": "x", "type": "texte", "libelle": "A"}, {"cle": "x", "type": "booleen", "libelle": "B"})


def test_panneau_demesure_refuse():
    """Un panneau d'administration se lit, il ne se parcourt pas."""
    with pytest.raises(ContratInvalide, match="maximum"):
        panneau(*[{"cle": f"r{i}", "type": "texte", "libelle": "X"} for i in range(21)])


def test_valeur_trop_longue_refusee():
    with pytest.raises(ContratInvalide, match="trop longue"):
        panneau({"cle": "x", "type": "texte", "libelle": "X", "defaut": "a" * 501})


def test_interface_sans_panneau_rend_une_liste_vide():
    assert interface.valider_interface({}, "jira")["admin_panel"] == []


# ── Actions de résultat et pages ─────────────────────────────

def accroche(cle, *entrees, module="jira"):
    return interface.valider_interface({cle: list(entrees)}, module)[cle]


def test_action_de_resultat_valide():
    a = accroche("result_action", {"libelle": "Ouvrir", "chemin": "/ext/jira/ouvrir"})[0]
    assert a["chemin"] == "/ext/jira/ouvrir"


def test_page_valide_accepte_titre_ou_libelle():
    """`titre` est le mot naturel pour un écran, `libelle` pour un lien —
    les deux sont acceptés plutôt que d'imposer une gymnastique."""
    assert accroche("page", {"titre": "Tableau", "chemin": "/ext/jira/t"})[0]["libelle"] == "Tableau"
    assert accroche("page", {"libelle": "Tableau", "chemin": "/ext/jira/t"})[0]["libelle"] == "Tableau"


@pytest.mark.parametrize("cle", ["result_action", "page"])
def test_lien_vers_un_autre_module_refuse(cle):
    """Le même contrôle que pour `nav`, et pour la même raison : un module
    ne pointe que vers lui-même."""
    with pytest.raises(ContratInvalide, match="hors de /ext/jira/"):
        accroche(cle, {"libelle": "X", "chemin": "/ext/autre/x"})


@pytest.mark.parametrize("cle", ["result_action", "page"])
def test_chemin_hors_ext_refuse(cle):
    with pytest.raises(ContratInvalide, match="chemin invalide"):
        accroche(cle, {"libelle": "X", "chemin": "/admin.html"})


@pytest.mark.parametrize("cle", ["result_action", "page"])
def test_libelle_obligatoire(cle):
    with pytest.raises(ContratInvalide, match="sans libellé"):
        accroche(cle, {"chemin": "/ext/jira/x"})


def test_trop_d_actions_refusees():
    """Une carte de résultat sert à lire, pas à porter une barre
    d'outils."""
    with pytest.raises(ContratInvalide, match="maximum"):
        accroche("result_action", *[{"libelle": f"A{i}", "chemin": "/ext/jira/x"} for i in range(4)])


def test_deux_pages_refusees():
    with pytest.raises(ContratInvalide, match="Une seule page"):
        accroche("page", {"titre": "A", "chemin": "/ext/jira/a"}, {"titre": "B", "chemin": "/ext/jira/b"})


def test_icone_libre_refusee_sur_une_action():
    with pytest.raises(ContratInvalide, match="icône inconnue"):
        accroche("result_action", {"libelle": "X", "chemin": "/ext/jira/x", "icone": "ma-classe"})


def test_le_vocabulaire_est_complet():
    """Les quatre accroches du §3 sont servies : plus aucune n'est
    refusée pour cause de non-implémentation."""
    assert set(interface.ACCROCHES) == {"nav", "admin_panel", "result_action", "page"}
