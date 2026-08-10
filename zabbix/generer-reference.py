#!/usr/bin/env python3
"""Génère REFERENCE.md à partir du modèle Zabbix.

Le catalogue des éléments et des déclencheurs est TIRÉ du YAML, jamais
recopié à la main : une sonde ajoutée sans mise à jour de la
documentation produirait exactement le genre d'écart qu'on ne remarque
que le jour où l'on cherche pourquoi une alerte n'existe pas.

    ./generer-reference.py            # écrit REFERENCE.md
    ./generer-reference.py --verifier # sort en erreur si le fichier a divergé
"""

import sys
from pathlib import Path

import yaml

ICI = Path(__file__).resolve().parent
MODELE = ICI / "templates" / "docsearch-zabbix-7.0.yaml"
SORTIE = ICI / "REFERENCE.md"

# Type d'élément → comment la valeur arrive réellement.
COLLECTE = {
    None:            "agent",
    "ZABBIX_ACTIVE": "agent (actif)",
    "DEPENDENT":     "dépendant",
    "HTTP_AGENT":    "HTTP",
    "SIMPLE":        "contrôle simple",
    "CALCULATED":    "calculé",
}

PRIORITES = {
    "DISASTER": "Désastre",
    "HIGH":     "Haute",
    "AVERAGE":  "Moyenne",
    "WARNING":  "Avertissement",
    "INFO":     "Information",
    "NOT_CLASSIFIED": "Non classée",
}

ORDRE_PRIORITE = ["DISASTER", "HIGH", "AVERAGE", "WARNING", "INFO", "NOT_CLASSIFIED"]


def cellule(texte):
    """Rend une chaîne inoffensive dans une cellule de tableau Markdown."""
    return (texte or "").replace("|", "\\|").replace("\n", " ").strip()


def premier_paragraphe(texte):
    """Premier paragraphe d'une description, replié sur une ligne.

    Pas la première LIGNE : les descriptions du modèle sont repliées à
    72 colonnes, et n'en garder qu'une couperait les phrases en deux.
    """
    if not texte:
        return ""
    accumule = []
    for ligne in texte.strip().splitlines():
        ligne = ligne.strip()
        if not ligne:
            if accumule:
                break
            continue
        accumule.append(ligne)
    return cellule(" ".join(accumule))


def elements(modele):
    """Éléments du modèle, prototypes de découverte compris."""
    for e in modele.get("items", []):
        yield e, None
    for regle in modele.get("discovery_rules", []):
        for e in regle.get("item_prototypes", []):
            yield e, regle["name"]


def declencheurs(modele):
    for e in modele.get("items", []):
        for d in e.get("triggers", []):
            yield d, False
    for regle in modele.get("discovery_rules", []):
        for d in regle.get("trigger_prototypes", []):
            yield d, True


def rendre(modele):
    lignes = []
    nom = modele["template"]
    lignes.append(f"### {nom}")
    lignes.append("")
    if modele.get("description"):
        lignes.append(modele["description"].strip())
        lignes.append("")

    macros = modele.get("macros", [])
    if macros:
        lignes.append("**Macros**")
        lignes.append("")
        lignes.append("| Macro | Défaut | Rôle |")
        lignes.append("|---|---|---|")
        for m in macros:
            lignes.append(
                f"| `{cellule(m['macro'])}` | `{cellule(str(m.get('value', '')))}` "
                f"| {premier_paragraphe(m.get('description'))} |"
            )
        lignes.append("")

    lignes.append("**Éléments**")
    lignes.append("")
    lignes.append("| Clé | Nom | Collecte | Intervalle |")
    lignes.append("|---|---|---|---|")
    for e, regle in sorted(elements(modele), key=lambda x: x[0]["key"]):
        mode = COLLECTE.get(e.get("type"), e.get("type", "agent"))
        if regle:
            mode += " (découverte)"
        intervalle = e.get("delay", "—") if e.get("type") != "DEPENDENT" else "—"
        lignes.append(
            f"| `{cellule(e['key'])}` | {cellule(e['name'])} | {mode} | {intervalle} |"
        )
    lignes.append("")

    liste = sorted(
        declencheurs(modele),
        key=lambda x: (ORDRE_PRIORITE.index(x[0].get("priority", "NOT_CLASSIFIED")),
                       x[0]["name"]),
    )
    if liste:
        lignes.append("**Déclencheurs**")
        lignes.append("")
        lignes.append("| Priorité | Nom | Ce qu'il signifie |")
        lignes.append("|---|---|---|")
        for d, proto in liste:
            marque = " *(prototype)*" if proto else ""
            lignes.append(
                f"| {PRIORITES.get(d.get('priority', ''), '—')} "
                f"| {cellule(d['name'])}{marque} "
                f"| {premier_paragraphe(d.get('description'))} |"
            )
        lignes.append("")

    return lignes


def construire():
    export = yaml.safe_load(MODELE.read_text())["zabbix_export"]
    modeles = export["templates"]

    nb_elements = sum(len(m.get("items", [])) for m in modeles)
    nb_prototypes = sum(len(r.get("item_prototypes", []))
                        for m in modeles for r in m.get("discovery_rules", []))
    nb_declencheurs = sum(len(list(declencheurs(m))) for m in modeles)

    lignes = [
        "# Sondes DocSearch — catalogue",
        "",
        "*Généré par `generer-reference.py` à partir de "
        "`templates/docsearch-zabbix-7.0.yaml`. Ne pas modifier à la main.*",
        "",
        f"**{len(modeles)} modèles · {nb_elements} éléments "
        f"(+ {nb_prototypes} prototypes de découverte) · "
        f"{nb_declencheurs} déclencheurs.**",
        "",
        "Le pourquoi de ce découpage est dans [README.md](README.md) ; "
        "la procédure d'installation est dans "
        "[docsearch-docs/guide_supervision_zabbix.md]"
        "(../../docsearch-docs/guide_supervision_zabbix.md).",
        "",
        "## Sommaire",
        "",
    ]
    for m in modeles:
        ancre = m["template"].lower().replace(" ", "-")
        lignes.append(f"- [{m['template']}](#{ancre})")
    lignes.append("")
    lignes.append("## Modèles")
    lignes.append("")
    for m in modeles:
        lignes += rendre(m)
    return "\n".join(lignes).rstrip() + "\n"


def main():
    contenu = construire()
    if "--verifier" in sys.argv:
        actuel = SORTIE.read_text() if SORTIE.exists() else ""
        if actuel != contenu:
            print(f"{SORTIE.name} a divergé du modèle — relancer "
                  f"./generer-reference.py", file=sys.stderr)
            return 1
        print(f"{SORTIE.name} est à jour.")
        return 0
    SORTIE.write_text(contenu)
    print(f"{SORTIE.name} écrit ({len(contenu.splitlines())} lignes).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
