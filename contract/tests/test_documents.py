# test_documents.py — Messages poussés par un module complémentaire.
#
# Aucun service requis. C'est le fichier qui compte le plus du lot 1 :
# tout ce qu'un module peut tenter d'obtenir — écrire dans la source
# d'un autre, se déclarer public, nommer un groupe qu'il n'a pas le
# droit de nommer, glisser un champ non déclaré — se refuse ici, avant
# qu'Elasticsearch ne voie quoi que ce soit.

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from docsearch_contract import CONTRACT_VERSION, ContratInvalide, documents, plugins  # noqa: E402

MAJEURE_MINEURE = ".".join(CONTRACT_VERSION.split(".")[:2])


def source(**surcharges) -> plugins.PluginSource:
    base = {
        "plugin": "jira", "es_index": "tickets_jira", "acl_policy": "public",
    }
    cfg = plugins.valider_declaration({**base, **surcharges})
    return plugins.depuis_dict("tickets", cfg)


def enveloppe(**surcharges) -> dict:
    base = {
        "contract_version": CONTRACT_VERSION,
        "plugin": "jira", "source": "tickets", "run_id": "passe-1",
        "type": "document", "document": {"id": "T-1", "title": "Un ticket"},
    }
    return {**base, **surcharges}


# ── Enveloppe ────────────────────────────────────────────────

def test_enveloppe_valide():
    msg = documents.valider_message(enveloppe())
    assert msg["source"] == "tickets"
    assert msg["run_id"] == "passe-1"


def test_version_de_contrat_incompatible_refusee():
    with pytest.raises(ContratInvalide, match="Version de contrat"):
        documents.valider_message(enveloppe(contract_version="9.9.9"))


def test_version_de_contrat_absente_refusee():
    msg = enveloppe()
    del msg["contract_version"]
    with pytest.raises(ContratInvalide, match="Version de contrat"):
        documents.valider_message(msg)


def test_compatibilite_de_version():
    """Tant que la majeure est 0, la forme du contrat n'est pas figée :
    c'est `majeure.mineure` qui doit correspondre."""
    assert documents.version_compatible(CONTRACT_VERSION) is True
    assert documents.version_compatible(f"{MAJEURE_MINEURE}.99") is True
    assert documents.version_compatible("0.0.1") is False
    assert documents.version_compatible("pas une version") is False
    assert documents.version_compatible(None) is False


@pytest.mark.parametrize("clef", ["plugin", "source", "run_id"])
def test_champ_d_enveloppe_manquant(clef):
    msg = enveloppe()
    del msg[clef]
    with pytest.raises(ContratInvalide, match=clef):
        documents.valider_message(msg)


def test_type_de_message_inconnu():
    with pytest.raises(ContratInvalide, match="Type de message"):
        documents.valider_message(enveloppe(type="upsert"))


def test_suppression_sans_doc_id():
    with pytest.raises(ContratInvalide, match="doc_id"):
        documents.valider_message(enveloppe(type="delete", document=None))


def test_fin_de_passe_sans_document():
    """`run_end` ne porte rien d'autre que son run_id — c'est le signal
    qui autorise la réconciliation."""
    msg = documents.valider_message(enveloppe(type="run_end", document=None))
    assert msg["type"] == "run_end"


# ── Émetteur ─────────────────────────────────────────────────

def test_un_module_ne_pousse_pas_sur_la_source_d_un_autre():
    """Sans ce contrôle, tout module installé pourrait écrire dans la
    source d'un autre — y compris dans une source dont la politique
    d'ACL est plus permissive que la sienne."""
    msg = documents.valider_message(enveloppe(plugin="confluence"))
    with pytest.raises(ContratInvalide, match="appartient à 'jira'"):
        documents.verifier_emetteur(source(), msg)


# ── Identité ─────────────────────────────────────────────────

def test_doc_id_stable_et_cloisonne_par_source():
    assert documents.doc_id_pour("tickets", "T-1") == documents.doc_id_pour("tickets", "T-1")
    # Deux sources peuvent légitimement employer le même identifiant, et
    # elles partagent l'alias de recherche fédérée.
    assert documents.doc_id_pour("tickets", "1") != documents.doc_id_pour("wiki", "1")


def test_document_sans_id_refuse():
    with pytest.raises(ContratInvalide, match="sans 'id'"):
        documents.construire_document(source(), {"title": "x"}, "passe-1")


def test_id_demesure_refuse():
    with pytest.raises(ContratInvalide, match="trop long"):
        documents.construire_document(source(), {"id": "x" * 900}, "passe-1")


