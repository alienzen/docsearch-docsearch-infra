# Sondes DocSearch — catalogue

*Généré par `generer-reference.py` à partir de `templates/docsearch-zabbix-7.0.yaml`. Ne pas modifier à la main.*

**7 modèles · 114 éléments (+ 7 prototypes de découverte) · 62 déclencheurs.**

Le pourquoi de ce découpage est dans [README.md](README.md) ; la procédure d'installation est dans [docsearch-docs/guide_supervision_zabbix.md](../../docsearch-docs/guide_supervision_zabbix.md).

## Sommaire

- [DocSearch socle](#docsearch-socle)
- [DocSearch noeud Elasticsearch](#docsearch-noeud-elasticsearch)
- [DocSearch arbitre et Kibana](#docsearch-arbitre-et-kibana)
- [DocSearch Kafka](#docsearch-kafka)
- [DocSearch frontend](#docsearch-frontend)
- [DocSearch ingestion](#docsearch-ingestion)
- [DocSearch application](#docsearch-application)

## Modèles

### DocSearch socle

Sondes communes aux 8 machines DocSearch : unités systemd (Quadlet),
conteneurs podman, horloge, vm.max_map_count.

Prérequis sur la machine : deployer-sondes.sh <rôle>.

**Macros**

| Macro | Défaut | Rôle |
|---|---|---|
| `{$DOCSEARCH.UNITE.ATTENDUE}` | `1` | 1 = l'unité doit tourner, 0 = arrêt normal. Se surcharge par unité avec un contexte : {$DOCSEARCH.UNITE.ATTENDUE:"docsearch-xxx.service"}. |
| `{$DOCSEARCH.UNITE.ATTENDUE:"docsearch-alert-worker.service"}` | `0` | Sans [Install] dans son unité Quadlet : démarré sciemment ou pas du tout. |
| `{$DOCSEARCH.UNITE.ATTENDUE:"docsearch-sql-worker.service"}` | `0` | À activer seulement si des sources SQL sont enregistrées. |
| `{$DOCSEARCH.UNITE.ATTENDUE:"docsearch-web-worker.service"}` | `0` | À activer seulement si des sources web sont enregistrées. |
| `{$DOCSEARCH.UNITE.REDEMARRAGES.MAX}` | `3` | Redémarrages tolérés sur 10 min avant de parler de boucle. |
| `{$DOCSEARCH.NTP.DECALAGE.MAX}` | `1` | Décalage d'horloge toléré, en secondes. |
| `{$DOCSEARCH.MAX_MAP_COUNT.MIN}` | `262144` |  |

**Éléments**

| Clé | Nom | Collecte | Intervalle |
|---|---|---|---|
| `docsearch.conteneur.sante[{#CONTENEUR}]` | {#CONTENEUR} : santé podman | dépendant (découverte) | — |
| `docsearch.conteneur.tourne[{#CONTENEUR}]` | {#CONTENEUR} : en fonctionnement | dépendant (découverte) | — |
| `docsearch.conteneurs` | Conteneurs podman : collecte | agent | 1m |
| `docsearch.conteneurs.malsains` | Conteneurs déclarés malades | dépendant | — |
| `docsearch.horloge` | Horloge : collecte | agent | 5m |
| `docsearch.horloge.decalage` | Décalage d'horloge | dépendant | — |
| `docsearch.horloge.strate` | Strate NTP | dépendant | — |
| `docsearch.horloge.synchronise` | Horloge synchronisée | dépendant | — |
| `docsearch.max_map_count` | vm.max_map_count | agent | 1h |
| `docsearch.podman.version` | Version de podman | agent | 1h |
| `docsearch.unite.actif[{#UNITE}]` | {#COURT} : état | dépendant (découverte) | — |
| `docsearch.unite.echoue[{#UNITE}]` | {#COURT} : en échec | dépendant (découverte) | — |
| `docsearch.unite.memoire[{#UNITE}]` | {#COURT} : mémoire du cgroup | dépendant (découverte) | — |
| `docsearch.unite.redemarrages[{#UNITE}]` | {#COURT} : redémarrages | dépendant (découverte) | — |
| `docsearch.unites` | Unités systemd DocSearch : collecte | agent | 1m |
| `docsearch.unites.echouees` | Unités systemd en échec | dépendant | — |
| `docsearch.unites.workers` | Workers d'indexation actifs sur cette machine | dépendant | — |

**Déclencheurs**

| Priorité | Nom | Ce qu'il signifie |
|---|---|---|
| Haute | DocSearch : l'unité {#UNITE} est en échec *(prototype)* | journalctl -u {#UNITE} -n 100 |
| Haute | DocSearch : podman déclare {#CONTENEUR} en mauvaise santé *(prototype)* | Le HealthCmd de l'unité échoue depuis 3 minutes. systemd, lui, voit toujours l'unité "active" : podman ne redémarre pas un conteneur unhealthy. Diagnostic : podman healthcheck run {#CONTENEUR} |
| Moyenne | DocSearch : horloge non synchronisée | chrony n'a plus de source de temps valide. Les dates d'indexation (date_created, date_modified) et la corrélation des journaux entre les 8 machines deviennent fausses, sans autre symptôme visible. |
| Moyenne | DocSearch : l'unité {#UNITE} est arrêtée *(prototype)* | Les unités volontairement à l'arrêt (alert-worker, sql-worker, web-worker) sont exclues par la macro à contexte {$DOCSEARCH.UNITE.ATTENDUE:"<unité>"} = 0. |
| Moyenne | DocSearch : l'unité {#UNITE} redémarre en boucle *(prototype)* | Restart=always masque la panne : l'unité paraît active entre deux chutes. Cause fréquente sur un worker : dépassement de --memory=1g. |
| Moyenne | DocSearch : vm.max_map_count est retombé sous {$DOCSEARCH.MAX_MAP_COUNT.MIN} | Vérifier que la ligne existe bien dans /etc/sysctl.d/99-docsearch.conf, et pas seulement appliquée à chaud (§9.3 du guide d'installation). |
| Avertissement | DocSearch : décalage d'horloge supérieur à {$DOCSEARCH.NTP.DECALAGE.MAX} s |  |
| Information | DocSearch : la version de podman a changé |  |

### DocSearch noeud Elasticsearch

Sondes par nœud Elasticsearch. Interrogation HTTP directe sur 9200
(xpack.security.enabled=false) : aucun agent requis pour ces éléments.

**Macros**

| Macro | Défaut | Rôle |
|---|---|---|
| `{$DOCSEARCH.ES.URL}` | `http://{HOST.CONN}:9200` |  |
| `{$DOCSEARCH.ES.HEAP.CRIT}` | `90` |  |
| `{$DOCSEARCH.ES.HEAP.AVERT}` | `75` |  |
| `{$DOCSEARCH.ES.DISQUE.MIN}` | `15` | Pourcentage d'espace libre en dessous duquel alerter. ES bloque les écritures à 5 %. |
| `{$DOCSEARCH.ES.ROLE.ATTENDU}` | `data` | Poser "voting_only" sur l'hôte es-voting. |

**Éléments**

| Clé | Nom | Collecte | Intervalle |
|---|---|---|---|
| `es.noeud.descripteurs` | ES nœud : descripteurs de fichiers ouverts | dépendant | — |
| `es.noeud.disjoncteur` | ES nœud : disjoncteur parent déclenché | dépendant | — |
| `es.noeud.disque.libre` | ES nœud : espace disque libre | dépendant | — |
| `es.noeud.disque.pct` | ES nœud : espace disque libre en pourcentage | dépendant | — |
| `es.noeud.documents` | ES nœud : documents stockés | dépendant | — |
| `es.noeud.ecritures.rejetees` | ES nœud : écritures rejetées | dépendant | — |
| `es.noeud.gc.old` | ES nœud : temps passé en GC old | dépendant | — |
| `es.noeud.heap.pct` | ES nœud : occupation du tas JVM | dépendant | — |
| `es.noeud.indexation.debit` | ES nœud : débit d'indexation | dépendant | — |
| `es.noeud.info` | ES nœud : identité | HTTP | 10m |
| `es.noeud.memlock` | ES nœud : tas verrouillé en mémoire | dépendant | — |
| `es.noeud.nom` | ES nœud : nom | dépendant | — |
| `es.noeud.recherche.debit` | ES nœud : débit de recherche | dépendant | — |
| `es.noeud.recherches.rejetees` | ES nœud : recherches rejetées | dépendant | — |
| `es.noeud.roles` | ES nœud : rôles | dépendant | — |
| `es.noeud.segments` | ES nœud : segments | dépendant | — |
| `es.noeud.stats` | ES nœud : statistiques | HTTP | 1m |
| `es.noeud.version` | ES nœud : version | dépendant | — |
| `system.swap.size[all,total]` | ES nœud : swap total | agent | 10m |

**Déclencheurs**

| Priorité | Nom | Ce qu'il signifie |
|---|---|---|
| Haute | ES : ce nœud n'a pas le rôle attendu ({$DOCSEARCH.ES.ROLE.ATTENDU}) | node.roles ne correspond pas à ce qu'attend l'architecture. Cause la plus fréquente : elasticsearch.env recopié d'une machine à l'autre sans adaptation. Poser {$DOCSEARCH.ES.ROLE.ATTENDU}=voting_only sur l'hôte es-voting. |
| Haute | ES : le tas JVM n'est PAS verrouillé en mémoire | bootstrap.memory_lock=true est demandé dans elasticsearch.env mais n'a pas pris : il manque --ulimit=memlock=-1:-1 sur le conteneur, ou la limite système l'interdit. Panne silencieuse : le nœud démarre et fonctionne, mais son tas peut partir en swap, avec des pauses GC de plusieurs secondes pour seul symptôme. |
| Haute | ES : moins de {$DOCSEARCH.ES.DISQUE.MIN} % d'espace disque libre | À 85 % d'occupation Elasticsearch cesse d'allouer de nouveaux shards sur ce nœud, à 90 % il en déplace, à 95 % il passe TOUS les index en lecture seule — l'indexation s'arrête alors sans que rien d'autre ne le signale (voir la sonde "index passés en lecture seule"). |
| Haute | ES : tas JVM au-dessus de {$DOCSEARCH.ES.HEAP.CRIT} % depuis 10 min | Au-delà de 90 %, le ramasse-miettes tourne en continu et le nœud devient très lent avant de se faire éjecter du cluster. Le tas est fixé dans /etc/docsearch/elasticsearch.env (7 Go pour 16 Go de RAM). |
| Moyenne | ES : le disjoncteur mémoire s'est déclenché | Des requêtes ont été refusées pour protéger le tas. Recherche ou agrégation trop lourde. |
| Moyenne | ES : le nœud rejette des écritures | La file d'écriture est pleine : les workers d'ingestion voient leurs lots refusés. Réduire WORKER_BATCH_SIZE ou le nombre de workers. |
| Moyenne | ES : le swap est actif sur un nœud Elasticsearch | Le guide impose swapoff -a et le retrait de la ligne swap de /etc/fstab sur es-data-1, es-data-2 et es-voting. Un swap réactivé après réinstallation ou mise à jour du noyau se voit ici. |
| Moyenne | ES : plus de 10 % du temps passé en ramasse-miettes | Signe avant-coureur classique d'un tas sous-dimensionné ou d'une requête trop lourde. |
| Avertissement | ES : le nom du nœud a changé | node.name vient de /etc/docsearch/elasticsearch.env, et doit être UNIQUE dans le cluster : deux nœuds du même nom refusent de se joindre. Un changement ici veut dire que ce fichier a bougé. |
| Avertissement | ES : tas JVM au-dessus de {$DOCSEARCH.ES.HEAP.AVERT} % depuis 30 min |  |

### DocSearch arbitre et Kibana

Sondes propres à la machine es-voting : Kibana. Le nœud Elasticsearch
lui-même est couvert par "DocSearch noeud Elasticsearch", à lier aussi
sur cet hôte (avec {$DOCSEARCH.ES.ROLE.ATTENDU}=voting_only).

**Macros**

| Macro | Défaut | Rôle |
|---|---|---|
| `{$DOCSEARCH.KIBANA.URL}` | `http://{HOST.CONN}:5601` |  |

**Éléments**

| Clé | Nom | Collecte | Intervalle |
|---|---|---|---|
| `kibana.niveau` | Kibana : niveau global | dépendant | — |
| `kibana.statut` | Kibana : état | HTTP | 2m |
| `kibana.version` | Kibana : version | dépendant | — |
| `net.tcp.service[tcp,,5601]` | Kibana : port 5601 | contrôle simple | 2m |

**Déclencheurs**

| Priorité | Nom | Ce qu'il signifie |
|---|---|---|
| Avertissement | Kibana : indisponible | Kibana ne sert qu'à l'exploitation : ni la recherche ni l'indexation n'en dépendent. D'où WARNING et non HIGH. |
| Information | Kibana : dégradé |  |

### DocSearch Kafka

File de travail de l'indexation. Broker unique en KRaft : sa perte
arrête l'INDEXATION, jamais la RECHERCHE — les messages de la priorité
des déclencheurs le disent explicitement.

**Macros**

| Macro | Défaut | Rôle |
|---|---|---|
| `{$DOCSEARCH.KAFKA.RETARD.MAX}` | `50000` | Documents en attente d'indexation au-delà desquels alerter. |

**Éléments**

| Clé | Nom | Collecte | Intervalle |
|---|---|---|---|
| `docsearch.kafka.assignees` | Kafka : partitions assignées | dépendant | — |
| `docsearch.kafka.broker` | Kafka : broker joignable | dépendant | — |
| `docsearch.kafka.file` | Kafka : file d'indexation | agent | 2m |
| `docsearch.kafka.membres` | Kafka : workers dans le groupe de consumers | dépendant | — |
| `docsearch.kafka.partitions` | Kafka : partitions du topic | dépendant | — |
| `docsearch.kafka.retard` | Kafka : documents en attente d'indexation | dépendant | — |
| `docsearch.kafka.retard.max` | Kafka : retard de la partition la plus en retard | dépendant | — |
| `docsearch.kafka.topic` | Kafka : topic présent | dépendant | — |
| `net.tcp.service[tcp,,9092]` | Kafka : port 9092 | contrôle simple | 1m |

**Déclencheurs**

| Priorité | Nom | Ce qu'il signifie |
|---|---|---|
| Haute | Kafka : aucun worker ne consomme la file | Le broker va bien mais plus aucun worker des 3 machines d'ingestion n'est membre du groupe. Rien n'est indexé, et rien d'autre ne le dit. |
| Haute | Kafka : broker injoignable — l'indexation est arrêtée | Point de défaillance unique assumé de l'architecture (§2.2 du guide). L'INDEXATION de nouveaux documents s'arrête ; la RECHERCHE continue de fonctionner normalement, elle ne dépend ni de Kafka ni des machines d'ingestion. Les documents non publiés seront rattrapés au prochain scan complet. |
| Haute | Kafka : le topic documents-to-index n'existe pas | Le broker répond mais le topic a disparu : volume de données perdu, ou broker réinitialisé. |
| Avertissement | Kafka : plus de workers que de partitions | Le parallélisme est plafonné par le nombre de partitions (KAFKA_NUM_PARTITIONS, 16 par défaut) : les workers en trop ne reçoivent jamais de partition et restent inactifs (§9.2 du guide). |
| Avertissement | Kafka : retard d'indexation supérieur à {$DOCSEARCH.KAFKA.RETARD.MAX} documents depuis 30 min | Normal pendant un scan complet (manage.sh init) : la file se remplit d'un coup puis se vide. Anormal en régime établi — vérifier que les workers consomment (docsearch.kafka.membres) et que Tika répond. |

### DocSearch frontend

Sondes de la machine frontend : chaîne HTTPS complète, API de recherche,
Redis, certificat TLS, et l'état agrégé de toute l'application via
/admin/status.

Prérequis : deployer-sondes.sh frontend, puis renseigner
/etc/zabbix/docsearch-supervision.conf (compte local de supervision).

**Macros**

| Macro | Défaut | Rôle |
|---|---|---|
| `{$DOCSEARCH.SOURCES.CHEMIN}` | `/data/docsearch-sources` |  |
| `{$DOCSEARCH.RECHERCHE.MS.MAX}` | `2000` |  |
| `{$DOCSEARCH.CERT.JOURS.AVERT}` | `30` |  |
| `{$DOCSEARCH.CERT.JOURS.CRIT}` | `7` |  |
| `{$DOCSEARCH.REDIS.MEMOIRE.MAX}` | `85` |  |
| `{$DOCSEARCH.WATCHER.SILENCE.MAX}` | `180` | Le watcher bat toutes les WATCHER_POLL_INTERVAL secondes, TTL 120 s. |
| `{$DOCSEARCH.INDEXATION.RETARD.MAX}` | `50000` |  |

**Éléments**

| Clé | Nom | Collecte | Intervalle |
|---|---|---|---|
| `docsearch.api.certificat` | TLS : certificat de Nginx | agent | 6h |
| `docsearch.api.certificat.date` | TLS : date d'expiration | dépendant | — |
| `docsearch.api.certificat.jours` | TLS : jours avant expiration du certificat | dépendant | — |
| `docsearch.api.es_version` | API : version d'Elasticsearch vue par l'API | dépendant | — |
| `docsearch.api.etat` | Application : /admin/status | agent | 1m |
| `docsearch.api.jwks` | Authentification : trousseau de signature | agent | 5m |
| `docsearch.api.jwks.http` | Authentification : code HTTP de /auth/.well-known/jwks.json | dépendant | — |
| `docsearch.api.metriques` | Application : /metrics | agent | 10m |
| `docsearch.api.recherche` | Recherche : sonde de bout en bout | agent | 1m |
| `docsearch.api.recherche.http` | Recherche : code HTTP | dépendant | — |
| `docsearch.api.recherche.resultats` | Recherche : résultats de la requête témoin | dépendant | — |
| `docsearch.api.recherche.temps` | Recherche : temps de réponse | dépendant | — |
| `docsearch.api.sante` | API : /health (port 8000 en direct) | agent | 1m |
| `docsearch.api.sante.http` | API : code HTTP de /health | dépendant | — |
| `docsearch.api.sante.temps` | API : temps de réponse de /health | dépendant | — |
| `docsearch.api.version` | API : version déployée | dépendant | — |
| `docsearch.api.web` | Interface : redirection de la racine | agent | 1m |
| `docsearch.api.web.http` | Interface : code HTTP de la racine | dépendant | — |
| `docsearch.api.web.temps` | Interface : temps de réponse de la racine | dépendant | — |
| `docsearch.etat.attente` | Application : documents en attente d'indexation | dépendant | — |
| `docsearch.etat.es` | Application : Elasticsearch joignable depuis l'API | dépendant | — |
| `docsearch.etat.http` | Application : code HTTP de /admin/status | dépendant | — |
| `docsearch.etat.redis` | Application : Redis joignable depuis l'API | dépendant | — |
| `docsearch.etat.tika.actives` | Application : instances Tika répondant | dépendant | — |
| `docsearch.etat.tika.total` | Application : instances Tika déclarées | dépendant | — |
| `docsearch.etat.version.ingestion` | Application : version de l'ingestion | dépendant | — |
| `docsearch.etat.watcher.silence` | Application : silence du watcher | dépendant | — |
| `docsearch.etat.workers` | Application : workers actifs (vu de Kafka) | dépendant | — |
| `docsearch.metriques.documents` | Application : documents indexés | dépendant | — |
| `docsearch.metriques.taille` | Application : volume indexé | dépendant | — |
| `docsearch.montage.lisible` | Sources : partage lisible | dépendant | — |
| `docsearch.montage.monte` | Sources : partage monté | dépendant | — |
| `docsearch.montage[{$DOCSEARCH.SOURCES.CHEMIN}]` | Sources : montage {$DOCSEARCH.SOURCES.CHEMIN} | agent | 5m |
| `docsearch.redis` | Redis : collecte | agent | 1m |
| `docsearch.redis.battement.sql` | Redis : silence du worker SQL | dépendant | — |
| `docsearch.redis.battement.web` | Redis : silence du worker web | dépendant | — |
| `docsearch.redis.clients` | Redis : clients connectés | dépendant | — |
| `docsearch.redis.evictions` | Redis : clés évincées | dépendant | — |
| `docsearch.redis.joignable` | Redis : joignable | dépendant | — |
| `docsearch.redis.memoire` | Redis : mémoire utilisée | dépendant | — |
| `docsearch.redis.memoire.pct` | Redis : occupation mémoire | dépendant | — |
| `docsearch.redis.rdb` | Redis : dernière sauvegarde RDB réussie | dépendant | — |
| `docsearch.redis.registre.sources` | Redis : registre des sources fichier présent | dépendant | — |
| `docsearch.source.documents[{#SOURCE}]` | Source {#LIBELLE} : documents indexés | dépendant (découverte) | — |
| `net.tcp.service[tcp,,443]` | Nginx : port 443 | contrôle simple | 1m |
| `net.tcp.service[tcp,,6379]` | Redis : port 6379 | contrôle simple | 1m |
| `net.tcp.service[tcp,,8000]` | API : port 8000 | contrôle simple | 1m |
| `net.tcp.service[tcp,,80]` | Nginx : port 80 | contrôle simple | 5m |

**Déclencheurs**

| Priorité | Nom | Ce qu'il signifie |
|---|---|---|
| Désastre | DocSearch : l'API ne répond plus | /health répond 503 dès qu'Elasticsearch est injoignable DEPUIS l'API. Attention : ES_HOST ne liste qu'un seul hôte (es-data-1). Si ce nœud tombe, l'API perd son point d'entrée MÊME SI le cluster reste vert sur les autres nœuds (§2.3 du guide). 0 = l'API n'écoute plus du tout sur 8000. |
| Désastre | DocSearch : la recherche ne fonctionne plus | Codes à distinguer : 401/403 le compte de supervision a perdu ses droits ou son mot de passe a changé ; 503 annuaire, Redis ou clés de signature indisponibles ; 429 limite de débit atteinte (l''intervalle de la sonde est passé sous 2 s) ; 0 rien ne répond. |
| Désastre | DocSearch : le registre des sources a disparu de Redis | docsearch:config:file_sources n'existe plus alors que Redis répond. Plus aucune source n'est déclarée : ni indexation, ni facette de source, ni aperçu. Causes : éviction LRU, FLUSHDB, ou volume redis-data reparti à vide. |
| Désastre | Nginx : la chaîne HTTPS ne répond plus | Ni TLS ni proxy : Nginx est tombé, ou le certificat est illisible. |
| Haute | DocSearch : la requête témoin ne ramène plus aucun résultat | L'API répond 200 mais l'index ne rend plus rien. Alias fédéré cassé, index purgé, ou filtrage ACL qui exclut désormais tout pour le compte de supervision. Choisir dans docsearch-supervision.conf une requête témoin dont on sait qu'elle ramène toujours des résultats. |
| Haute | DocSearch : les clés de signature ne sont pas lisibles | Plus aucune connexion n'est possible : /auth/login répond 503. Piège documenté (§6.4 du guide) — /etc/docsearch/jwt est monté en lecture seule et ses permissions sont interprétées avec l'UID MAPPÉ dans le conteneur : un fichier parfaitement lisible côté hôte peut rester illisible dedans. |
| Haute | Ingestion : des documents attendent et aucun worker ne consomme | La file se remplit sans être consommée. Distinct d'un simple retard : ici personne ne travaille. Vérifier les unités docsearch-worker-* des 3 machines d'ingestion. |
| Haute | Ingestion : le watcher ne bat plus | Plus aucune détection temps réel des nouveaux documents : ils ne seront indexés qu'au prochain scan complet (manage.sh init). Service singleton, sur ingest-1 uniquement. |
| Haute | Ingestion : plus aucune instance Tika ne répond | Aucun document ne peut plus être extrait. L'indexation est à l'arrêt complet. |
| Haute | Nginx : la racine répond 200 au lieu de rediriger vers /connexion | L'accès anonyme n'existe plus : la racine doit répondre 302 vers /connexion. Un 200 signifie que le contrôle d'accès de l'interface a sauté (auth_request de docsearch-ui-vue). |
| Haute | Redis : des clés ont été évincées | Une seule éviction est un événement grave, pas une statistique : allkeys-lru peut faire disparaître le registre des sources, un filtre de chemins ou une session, sans aucune trace ailleurs. Relever --maxmemory, ou purger ce qui a grossi (historiques de recherche, alertes). |
| Haute | Redis : injoignable | Redis porte les registres de sources, la configuration à chaud, les sessions et les compteurs de limitation de débit. Sans lui, /auth répond 503 et plus personne ne se connecte. |
| Haute | TLS : le certificat expire dans moins de {$DOCSEARCH.CERT.JOURS.CRIT} jours | Le guide fait générer un certificat AUTO-SIGNÉ valable 365 jours. Sans renouvellement, l'application devient inaccessible un an jour pour jour après la mise en service. Renouveler : openssl req -x509 ... puis systemctl restart docsearch-nginx |
| Moyenne | Redis : la sauvegarde sur disque échoue | Le volume redis-data ne reçoit plus de snapshot : au prochain redémarrage du conteneur, les registres de sources et la configuration à chaud repartiraient dans l'état du dernier snapshot réussi. Cause habituelle : disque plein. |
| Moyenne | Sources : le partage réseau n'est plus monté | Sur frontend, ce partage sert l'aperçu de document (conversion Office → PDF) : les aperçus échouent, la recherche continue. |
| Avertissement | DocSearch : la recherche met plus de {$DOCSEARCH.RECHERCHE.MS.MAX} ms depuis 10 min |  |
| Avertissement | Ingestion : une instance Tika de TIKA_SERVERS ne répond pas | Une extraction sur N échoue. Identifier laquelle dans /admin/status. |
| Avertissement | Redis : plus de {$DOCSEARCH.REDIS.MEMOIRE.MAX} % de maxmemory utilisés | Avertissement avant les premières évictions. Agir maintenant coûte moins cher. |
| Avertissement | Source {#SOURCE} : aucun document indexé depuis 1 h *(prototype)* | Source enregistrée mais son index est vide. Normal juste après l'enregistrement, anormal ensuite : index supprimé, ou scan jamais lancé pour cette source. |
| Avertissement | Supervision : le compte de sonde n'est plus administrateur | La session s'ouvre mais /admin/status est refusé : svc-supervision a perdu docsearch-admins. Toutes les sondes applicatives agrégées sont aveugles tant que ce n'est pas corrigé. |
| Avertissement | TLS : le certificat expire dans moins de {$DOCSEARCH.CERT.JOURS.AVERT} jours |  |

### DocSearch ingestion

Sondes des machines d'ingestion : les deux serveurs Tika et le partage
réseau des documents sources. Les workers eux-mêmes sont vus par le
modèle "DocSearch socle" (unités systemd) et, côté file, par
"DocSearch Kafka".

**Macros**

| Macro | Défaut | Rôle |
|---|---|---|
| `{$DOCSEARCH.SOURCES.CHEMIN}` | `/data/docsearch-sources` |  |

**Éléments**

| Clé | Nom | Collecte | Intervalle |
|---|---|---|---|
| `docsearch.montage.lisible` | Sources : partage lisible | dépendant | — |
| `docsearch.montage.monte` | Sources : partage monté | dépendant | — |
| `docsearch.montage.vide` | Sources : partage vide | dépendant | — |
| `docsearch.montage[{$DOCSEARCH.SOURCES.CHEMIN}]` | Sources : montage {$DOCSEARCH.SOURCES.CHEMIN} | agent | 5m |
| `net.tcp.service.perf[http,,9998]` | Tika A : temps de réponse | contrôle simple | 1m |
| `net.tcp.service.perf[http,,9999]` | Tika B : temps de réponse | contrôle simple | 1m |
| `net.tcp.service[http,,9998]` | Tika A : port 9998 | contrôle simple | 1m |
| `net.tcp.service[http,,9999]` | Tika B : port 9999 | contrôle simple | 1m |

**Déclencheurs**

| Priorité | Nom | Ce qu'il signifie |
|---|---|---|
| Haute | Sources : le partage est monté mais illisible | Poignée CIFS périmée ou droits modifiés côté serveur de fichiers. Remonter le partage. |
| Haute | Sources : le partage réseau n'est plus monté | La panne la plus silencieuse de la pile. Le watcher continue de battre et les workers de tourner ; il n'y a simplement plus aucun fichier à voir. Aucune erreur nulle part, et l'indexation s'arrête. Remède : mount -a, puis vérifier /etc/fstab et le serveur de fichiers. |
| Moyenne | Tika : les deux instances de cette machine sont muettes | Les 4 instances des deux autres machines d'ingestion prennent le relais : l'extraction continue, plus lentement. Devient HIGH via l'agrégat du modèle "DocSearch application" si toutes tombent. |

### DocSearch application

État du cluster Elasticsearch et agrégats inter-machines. À lier sur un
hôte logique sans interface. Aucun agent requis.

**Macros**

| Macro | Défaut | Rôle |
|---|---|---|
| `{$DOCSEARCH.ES.URL}` | `http://192.168.10.11:9200` | Un nœud de données joignable, à adapter. C'est aussi celui que désigne ES_HOST côté API — utiliser le même rend la sonde représentative de ce que voit l'application. |
| `{$DOCSEARCH.ES.ALIAS}` | `docsearch-all` |  |
| `{$DOCSEARCH.ES.NOEUDS.ATTENDUS}` | `3` |  |
| `{$DOCSEARCH.TIKA.ATTENDUS}` | `6` |  |
| `{$DOCSEARCH.TIKA.MIN}` | `4` |  |
| `{$DOCSEARCH.WORKERS.MIN}` | `9` |  |
| `{$DOCSEARCH.DOCS.CHUTE.MAX}` | `10000` | Chute du nombre de documents indexés, entre deux relevés, jugée anormale. |

**Éléments**

| Clé | Nom | Collecte | Intervalle |
|---|---|---|---|
| `docsearch.agr.conteneurs.malsains` | Agrégat : conteneurs malades dans le cluster | calculé | 2m |
| `docsearch.agr.retard` | Agrégat : documents en attente d'indexation | calculé | 2m |
| `docsearch.agr.tika` | Agrégat : instances Tika joignables | calculé | 2m |
| `docsearch.agr.unites.echouees` | Agrégat : unités systemd en échec dans le cluster | calculé | 2m |
| `docsearch.agr.watchers` | Agrégat : watchers actifs dans le cluster | calculé | 2m |
| `docsearch.agr.workers` | Agrégat : workers d'indexation dans le cluster | calculé | 2m |
| `es.cluster.etat` | Cluster ES : état | dépendant | — |
| `es.cluster.lecture_seule` | Cluster ES : index passés en lecture seule | HTTP | 5m |
| `es.cluster.master` | Cluster ES : nœud master | HTTP | 2m |
| `es.cluster.noeuds` | Cluster ES : nœuds | dépendant | — |
| `es.cluster.noeuds.donnees` | Cluster ES : nœuds de données | dépendant | — |
| `es.cluster.sante` | Cluster ES : santé | HTTP | 1m |
| `es.cluster.shards.non_assignes` | Cluster ES : shards non assignés | dépendant | — |
| `es.cluster.shards.pct` | Cluster ES : shards actifs | dépendant | — |
| `es.cluster.taches` | Cluster ES : tâches en attente | dépendant | — |
| `es.documents.total` | Cluster ES : documents dans l'alias fédéré | HTTP | 5m |

**Déclencheurs**

| Priorité | Nom | Ce qu'il signifie |
|---|---|---|
| Désastre | Elasticsearch : cluster ROUGE | Au moins un shard primaire est indisponible : une partie du corpus ne peut plus être ni cherchée ni indexée. GET /_cluster/allocation/explain donne la raison exacte. |
| Désastre | Elasticsearch : des index sont bloqués en lecture seule | Verrou de seuil disque. Libérer de la place PUIS lever le verrou à la main — Elasticsearch ne le fait pas de lui-même. |
| Haute | DocSearch : chute brutale du nombre de documents indexés | Attendu après une purge volontaire (manage.sh purge-path) ou une réindexation. Inattendu autrement : index supprimé, alias amputé d'un index, ou source retirée par erreur. |
| Haute | Elasticsearch : le cluster n'a plus ses {$DOCSEARCH.ES.NOEUDS.ATTENDUS} nœuds | Avec 2 nœuds de données et 1 arbitre, la perte d'un nœud laisse le quorum tenable ; la perte d'un second l'anéantit (plus d'élection de master possible). Vérifier aussi que le port 9300 est ouvert entre les 3 machines. |
| Haute | Ingestion : PLUSIEURS watchers tournent en même temps | Chaque fichier est publié deux fois sur Kafka, donc extrait et indexé deux fois : charge doublée sur Tika et sur Elasticsearch. Cause : install-units.sh ingest --with-singletons lancé sur plus d'une machine. Arrêter et désinstaller l'unité en trop. |
| Haute | Ingestion : plus AUCUNE instance Tika dans tout le cluster | Plus aucun document ne peut être extrait, sur aucune machine. L'indexation est à l'arrêt. |
| Moyenne | Elasticsearch : cluster JAUNE depuis 15 min | Réplicas non assignés : la recherche fonctionne, la redondance non. Normal quelques minutes après le redémarrage d'un nœud, anormal ensuite. |
| Moyenne | Elasticsearch : des shards restent non assignés depuis 20 min |  |
| Moyenne | Ingestion : aucun watcher actif dans le cluster | Plus de détection temps réel : les nouveaux documents n'arriveront qu'au prochain scan complet. La recherche n'est pas affectée. |
| Avertissement | Elasticsearch : file de tâches du master engorgée | Le master n'absorbe plus les changements d'état : créations d'index et bascules de shards traînent. |
| Avertissement | Elasticsearch : le nœud master a changé | Une élection a eu lieu. Isolé, c'est bénin (redémarrage d'un nœud). Répété, c'est un réseau instable entre les 3 machines, et le cluster passe son temps à se réorganiser au lieu de servir. |
| Avertissement | Ingestion : moins de {$DOCSEARCH.TIKA.MIN} instances Tika sur {$DOCSEARCH.TIKA.ATTENDUS} |  |
| Avertissement | Ingestion : moins de {$DOCSEARCH.WORKERS.MIN} workers actifs dans le cluster | Configuration par défaut : 3 workers sur chacune des 3 machines d'ingestion. En dessous, l'indexation ralentit sans s'arrêter. |
