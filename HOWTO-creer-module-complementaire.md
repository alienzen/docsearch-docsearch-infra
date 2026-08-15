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
- **`capacites`** — `ingestion` (pousser des documents) et `service_web`
  (exposer des routes sous `/ext/<nom>/`, voir plus bas). Un module peut
  demander les deux, ou une seule. Toute autre valeur fait refuser le
  manifeste : une capacité que le cœur ne route pas produirait un module
  qui s'annonce sans que rien ne l'écoute.
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

## 2 bis. Exposer des routes (`service_web`)

Un module peut servir ses propres écrans et ses propres appels. Il déclare
alors la capacité `service_web` et le `port` qu'il écoute **dans son
conteneur** :

```json
{"capacites": ["service_web"], "port": 8080, "sources": []}
```

`./manage.sh plugin install` écrit un fragment nginx dans
`/etc/docsearch/nginx/plugins/<nom>.conf` et recharge le proxy. Le module
devient joignable sous `/ext/<nom>/`.

⚠️ **Le préfixe est retiré avant d'arriver au module** : une requête sur
`/ext/assistant/ask` lui parvient comme `/ask`. Il n'a donc pas à
connaître son point de montage, et le changer ne casse pas son code.

### Vérifier la session

Le cookie de session traverse le proxy. **Le module est responsable de le
vérifier** — aucun en-tête d'identité n'est posé par le proxy, et un
module reste de toute façon joignable directement sur le réseau de la
pile.

```
1. lire le cookie docsearch_access
2. récupérer les clés publiques : GET http://api:8000/auth/.well-known/jwks.json
3. vérifier la signature RS256 avec la clé dont le `kid` correspond
4. vérifier les revendications — voir contract/docsearch_contract/jetons.py
```

Le point 4 est celui qu'on oublie, et le contrat le tient en un appel :
`verifier_revendications(payload)` contrôle `token_type` (un jeton de
**rafraîchissement** présenté comme un jeton d'accès est le contournement
classique), l'émetteur, l'audience, et rend le `sub`.

### Lire des documents

**Jamais Elasticsearch.** Le module rappelle l'API du cœur en portant le
cookie de l'utilisateur : l'ACL s'applique sans qu'il ait à la connaître,
et il ne peut pas s'en écarter.

```python
reponse = httpx.post(
    "http://api:8000/search",
    json={"q": question, "size": 5},
    cookies={"docsearch_access": jeton_de_l_utilisateur},
)
```

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

## Ce que le réseau empêche

Le conteneur d'un module vit sur `docsearch-plugins`, **pas** sur
`docsearch-net`. Elasticsearch, Redis et Tika n'y sont pas rattachés :
leurs noms ne s'y résolvent même pas. Un module ne peut donc pas écrire
directement dans un index, même s'il essaie — l'invariant « un module
n'écrit jamais dans Elasticsearch » est tenu par le réseau et plus
seulement par le contrat.

Ce qu'un module atteint, et rien d'autre :

| Service | Pourquoi |
|---|---|
| `kafka` | pousser des documents (capacité `ingestion`) |
| `api` | vérifier une session, relire des documents à travers l'ACL |
| — | le proxy l'atteint, lui, pour servir `/ext/<nom>/` |

⚠️ Un module installé AVANT cette bascule porte encore
`Network=docsearch-net.network` dans son unité : le réinstaller
(`plugin install` de la même archive) régénère l'unité sur le bon réseau.

## 2 ter. Ajouter une entrée de menu (`interface`)

Un module peut poser une entrée dans le menu de l'interface de recherche :

```json
{
  "capacites": ["service_web"],
  "port": 8080,
  "interface": {
    "nav": [{"libelle": "Assistant", "chemin": "/ext/assistant/", "icone": "fr-icon-chat-3-line"}]
  }
}
```

Le cœur ne rend **jamais** de code venu d'un module : seulement un
libellé (en texte), un chemin et une classe d'icône DSFR. Trois contrôles
à l'installation :

- le chemin doit être sous `/ext/<votre module>/` — un module ne pose pas
  dans le menu de tout le monde un lien vers ailleurs ;
- l'icône doit être une classe `fr-icon-…` connue (le cœur la rend comme
  classe CSS) ;
- le libellé est borné à 40 caractères : une entrée vit dans un en-tête
  partagé, et un libellé démesuré ne tronque pas, il casse la mise en page
  de tous.

L'entrée n'apparaît que si le module est actif (`plugin enable`) et
disparaît avec `plugin disable` — sans quoi elle mènerait à un 502.

⚠️ **Le chemin doit être une route que votre module SERT.** Rappel du §2
bis : le préfixe est retiré avant d'arriver au module, donc
`/ext/assistant/` lui parvient comme `/`. Un module qui n'expose que
`/ask` et déclare une entrée vers `/ext/assistant/` produit un lien de
menu qui rend `{"detail":"Not Found"}` — l'erreur est côté module, pas
côté proxy, et c'est le corps JSON qui le trahit. Rien ne peut le
détecter à l'installation : le cœur ne connaît pas les routes de votre
module. **Cliquez sur votre entrée après `plugin enable`.**

Un module qui n'a pas d'écran à lui — parce que son interface est une
page du cœur, comme l'assistant de recherche — ne déclare simplement pas
d'entrée. Un service dorsal n'a rien à faire dans le menu.

⚠️ Trois autres accroches sont prévues (`result_action`, `admin_panel`,
`page`) et **ne sont pas encore servies** : les déclarer fait refuser le
manifeste.
