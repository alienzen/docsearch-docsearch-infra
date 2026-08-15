# test_plugins.py — Déclaration d'une source portée par un module
# complémentaire.
#
# Aucun service requis. Ce qui est éprouvé ici est ce qu'un
# administrateur peut déclarer — et surtout ce qu'il ne peut PAS, parce
# qu'une déclaration acceptée à tort ne se rattrape plus au moment où
# les documents arrivent.

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from docsearch_contract import ContratInvalide, plugins  # noqa: E402

BASE = {"plugin": "jira", "es_index": "tickets_jira", "acl_policy": "public"}


def test_declaration_minimale_acceptee():
    cfg = plugins.valider_declaration(BASE)
    assert cfg["acl_policy"] == "public"
    assert cfg["searchable"] is True
    assert cfg["fields"] == []


@pytest.mark.parametrize("manquant", ["plugin", "es_index", "acl_policy"])
def test_champ_obligatoire_manquant(manquant):
    entree = dict(BASE)
    del entree[manquant]
    with pytest.raises(ContratInvalide, match=manquant):
        plugins.valider_declaration(entree)


def test_politique_inconnue_refusee():
    with pytest.raises(ContratInvalide, match="Politique d'ACL inconnue"):
        plugins.valider_declaration({**BASE, "acl_policy": "ouvert"})


def test_politique_groupes_sans_groupe_refusee():
    """Sans groupe, aucun document ne serait visible par personne — une
    source muette est plus coûteuse à diagnostiquer qu'un refus."""
    with pytest.raises(ContratInvalide, match="au moins un groupe"):
        plugins.valider_declaration({**BASE, "acl_policy": "groupes"})


def test_politique_fournie_sans_liste_blanche_refusee():
    """LE contrôle du lot : une liste blanche vide se lirait comme
    « aucune restriction », c'est-à-dire tout ce que le module décide."""
    with pytest.raises(ContratInvalide, match="liste blanche"):
        plugins.valider_declaration({**BASE, "acl_policy": "fournie"})


def test_groupes_sans_la_politique_correspondante_refuses():
    with pytest.raises(ContratInvalide, match="acl_groups"):
        plugins.valider_declaration({**BASE, "acl_groups": ["DL-RH"]})
    with pytest.raises(ContratInvalide, match="acl_principaux"):
        plugins.valider_declaration({**BASE, "acl_principaux": ["DL-RH"]})


def test_nom_d_index_invalide_refuse():
    with pytest.raises(ContratInvalide, match="es_index"):
        plugins.valider_declaration({**BASE, "es_index": "Tickets Jira"})


def test_champ_supplementaire_ne_peut_pas_masquer_le_schema_commun():
    """`source` et `acl` portent toute la recherche fédérée et tout le
    contrôle d'accès : un module qui les redéfinirait réécrirait le sens
    de champs dont dépend le reste du produit."""
    for reserve in ("source", "acl", "content", "run_id"):
        with pytest.raises(ContratInvalide, match="schéma DocSearch commun"):
            plugins.valider_declaration({
                **BASE, "fields": [{"nom": reserve, "es_type": "keyword"}],
            })


def test_facette_sur_champ_texte_refusee():
    """Le piège déjà payé par les sources SQL le 2026-08-13 : une
    agrégation `terms` sur un champ `text` fait échouer le shard, et
    _verifier_shards() refuse alors la recherche fédérée entière — pas
    seulement cette source."""
    with pytest.raises(ContratInvalide, match="facette exige"):
        plugins.valider_declaration({
            **BASE, "fields": [{"nom": "bureau", "es_type": "text", "facet": True}],
        })


def test_type_es_invalide_refuse():
    with pytest.raises(ContratInvalide, match="Type ES invalide"):
        plugins.valider_declaration({
            **BASE, "fields": [{"nom": "montant", "es_type": "decimal"}],
        })


def test_champ_declare_deux_fois_refuse():
    with pytest.raises(ContratInvalide, match="deux fois"):
        plugins.valider_declaration({
            **BASE,
            "fields": [
                {"nom": "bureau", "es_type": "keyword"},
                {"nom": "bureau", "es_type": "text"},
            ],
        })


def test_aller_retour_dict():
    cfg = plugins.valider_declaration({
        **BASE, "acl_policy": "fournie", "acl_principaux": ["DL-RH"],
        "label": "Tickets", "fields": [{"nom": "bureau", "es_type": "keyword", "facet": True}],
    })
    source = plugins.depuis_dict("tickets", cfg)
    assert source.name == "tickets"
    assert source.acl_principaux == ("DL-RH",)
    assert source.fields[0].nom == "bureau"
    assert source.fields[0].facet is True


def test_lecture_tolerante_aux_cles_inconnues():
    """Le chemin de lecture est emprunté à chaque passage : une entrée
    écrite par une version antérieure — ou postérieure — du contrat doit
    continuer de se lire plutôt que de faire tomber le worker."""
    source = plugins.depuis_dict("vieille", {"plugin": "x", "es_index": "y", "cle_du_futur": 42})
    assert source.plugin == "x"
    assert source.searchable is True
