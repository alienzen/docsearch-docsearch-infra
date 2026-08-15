# Créer un module complémentaire (plugin)

Un module complémentaire alimente DocSearch avec une source de données que
le cœur ne sait pas lire — un outil de tickets, un intranet, une base
métier. Il tourne dans **son propre conteneur**, écrit dans **son propre
langage**, et ne parle qu'à **Kafka**.

Voir [PLAN-PLUGINS.md](PLAN-PLUGINS.md) pour le raisonnement, et le
[README de docsearch-ingestion](../docsearch-ingestion/README.md#connecteur-de-modules-complémentaires-plugins)
pour le détail du format des messages.

## Ce que le module ne peut pas faire

Ce n'est pas une liste de bonnes pratiques, c'est ce que le cœur refuse :

| Tentative | Ce qui se passe |
|---|---|
| Écrire dans Elasticsearch | il n'a ni l'URL du cluster ni de compte |
| Pousser sur la source d'un autre module | message refusé (`verifier_emetteur`) |
| Se déclarer public (`acl.public: true`) | ignoré, dans les trois politiques d'ACL |
| Nommer un groupe hors de sa liste blanche | le principal est écarté et journalisé |
| Envoyer un champ non déclaré | document refusé, avant même Elasticsearch |
| Livrer une image en `:latest` | manifeste refusé à l'installation |
| Embarquer un secret dans son manifeste | le manifeste ne porte que des NOMS de secrets podman |

## 1. Le manifeste

`manifeste.json`, à la racine de l'archive de livraison :

```json
{
  "nom": "jira",
  "version": "1.2.0",
  "contract_version": "0.3.0",
  "image": "registre.interne/docsearch-plugins/jira:1.2.0",
  "description": "Tickets Jira du support",
  "auteur": "Équipe outils",
  "capacites": ["ingestion"],
  "secrets": ["jira-token"],
  "ressources": {"cpus": "0.5", "memoire": "256m"},
  "sources": [
    {
      "nom": "tickets",
      "es_index": "tickets_jira",
      "acl_policy": "groupes",
      "acl_groups": ["DL-SUPPORT"],
      "label": "Tickets",
      "fields": [
        {"nom": "bureau", "es_type": "keyword", "facet": true, "facet_label": "Bureau"}
      ]
    }
  ]
}
```

- **`contract_version`** — la version du contrat que le module vise. Tant
  que sa majeure est `0`, la **mineure doit correspondre** à celle du cœur
  (`contract/docsearch_contract/version.py`) : la forme du contrat n'est
  pas encore figée.
- **`capacites`** — aujourd'hui `ingestion` seulement. `service_web`
  (écrans et routes sous `/ext/<nom>/`) est prévue par le §2 du plan et
  **n'est pas encore routée** : la déclarer fait refuser le manifeste,
  plutôt que d'installer un module à moitié servi.
- **`sources`** — une source n'y déclare pas son `plugin` : c'est `nom`
  qui en décide. Un manifeste ne peut donc pas revendiquer la source d'un
  autre module.
- **`acl_policy`** — `public`, `groupes` (exige `acl_groups`) ou `fournie`
  (exige `acl_principaux`, la liste blanche des utilisateurs et groupes que
  le module a le droit de nommer ; une liste vide est **refusée**, elle se
  lirait comme « aucune restriction »).

## 2. Le code du module

Aucune contrainte de langage : il lui faut un client Kafka et de quoi lire
sa source. Trois variables d'environnement lui sont fournies par l'unité
générée à l'installation :

| Variable | Contenu |
|---|---|
| `KAFKA_BOOTSTRAP` | l'adresse du broker |
| `DOCSEARCH_TOPIC` | le topic où pousser (`documents-ready`) |
| `DOCSEARCH_PLUGIN` | son propre nom, à recopier dans chaque message |

Ses secrets arrivent par `podman secret`, montés dans
`/run/secrets/<nom>`. **`docsearch.env` ne lui est pas fourni** : ce
fichier porte le mot de passe LDAP et les DSN des bases du produit.

Une passe ressemble à ceci :

```python
run_id = f"{datetime.now(timezone.utc).isoformat()}-{uuid4().hex[:4]}"

for ticket in lire_les_tickets():
    envoyer({
        "contract_version": "0.3.0",
        "plugin":  os.environ["DOCSEARCH_PLUGIN"],
        "source":  "tickets",
        "run_id":  run_id,
        "type":    "document",
        "document": {
            "id":      ticket.cle,          # identité STABLE d'une passe à l'autre
            "title":   ticket.titre,
            "content": ticket.description,
            "url":     ticket.url,
            "author":  ticket.auteur,
            "date_modified": ticket.modifie_le,
            "extra":   {"bureau": ticket.bureau},
        },
    })

# Ferme la passe : tout document resté sur une passe antérieure est purgé.
envoyer({"contract_version": "0.3.0", "plugin": ..., "source": "tickets",
         "run_id": run_id, "type": "run_end"})
```

⚠️ **N'envoyez `run_end` que si la passe est allée jusqu'au bout.** C'est
lui qui autorise la suppression. Un module qui échoue en cours de route
doit se taire : le garde-fou du cœur refusera de toute façon d'effacer
plus de la moitié d'un index, mais il vaut mieux ne pas compter dessus.

`id` doit être **stable** : c'est ce qui distingue une mise à jour d'une
création. Un identifiant qui change à chaque passe crée un doublon par
passage, puis les fait tous supprimer par la réconciliation suivante.

## 3. L'archive de livraison

```bash
podman build -t registre.interne/docsearch-plugins/jira:1.2.0 .
podman save -o image.tar registre.interne/docsearch-plugins/jira:1.2.0
tar -cf jira-1.2.0.tar manifeste.json image.tar
```

Le manifeste est un fichier **séparé** de l'image, à dessein : il est
validé avant tout chargement, donc un module refusé ne laisse ni image, ni
unité, ni source enregistrée.

## 4. Installation

```bash
# Les secrets d'abord — l'installation refuse un secret déclaré mais absent
printf '%s' 'le-jeton' | sudo podman secret create jira-token -

sudo ./manage.sh plugin install /chemin/jira-1.2.0.tar
sudo ./manage.sh plugin enable jira
./manage.sh plugin list
sudo ./manage.sh logs docsearch-plugin-jira
```

Mettre à jour un module : réinstaller l'archive de la nouvelle version.
Les sources déjà enregistrées **conservent** leur `searchable`,
`collectable` et `allowed_groups` — une mise à jour ne rallume pas une
source qu'un administrateur avait éteinte.

```bash
sudo ./manage.sh plugin disable jira   # arrêt, sources hors recherche, rien de détruit
sudo ./manage.sh plugin remove jira    # unité + manifeste + sources ; index et image conservés
```

## Ce que l'installation ne protège pas encore

Le conteneur du module est sur `docsearch-net`, où **Elasticsearch et
Redis répondent sans authentification**. Le contrat empêche un module
d'écrire n'importe quoi *par le chemin prévu* ; le réseau ne l'empêche pas
d'en emprunter un autre. Tant que le réseau dédié décrit dans
[PLAN-PLUGINS.md](PLAN-PLUGINS.md) n'est pas en place, **n'installez que
des modules dont vous maîtrisez le code**.
