# test_jetons.py — Ce qu'un module doit vérifier d'une session.
#
# La signature n'est pas vérifiée ici (le contrat n'a pas de dépendance
# cryptographique) : ce qui est éprouvé, ce sont les REVENDICATIONS,
# c'est-à-dire tout ce qu'on oublie quand on n'a que « décoder le jeton »
# en tête.

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from docsearch_contract import ContratInvalide, jetons  # noqa: E402


def charge(**surcharges) -> dict:
    base = {
        "sub": "alice.dupont",
        "token_type": jetons.TYPE_JETON_ACCES,
        "iss": jetons.EMETTEUR_DEFAUT,
        "aud": jetons.AUDIENCE_DEFAUT,
    }
    return {**base, **surcharges}


def test_jeton_valide_rend_l_identite():
    assert jetons.verifier_revendications(charge()) == "alice.dupont"


def test_jeton_de_rafraichissement_refuse():
    """Le contournement classique : un jeton de rafraîchissement a une
    durée de vie bien plus longue qu'un jeton d'accès. L'API le contrôle,
    un module qui l'oublierait ouvrirait une session de plusieurs jours."""
    with pytest.raises(ContratInvalide, match="Type de jeton refusé"):
        jetons.verifier_revendications(charge(token_type="refresh"))


def test_type_de_jeton_absent_refuse():
    m = charge()
    del m["token_type"]
    with pytest.raises(ContratInvalide, match="Type de jeton"):
        jetons.verifier_revendications(m)


def test_emetteur_inattendu_refuse():
    """Sans ce contrôle, un jeton signé par la même autorité pour un
    AUTRE service est accepté."""
    with pytest.raises(ContratInvalide, match="Émetteur"):
        jetons.verifier_revendications(charge(iss="autre-service"))


def test_audience_inattendue_refusee():
    with pytest.raises(ContratInvalide, match="Audience"):
        jetons.verifier_revendications(charge(aud="autre-public"))


def test_audience_en_liste_acceptee():
    """`aud` peut être une chaîne ou une liste au sens de la RFC 7519 —
    selon la bibliothèque qui a décodé le jeton."""
    assert jetons.verifier_revendications(charge(aud=["docsearch", "autre"])) == "alice.dupont"


def test_emetteur_et_audience_surchargeables():
    """Ce sont des DÉFAUTS : une installation qui a changé JWT_ISSUER ne
    doit pas casser tous les modules."""
    payload = charge(iss="docsearch-interne", aud="intranet")
    assert jetons.verifier_revendications(
        payload, emetteur="docsearch-interne", audience="intranet",
    ) == "alice.dupont"


def test_jeton_sans_identite_refuse():
    m = charge()
    del m["sub"]
    with pytest.raises(ContratInvalide, match="sans identité"):
        jetons.verifier_revendications(m)


def test_charge_illisible_refusee():
    with pytest.raises(ContratInvalide, match="illisible"):
        jetons.verifier_revendications("pas un objet")
