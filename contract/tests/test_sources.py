# test_sources.py — Vue générique des registres de sources
#
# Aucun service requis : `docsearch_contract.sources` est sans
# dépendance, les registres y sont de simples objets exposant
# get_sources(). C'est tout l'intérêt d'avoir sorti ces règles des
# modules qui parlent à Redis — la règle d'accès se teste sans Redis.
#
#   cd contract && python3 -m pytest

import sys
from dataclasses import dataclass, field
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from docsearch_contract import sources  # noqa: E402


# ── Doublures des trois registres ────────────────────────────
# Reproduisent les attributs réels de Source / SqlSource / WebSource, y
# compris ceux qui LEUR SONT PROPRES : le test vérifie justement que la
# vue générique s'accommode d'objets hétérogènes.


@dataclass(frozen=True)
class SourceFichier:
    name: str
    es_index: str
    folder: str = "/sources/x"
    label: str = ""
    searchable: bool = True
    collectable: bool = True
    description: str = ""
    ocr_enabled: bool = False
    allowed_groups: tuple[str, ...] = field(default_factory=tuple)


@dataclass(frozen=True)
class SourceSql:
    name: str
    es_index: str
    query: str = "SELECT 1"
    label: str = ""
    searchable: bool = True
    collectable: bool = True
    description: str = ""
    allowed_groups: tuple[str, ...] = field(default_factory=tuple)


class RegistreFactice:
    def __init__(self, sources_par_nom):
        self._sources = sources_par_nom

    def get_sources(self):
        return self._sources


@pytest.fixture
def registres():
    return {
        "file": RegistreFactice({
            "documents": SourceFichier("documents", "documents", label="Documents"),
            "rh":        SourceFichier("rh", "rh_docs", label="RH", allowed_groups=("DL-RH",)),
            "archives":  SourceFichier("archives", "archives", searchable=False),
        }),
        "sql": RegistreFactice({
            "clients": SourceSql("clients", "clients_sql", label="Clients", collectable=False),
        }),
    }


def test_entree_normalise_les_attributs_communs(registres):
    e = sources.find(registres, "clients")
    assert (e.name, e.type, e.es_index, e.label) == ("clients", "sql", "clients_sql", "Clients")
    assert e.searchable is True
    assert e.collectable is False
    assert e.allowed_groups == ()


def test_attribut_propre_au_type_accessible_par_native(registres):
    """La vue générique n'efface pas le type d'origine : `native` reste
    le seul chemin vers ce qui n'est pas commun aux trois registres."""
    assert sources.find(registres, "clients").native.query == "SELECT 1"
    assert sources.find(registres, "documents").native.folder == "/sources/x"


def test_source_absente_rend_none(registres):
    assert sources.find(registres, "inexistante") is None


def test_source_non_cherchable_exclue(registres):
    """« archives » reste dans les registres — elle continue d'être
    indexée — mais sort de ce qu'un utilisateur peut atteindre."""
    assert "archives" not in sources.searchable_names(registres, [])
    assert sources.find(registres, "archives") is not None


def test_groupes_autorises_filtrent_la_source(registres):
    sans_groupe = sources.searchable_names(registres, [])
    membre_rh   = sources.searchable_names(registres, ["DL-RH"])
    autre       = sources.searchable_names(registres, ["DL-COMPTA"])

    assert "rh" not in sans_groupe
    assert "rh" not in autre
    assert "rh" in membre_rh
    # Les sources sans restriction restent visibles dans les trois cas.
    assert {"documents", "clients"} <= set(sans_groupe)


def test_ordre_stable_registres_puis_insertion(registres):
    assert sources.searchable_names(registres, ["DL-RH"]) == ["documents", "rh", "clients"]


def test_collectable_independant_de_searchable(registres):
    collectables = sources.collectable_names(registres)
    # « clients » est cherchable mais exclue des collections…
    assert "clients" not in collectables
    # …et « archives » l'inverse : retirée de la recherche, elle reste
    # collectable, ce qui est le comportement des trois registres.
    assert "archives" in collectables


def test_attribut_manquant_ne_casse_pas_l_enumeration():
    """Un type de source à venir peut n'exposer qu'une partie des
    attributs communs. L'énumération doit survivre — sans quoi une seule
    source mal formée rendrait la recherche vide POUR TOUT LE MONDE."""

    class SourceMinimale:
        es_index = "minimal"

    registres = {"plugin:x": RegistreFactice({"minimal": SourceMinimale()})}
    entries = list(sources.iter_entries(registres))

    assert len(entries) == 1
    assert entries[0].type == "plugin:x"
    assert entries[0].label == ""
    # Repli fermé : sans `searchable` déclaré, la source n'est pas
    # cherchable. L'inverse mettrait une source inconnue à la portée de
    # tout le monde.
    assert entries[0].searchable is False
    assert sources.searchable_names(registres, []) == []


def test_visible_to_accepte_entree_et_objet_natif(registres):
    e = sources.find(registres, "rh")
    assert sources.visible_to(e, ["DL-RH"]) is True
    assert sources.visible_to(e.native, ["DL-RH"]) is True
    assert sources.visible_to(e, []) is False
    assert sources.visible_to(e.native, []) is False


def test_egalite_ignore_l_objet_natif():
    """Deux entrées décrivant la même source sont égales même si les
    objets de registre qui les ont produites diffèrent — sans quoi
    comparer deux vues (celle de /search et celle du worker d'alertes)
    signalerait des écarts qui n'en sont pas."""
    a = sources.entry("file", "x", SourceFichier("x", "x_idx", label="X"))
    b = sources.entry("file", "x", SourceFichier("x", "x_idx", label="X", folder="/autre"))
    assert a == b
