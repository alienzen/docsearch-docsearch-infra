# Supervision Zabbix de DocSearch

Sondes pour les **8 serveurs de production** et pour **l'application**, au sens
de ce qu'un utilisateur constate : la recherche répond-elle, les documents
arrivent-ils dans l'index, la connexion fonctionne-t-elle.

Cible : **Zabbix 7.0 LTS**, **agent 2**, Debian 13. Compte applicatif de sonde :
compte **local** DocSearch dédié (voir §5).

## Par où commencer

| Document | Pour quoi faire |
|---|---|
| [guide_supervision_zabbix.md](../../docsearch-docs/guide_supervision_zabbix.md) | **Installer**, pas à pas, du pare-feu à la vérification finale |
| **Ce fichier** | Comprendre le découpage, les choix et leurs limites |
| [REFERENCE.md](REFERENCE.md) | Chercher un élément ou un déclencheur précis (catalogue généré) |

Le condensé opérationnel ci-dessous suffit pour une réinstallation ; pour une
première mise en service, suivre le guide.

---

## 1. Ce qui est surveillé, et par quel chemin

| Chemin de collecte | Ce qu'il couvre | Agent requis |
|---|---|---|
| `Linux by Zabbix agent` (modèle fourni avec Zabbix) | CPU, mémoire, disques, réseau, redémarrage, processus | oui |
| `DocSearch socle` | unités systemd Quadlet, santé podman, horloge, `vm.max_map_count` | oui |
| `DocSearch noeud Elasticsearch` | JVM, disque, rôles, verrouillage mémoire — **par nœud** | non (HTTP 9200) |
| `DocSearch arbitre et Kibana` | Kibana | non (HTTP 5601) |
| `DocSearch Kafka` | topic, partitions, membres du groupe, retard d'indexation | oui |
| `DocSearch frontend` | chaîne HTTPS, API, recherche réelle, Redis, certificat, `/admin/status` | oui |
| `DocSearch ingestion` | 2 Tika par machine, partage réseau des sources | oui (montage) |
| `DocSearch application` | état du **cluster** ES, agrégats inter-machines | non |

**114 éléments, 7 prototypes, 62 déclencheurs.** Tout est dans un seul fichier
d'import : `templates/docsearch-zabbix-7.0.yaml`.

### Le découpage n'est pas cosmétique

- **Ce qui est propre au nœud** (tas JVM, disque, `mlockall`) est relevé sur
  chaque nœud. **Ce qui est propre au cluster** (état vert/jaune/rouge, master,
  shards non assignés) est relevé **une seule fois**, par le modèle
  `DocSearch application`. Le relever sur les 3 machines ferait sonner trois
  fois pour une même panne.
- **Trois choses ne sont visibles d'aucune machine prise isolément**, et
  n'existent que dans les agrégats : un **watcher démarré deux fois** (chaque
  document indexé en double), les **6 Tika tombés ensemble**, les **9 workers
  réduits à 3**.
- **Le retard d'indexation est mesuré deux fois**, et c'est voulu : par l'API
  (`/admin/status`) et directement sur le broker. Le premier chemin exige que
  l'API, Elasticsearch et une session valide fonctionnent — c'est-à-dire qu'il
  s'éteint exactement quand on en a besoin. Le second tient tout seul.

---

## 2. Prérequis

### 2.1 Ouvrir le pare-feu — le point qui bloque toujours en premier

Le jeu de règles nftables du guide d'installation (§5.5) est en `policy drop`
et n'autorise qu'une liste de ports fixe, **où Zabbix ne figure pas**. Sur
les 8 machines :

```bash
sudo nft add rule inet filter input ip saddr <IP_SERVEUR_ZABBIX> tcp dport 10050 accept
```

Et reporter la règle dans `/etc/nftables.conf`, sinon elle disparaît au
redémarrage. Si le serveur Zabbix n'est pas sur `192.168.10.0/24`, c'est aussi
une exception à ajouter au réseau du cluster.