# ── Construction du document ─────────────────────────────────

def test_champs_imposes_par_le_coeur():
    doc_id, doc, _ = documents.construire_document(
        source(), {"id": "T-1", "title": "Un ticket", "content": "corps"}, "passe-7",
    )
    assert doc_id == documents.doc_id_pour("tickets", "T-1")
    assert doc["source"] == "tickets"      # jamais ce que le module annonce
    assert doc["type"] == "plugin"
    assert doc["run_id"] == "passe-7"
    assert doc["indexed_at"]
    # Repli de filename : titre puis identifiant, jamais vide — la carte
    # de résultat affiche ce champ.
    assert doc["filename"] == "Un ticket"


def test_date_absente_omise_et_non_nulle():
    _, doc, _ = documents.construire_document(source(), {"id": "T-1"}, "passe-1")
    assert "date_created" not in doc
    assert "date_modified" not in doc


def test_champ_supplementaire_declare_accepte():
    src = source(fields=[{"nom": "bureau", "es_type": "keyword"}])
    _, doc, _ = documents.construire_document(
        src, {"id": "T-1", "extra": {"bureau": "Paris"}}, "passe-1",
    )
    assert doc["bureau"] == "Paris"


def test_champ_supplementaire_non_declare_refuse():
    """Refusé ici, et pas laissé à `dynamic: strict` : ES rejetterait
    aussi le document, mais dans une erreur de bulk noyée dans un lot,
    sans dire quel module ni quelle source."""
    with pytest.raises(ContratInvalide, match="non déclaré"):
        documents.construire_document(
            source(), {"id": "T-1", "extra": {"bureau": "Paris"}}, "passe-1",
        )


# ── ACL : le cœur du contrat ─────────────────────────────────

def test_politique_public():
    _, doc, _ = documents.construire_document(source(), {"id": "T-1"}, "passe-1")
    assert doc["acl"] == {"public": True}


def test_politique_groupes_ignore_ce_que_le_module_propose():
    src = source(acl_policy="groupes", acl_groups=["DL-RH"])
    _, doc, _ = documents.construire_document(
        src, {"id": "T-1", "acl": {"public": True, "groups": ["DL-TOUT-LE-MONDE"]}}, "passe-1",
    )
    assert doc["acl"] == {"public": False, "groups": ["DL-RH"]}


def test_public_propose_par_le_module_toujours_ignore():
    """LE test du lot 1. `acl.public: true` rend un document visible par
    TOUT LE MONDE (build_acl_filter côté API) : c'est le seul champ dont
    l'acceptation naïve ouvrirait tout le corpus."""
    src = source(acl_policy="fournie", acl_principaux=["DL-RH"])
    _, doc, _ = documents.construire_document(
        src, {"id": "T-1", "acl": {"public": True, "groups": ["DL-RH"]}}, "passe-1",
    )
    assert doc["acl"]["public"] is False


def test_politique_fournie_filtre_contre_la_liste_blanche():
    src = source(acl_policy="fournie", acl_principaux=["DL-RH", "alice"])
    _, doc, refuses = documents.construire_document(
        src,
        {"id": "T-1", "acl": {"users": ["alice", "bob"], "groups": ["DL-RH", "DL-DIRECTION"]}},
        "passe-1",
    )
    assert doc["acl"]["users"] == ["alice"]
    assert doc["acl"]["groups"] == ["DL-RH"]
    # Les principaux écartés remontent à l'appelant, qui les journalise :
    # une ACL silencieusement rétrécie donne un document introuvable sans
    # rien à quoi le rattacher.
    assert refuses == ["DL-DIRECTION", "bob"]


def test_acl_entierement_refusee_rejette_le_document():
    """Plutôt qu'un document indexé mais invisible pour tout le monde —
    le genre de panne qu'on ne diagnostique jamais."""
    src = source(acl_policy="fournie", acl_principaux=["DL-RH"])
    with pytest.raises(ContratInvalide, match="Aucun principal autorisé"):
        documents.construire_document(
            src, {"id": "T-1", "acl": {"groups": ["DL-DIRECTION"]}}, "passe-1",
        )


def test_politique_fournie_sans_acl_du_tout_rejette_le_document():
    src = source(acl_policy="fournie", acl_principaux=["DL-RH"])
    with pytest.raises(ContratInvalide, match="Aucun principal autorisé"):
        documents.construire_document(src, {"id": "T-1"}, "passe-1")