Les vérifications sans agent partent du serveur Zabbix vers **9200** (les
3 machines ES), **5601** (es-voting), **9998/9999** (les 3 machines
d'ingestion), **443/80/8000/6379/9092** — tous déjà ouverts par le guide pour
`192.168.10.0/24`, à élargir à l'adresse du serveur Zabbix.

### 2.2 Installer l'agent — production hors ligne

La production n'a **aucun accès Internet**. `zabbix-agent2` et ses dépendances
doivent venir du **miroir interne**, jamais de `repo.zabbix.com` : télécharger
les `.deb` sur la machine de préparation, les transférer avec les images
(voir `HOWTO-deploiement-hors-ligne.md`), puis `dpkg -i`.

Aucune des sondes de ce dépôt n'appelle quoi que ce soit à l'extérieur :
`curl`, `openssl`, `awk`, `systemctl` et `podman` sont déjà là. Rien à
vendoriser.

Dans `/etc/zabbix/zabbix_agent2.conf` :

```
Server=<IP_SERVEUR_ZABBIX>
ServerActive=<IP_SERVEUR_ZABBIX>
Hostname=<nom de la machine, identique au nom d'hôte dans Zabbix>
Include=/etc/zabbix/zabbix_agent2.d/*.conf
Timeout=30
```

`Timeout=30` est **obligatoire sur la machine kafka** : `kafka-consumer-groups`
interroge le coordinateur et met couramment 5 à 10 secondes. Avec le défaut
(3 s), la sonde de la file d'indexation ne remonte jamais rien.

### 2.3 Déployer les sondes

Sur chaque machine, avec le même nom de rôle que `quadlet/install-units.sh` :

```bash
cd ~/docsearch/docsearch-infra/zabbix && sudo ./deployer-sondes.sh <rôle>
```

Rôles : `es-data`, `es-voting`, `kafka`, `frontend`, `ingest`. Le script
installe les scripts en `0755 root:root`, la configuration de l'agent, et la
règle sudo — vérifiée par `visudo -c` avant d'être posée. `--dry-run` montre ce
qui serait fait.

**Pourquoi une règle sudo.** Les unités Quadlet de production sont installées
dans `/etc/containers/systemd` : elles sont pilotées par le podman **rootful**,
et les conteneurs n'existent tout simplement pas pour l'utilisateur `zabbix`.
Trois sondes ont besoin d'y accéder (santé des conteneurs, Redis, Kafka). La
règle autorise **trois chemins précis, sans argument variable** — pas
`podman *`, qui donnerait `podman run --privileged -v /:/hôte`, c'est-à-dire
root complet.

---

## 3. Importer les modèles

*Data collection → Templates → Import*, fichier
`templates/docsearch-zabbix-7.0.yaml`, cocher « Create new » pour les modèles
et les groupes de modèles.

Puis créer les **groupes d'hôtes** — les agrégats du modèle
`DocSearch application` les désignent par leur nom, à l'orthographe près :

| Groupe | Hôtes |
|---|---|
| `DocSearch` | les 8 machines |
| `DocSearch/es` | es-data-1, es-data-2, es-voting |
| `DocSearch/kafka` | kafka |
| `DocSearch/frontend` | frontend |
| `DocSearch/ingestion` | ingest-1, ingest-2, ingest-3 |
| `DocSearch/application` | l'hôte logique (§4) |

Chaque machine appartient à `DocSearch` **et** à son groupe de rôle.

---

## 4. Hôtes et modèles à lier

| Hôte | Groupes | Modèles |
|---|---|---|
| es-data-1 | `DocSearch`, `DocSearch/es` | Linux by Zabbix agent · DocSearch socle · DocSearch noeud Elasticsearch |
| es-data-2 | `DocSearch`, `DocSearch/es` | idem |
| es-voting | `DocSearch`, `DocSearch/es` | Linux by Zabbix agent · DocSearch socle · DocSearch noeud Elasticsearch · DocSearch arbitre et Kibana |
| kafka | `DocSearch`, `DocSearch/kafka` | Linux by Zabbix agent · DocSearch socle · DocSearch Kafka |
| frontend | `DocSearch`, `DocSearch/frontend` | Linux by Zabbix agent · DocSearch socle · DocSearch frontend |
| ingest-1 | `DocSearch`, `DocSearch/ingestion` | Linux by Zabbix agent · DocSearch socle · DocSearch ingestion |
| ingest-2 | `DocSearch`, `DocSearch/ingestion` | idem |
| ingest-3 | `DocSearch`, `DocSearch/ingestion` | idem |
| **DocSearch — application** | `DocSearch/application` | DocSearch application |

L'hôte `DocSearch — application` est un **hôte logique, sans interface et sans
agent** : il ne porte que des éléments HTTP et calculés. C'est là que vivent
l'état du cluster Elasticsearch et les agrégats.

### Macros à poser par hôte

| Hôte | Macro | Valeur |
|---|---|---|
| **es-voting** | `{$DOCSEARCH.ES.ROLE.ATTENDU}` | `voting_only` |
| DocSearch — application | `{$DOCSEARCH.ES.URL}` | `http://<ES_DATA1_IP>:9200` |
| frontend, ingest-* | `{$DOCSEARCH.SOURCES.CHEMIN}` | le point de montage réel, si différent de `/data/docsearch-sources` |

**La première n'est pas optionnelle** : sans elle, es-voting déclenchera en
permanence « ce nœud n'a pas le rôle attendu ». C'est le même déclencheur qui
attrape un `elasticsearch.env` recopié d'une machine à l'autre sans adaptation
— le piège du §6.1 du guide d'installation.

---

## 5. Le compte de supervision

Les sondes applicatives (`/admin/status`, `/metrics`, recherche de bout en
bout) exigent une session. L'API vérifie elle-même un jeton RS256 qu'elle a
signé : aucun en-tête d'identité n'est cru sur parole, `TRUST_X_USER_HEADER`
est verrouillé par les garde-fous en `API_ENV=production`. Il faut donc un
vrai compte.

**Un compte LOCAL, pas un compte d'annuaire.** Un compte local reste opérant
quand l'annuaire est en panne — c'est-à-dire exactement quand la supervision
doit encore parler. Sur frontend :

```bash
sudo podman exec -it docsearch-api python scripts/gerer-comptes-locaux.py creer svc-supervision --groupes docsearch-users,docsearch-admins --nom "Supervision Zabbix"
```

Les deux groupes sont nécessaires : `docsearch-users` pour ouvrir une session
(contrôlé à la connexion), `docsearch-admins` pour `/admin/status`.

Reporter ensuite l'identifiant et le mot de passe dans
`/etc/zabbix/docsearch-supervision.conf` (`0640 root:zabbix`, créé depuis le
modèle par `deployer-sondes.sh frontend`), avec la requête témoin de la sonde
de recherche.

### Ce que ce compte coûte

- **Le mot de passe est sur le disque de frontend**, lisible par `zabbix`. Il
  n'est ni dans le dépôt, ni dans un `Containerfile`, ni en argument de ligne
  de commande — donc absent de l'historique du shell et de la liste des
  processus. Alternative si la politique l'exige : macro secrète Zabbix ou
  HashiCorp Vault, à passer par une variable d'environnement de l'agent.
- **~96 lignes par jour dans `login_events`.** Le jeton d'accès vit 15 min ; le
  pot à biscuits est réutilisé et rafraîchi, une session n'est pas rouverte à
  chaque relevé. Les lignes portent l'agent utilisateur `Zabbix-DocSearch`,
  filtrables dans le journal d'audit.
- **La requête témoin subit le filtrage ACL** de `svc-supervision`. Choisir un
  terme qui ramène des résultats **avec ce compte-là**, sinon le déclencheur
  « la requête témoin ne ramène plus aucun résultat » sonnera en permanence.

---

## 6. Vérifier

Sur la machine, sous l'identité de l'agent :

```bash
sudo runuser -u zabbix -- /usr/local/bin/docsearch-zabbix-unites
```

```bash
sudo runuser -u zabbix -- /usr/local/bin/docsearch-zabbix-api etat
```

Depuis le serveur Zabbix :

```bash
zabbix_get -s <ip_machine> -k docsearch.unites
```

Une sonde qui rend du JSON valide est bonne. Une sonde qui rend
`ZBX_NOTSUPPORTED` affiche sa propre cause en clair.

---

## 7. Option : statistiques Nginx

Non activé par défaut : cela demande de modifier la configuration du proxy de
production et de redémarrer le conteneur. Pour l'avoir, ajouter dans le bloc
`server` HTTPS de `nginx/nginx.conf` :

```nginx
location = /etat-nginx { stub_status; access_log off; allow 172.20.0.0/16; deny all; }
```

La restriction porte sur `172.20.0.0/16` et non sur `127.0.0.1` : les ports
sont publiés par podman, et Nginx voit l'adresse de la passerelle du réseau de
conteneurs, jamais celle de l'appelant. C'est la même restriction que la
`location /kibana/` existante. Puis créer les éléments correspondants à la main
— ils ne figurent pas dans le modèle, pour qu'un import ne dépende jamais d'une
modification de la configuration de production.

---

## 8. Ce qui n'est délibérément pas surveillé

- **JMX Kafka.** Le broker n'expose pas de port JMX et l'activer suppose de
  modifier `kafka.env` et de déployer `zabbix-java-gateway`. Ce qui compte
  fonctionnellement — topic, partitions, membres, retard — est obtenu par
  `kafka-consumer-groups`, sans rien changer à la production.
- **Consommation par conteneur via `podman stats`.** Coûteux, et le nom des
  colonnes de `--format` varie selon la version de podman. La mémoire par
  service est lue dans le cgroup de l'unité systemd (`MemoryCurrent`), ce qui
  donne la même information sans dépendre de podman.
- **Contenu des journaux applicatifs.** Un `log[]` sur `journalctl` serait
  utile mais demande de choisir les motifs avec l'exploitation ; hors périmètre
  de ce premier jeu de sondes.
- **La chaîne d'alerte** (actions, escalades, destinataires). À définir dans
  Zabbix selon les usages de l'équipe. Les priorités sont posées pour s'y
  brancher directement : `DISASTER` = les utilisateurs ne peuvent plus
  travailler, `HIGH` = une fonction est perdue, `AVERAGE`/`WARNING` = à traiter
  en heures ouvrées.

## 9. Limites connues

- L'agrégat `docsearch.agr.watchers` passe en « données absentes » — et non à
  zéro — si l'unité `docsearch-watcher.service` disparaît de **toutes** les
  machines d'ingestion : `last_foreach` ne trouve alors plus aucun élément à
  agréger. Le déclencheur « aucun watcher actif » ne se déclenchera pas dans ce
  cas précis ; l'unité manquante, elle, sera signalée par le modèle socle.
- Les seuils numériques (retard d'indexation, tas JVM, mémoire Redis) sont des
  points de départ raisonnables, pas des valeurs mesurées sur ce corpus. À
  réviser après le test de montée en charge à 4 millions de documents.
- La sonde de recherche est limitée par `limit_req zone=search rate=30r/m` dans
  Nginx : ne pas descendre son intervalle sous la minute, sous peine de 429.
