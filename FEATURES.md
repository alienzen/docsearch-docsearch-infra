# Fonctionnalités de DocSearch

Catalogue des fonctionnalités actuelles, tous dépôts confondus. Pour le
détail technique de chacune, voir le README du dépôt concerné
([docsearch-api](../docsearch-api/README.md),
[docsearch-ingestion](../docsearch-ingestion/README.md),
[docsearch-ui-vue](../docsearch-ui-vue/README.md)) ou ce dépôt pour
l'orchestration.

**Ce fichier ne décrit que l'existant.** Ce qui est décidé mais pas encore
écrit vit dans [PLAN-EVOLUTIONS.md](PLAN-EVOLUTIONS.md) (sept chantiers
arrêtés le 2026-08-12 : autocomplétion, écran « zéro résultat », rétention
des journaux, détection de doublons, synonymes et résultats épinglés,
permaliens, espace personnel) — les deux listes ne doivent jamais se
recouvrir : une fonctionnalité livrée descend du plan vers ce catalogue.

L'interface est [docsearch-ui-vue](../docsearch-ui-vue/README.md), **Vue 3
conforme au Système de Design de l'État**. Elle a remplacé `docsearch-ui`
(HTML/JS sans build), dont le dépôt est désormais archivé en bundle git
(restauration et repli manuel : voir [README.md](README.md), § Architecture
multi-dépôts). Deux
fonctionnalités de l'ancienne interface n'ont pas été reprises et sont
retirées du produit : les 7 thèmes de couleur maison, remplacés par le
clair/sombre/système du DSFR, et les gabarits d'affichage des résultats.

## Recherche

- **Recherche full-text fédérée** sur toutes les sources (fichiers, SQL,
  web) via un alias Elasticsearch commun, avec repli par source.
- **Filtrage par ACL** automatique et transparent : chaque résultat est
  restreint à ce que l'utilisateur courant a le droit de voir (public,
  propriétaire, utilisateurs et groupes autorisés — POSIX et/ou LDAP/AD).
- **Recherche floue par défaut** (tolérance aux fautes de frappe) ou
  **recherche exacte** en entourant la requête de guillemets.
- **Recherche restreinte à un champ** (`search_in`) : tout, titre, auteur
  ou chemin de fichier.
- **Syntaxe avancée dans la barre de recherche** : opérateurs
  `auteur:`, `type:`, `source:`, `dossier:`, `mots-cles:` (+ alias
  anglais), combinables entre eux et avec du texte libre — convertis en
  puces de filtre. Reconnaît aussi dynamiquement les **facettes SQL
  personnalisées** de chaque source (ex: `bureau:Paris`), sans
  configuration supplémentaire.
- **Autocomplétion** sous la barre de recherche : d'abord les recherches
  passées de l'utilisateur, puis les auteurs et mots-clés du corpus
  **qu'il a le droit de voir** (mêmes filtres ACL que la recherche
  elle-même). Un auteur ou un mot-clé retenu devient une puce de filtre,
  soit exactement l'état qu'aurait produit la facette cochée. Les
  requêtes des *autres* utilisateurs ne sont jamais proposées — elles
  nomment régulièrement un dossier que leur auteur est seul à connaître.
  Désactivée par défaut.
- **Historique de recherche personnel** (« Mes recherches récentes ») :
  chacun retrouve ce qu'il a lui-même cherché, dédoublonné, et le
  relance d'un clic. Aucune collecte nouvelle — la donnée est le journal
  de recherche déjà écrit, jusqu'ici visible des seuls administrateurs.
  Aucune route ne permet de lire l'historique de quelqu'un d'autre.
  Désactivé par défaut.
- **Facettes** : type de fichier, période (date de modification), source,
  auteur, mots-clés, dossier — plus des facettes personnalisées par
  source SQL (colonnes marquées "facette" dans son mapping).
  Sélection multiple combinée en OU dans une même facette, sauf les
  mots-clés (champ multi-valué) combinés en ET : cocher un second
  mot-clé restreint aux documents qui portent les deux.
- **Tri** des résultats (pertinence, date...).
- **Thésaurus métier** : les sigles et appellations qui désignent la même
  chose (« DRH » et « direction des ressources humaines », ancien et
  nouveau nom d'un service) se déclarent depuis le panneau
  d'administration et prennent effet **immédiatement, sans
  réindexation** — le moteur recharge ses analyseurs de recherche. La
  recherche entre guillemets reste littérale : « terme exact » veut dire
  exact.
- **Permalien de recherche** : l'état de la recherche (texte, facettes,
  période, tri, page) vit dans l'URL, donc une recherche s'envoie par
  lien, se met en signet et survit à F5 ; le bouton Précédent revient à
  la recherche précédente. Le lien partage la **recherche, pas les
  droits** — le destinataire la rejoue avec ses propres ACL et peut en
  voir moins. L'URL porte les critères canoniques, ceux d'après
  l'analyse des opérateurs de la barre : `type:pdf` tapé à la main et la
  facette « PDF » cochée produisent le même lien.
- **Documents similaires** ("More Like This") depuis la fiche détail.
- **Aperçu de documents** en ligne (conversion PDF à la volée via
  LibreOffice pour les formats bureautiques).
- **Export des résultats** de recherche en XLSX ou DOCX.
- **Recherches enregistrées** par utilisateur, avec **alertes**
  (fréquence quotidienne ou hebdomadaire) : un worker dédié détecte les
  nouveaux résultats et dépose une notification **in-app** (pas d'email,
  pour ne jamais faire sortir de titres de documents confidentiels du
  périmètre ACL).
- **Collections personnelles** ("Mes collections") : sélection et
  regroupement de documents par l'utilisateur, indépendamment de la
  recherche.
- **Mots-clés personnalisés** ajoutables/retirables sur un document par
  les utilisateurs, réappliqués automatiquement à chaque réindexation.
- **Assistant conversationnel (RAG)** — ⚠️ **maquette uniquement, non
  fonctionnelle.** La page dédiée (`chat.html`) illustre l'expérience
  visée avec des réponses écrites à l'avance : elle n'interroge PAS les
  documents indexés. L'endpoint `/ask` n'existe pas côté docsearch-api,
  et aucun modèle de langage n'est branché. Le lien « Assistant IA » de
  l'en-tête de recherche étant AFFICHÉ par défaut (`chat_enabled` vaut
  `true`), le masquer depuis l'admin est recommandé sur toute
  installation où cette maquette pourrait être prise pour une
  fonctionnalité réelle. Voir `docsearch-docs/proposition_docsearch.docx`
  pour l'option envisagée, et [PLAN-EVOLUTIONS.md](PLAN-EVOLUTIONS.md) — le
  chantier §5 (RAG réel ou recherche sémantique seule) y est resté hors
  plan, faute d'arbitrage sur le matériel qu'il suppose.
- **Écran « aucun résultat » actionnable** : correction orthographique
  (« vouliez-vous dire »), retrait d'un filtre chiffré à l'avance
  (« sans le type PDF — 12 résultats »), et sources non sélectionnées où
  il y a quelque chose. Chaque compte annoncé est calculé sous les droits
  de l'utilisateur : cliquer donne bien ce nombre de résultats, jamais
  une liste vide. La correction n'est proposée que si elle mène à des
  documents qu'il peut voir.
- **Mesure de satisfaction** : pouce haut/bas par recherche, popup NPS
  occasionnelle, suggestions libres, tracking de clic sur les résultats
  (toujours actif, signal passif) — chaque signal individuellement
  suspendable depuis l'admin.

## Indexation / ingestion

- **Sources fichiers multiples**, chacune avec son propre index
  Elasticsearch dédié, ajoutables/retirables à chaud sans redémarrage.
- **Surveillance temps réel** (watcher, `PollingObserver` — compatible
  CIFS/NFS, contrairement à inotify) : création, modification,
  suppression, renommage de fichier ou de dossier entier.
- **Pipeline producer/workers** (Kafka) pour l'indexation initiale à haut
  débit : plusieurs workers en parallèle, scalable horizontalement
  (`sudo ./manage.sh scale-workers N`).
- **OCR** (Tesseract via Tika) pour les PDF scannés et les images
  (jpg/png/tiff/bmp), activable **par source**, français par défaut.
- **Extraction ACL** POSIX (owner/group/permissions) et `getfacl`.
- **Archives** (zip, tar/tar.gz/tar.bz2/tar.xz, 7z) : contenu indexé
  fichier par fichier avec ACL hérités de l'archive, protection contre
  zip slip et zip bomb, profondeur d'imbrication limitée.
- **Emails PST** (Outlook) : indexation individuelle de chaque message.
- **Connecteur SQL** (PostgreSQL/MySQL) : indexe le résultat d'une
  requête (une ligne = un document), réconciliation complète à chaque
  passage, mapping colonne→champ ES en liste blanche explicite, DSN
  chiffrés (Fernet) enregistrables depuis l'admin.
- **Connecteur web** (Elastic Open Web Crawler) : indexe le contenu d'un
  site externe crawlé, réconciliation automatique des pages disparues.
- **Renommage/déplacement sans réextraction Tika** : fichier, dossier
  entier ou membre d'archive — le contenu déjà extrait est simplement
  recopié vers la nouvelle identité.
- **Types de fichiers configurables dynamiquement**, par source
  (activation, taille maximale), y compris pour les archives.
- **Filtres de sous-dossiers** (inclusion ou exclusion, liste
  blanche/noire) par source, modifiables à chaud.
- **Paramètres opérationnels** modifiables à chaud sans redémarrage
  (limites d'archives, cadences de polling, taille de lot, langue/
  stratégie OCR...).

## Administration

- **Panneau web complet** (`admin.html`), réservé aux membres d'un groupe
  LDAP/AD dédié.
- **État des composants** en temps réel : Elasticsearch (statut de
  cluster), Redis, Kafka, instances Tika, workers actifs, progression de
  l'indexation, battement du watcher — plus trois contrôles d'écriture que
  le statut de cluster ne couvre pas : journalisation des recherches,
  recueil des suggestions et réponses NPS. Un cluster « green » dont les
  index sont passés en lecture seule (flood-stage watermark, disque à
  95 %) affiche du vert partout pendant que les avis, les statistiques,
  les suggestions et les notes de satisfaction se perdent en silence.
- **Gestion des sources** fichiers/SQL/web : création, retrait, libellé,
  description, activation OCR (fichiers) — plus une vue unifiée «
  Toutes les sources » avec bascules indépendantes « Recherche » et «
  Collections », tous types de source confondus.
- **Détection de doublons** : chaque document fichier porte une empreinte
  de son contenu, ce qui permet de compter les exemplaires en trop et de
  chiffrer la place qu'ils occupent, avec les chemins où aller regarder.
  Rapport calculé une fois par jour (l'agrégation parcourt l'index) et
  recalculable à la demande. Les documents indexés avant cette
  fonctionnalité se rattrapent par `./manage.sh backfill-hashes`, qui
  relit les fichiers sans appeler Tika.
- **Purge d'index** ciblée par motif de chemin (dry-run par défaut) et
  **déclenchement de scan** d'indexation à la demande.
- **Statistiques de recherche** (`stats.html`) : volumétrie, requêtes
  fréquentes, recherches sans résultat, temps de recherche, export,
  journal d'audit des actions d'administration.
- **Mesure des temps de recherche** sur le trafic réel, et non sur une
  requête témoin : chaque recherche enregistre le temps du moteur
  (`took` d'Elasticsearch) et le temps total de l'API, dont l'écart
  indique si une lenteur vient du moteur ou de ce qui l'entoure. Les
  deux sont conservés dans l'index `search_logs`, agrégés dans les
  statistiques (moyenne, médiane, 95ᵉ centile, nombre de recherches
  lentes) et exportés avec l'historique. Au-delà d'un seuil réglable
  (`SLOW_SEARCH_MS`, 2000 ms par défaut, aligné sur la macro Zabbix
  correspondante), la recherche laisse une ligne dans le journal du
  service. Complète la sonde Zabbix, qui ne mesure qu'une requête
  témoin une fois par minute.
- **Ventilation par groupe d'utilisateurs** : recherches, avis
  positifs/négatifs, score NPS, suggestions et recherches sans résultat
  sont aussi présentés par groupe LDAP. Les groupes sont figés **à
  l'écriture** de chaque événement, donc un changement de service ne
  réécrit pas l'historique. Deux mises en garde figurent sur la page :
  un utilisateur de plusieurs groupes compte dans chacun (la somme
  dépasse le total), et **aucun effectif minimum n'est appliqué** — dans
  un groupe d'une personne, ces chiffres la désignent. Voir
  `docsearch-api/README.md`, section « Statistiques par groupe ».
- **Conservation des journaux** : les cinq index de journalisation
  (recherches, connexions, audit, NPS, suggestions) sont purgés une fois
  par jour au-delà d'une durée réglable par journal — 12 mois pour les
  recherches et les connexions, 36 pour l'audit, 24 pour la satisfaction.
  `0` vaut conservation illimitée. Deux motifs : le disque, dont le
  franchissement du seuil de 95 % passe les index en lecture seule
  pendant que le cluster reste « green », et la conservation de données
  personnelles (identifiant, requêtes, adresse IP), qui doit avoir une
  durée décidée. Les données utilisateur — mots-clés personnalisés,
  collections — ne sont jamais concernées. Un aperçu montre ce qu'une
  durée emporterait avant de la régler.
- **Bascules d'interface** granulaires : assistant IA, pied de page,
  liens Administration/Statistiques, export, aide, collections,
  mots-clés personnalisés, alertes, tri, temps de recherche, badge
  utilisateur, animation d'accueil — chacune indépendamment
  activable/désactivable, effectives immédiatement.
- **Personnalisation** : bloc-marque, titre et sous-titre d'en-tête,
  favicon, description et mention de bas de page, chemin affiché par le
  bouton « Copier le chemin ».
- **Écran de connexion** aux couleurs de l'installation (même bloc-marque,
  même titre, même pied de page que le reste), avec bascule « Afficher »
  du mot de passe et bouton de rattrapage de la connexion automatique.
- **Contournements de recette** (`ADMIN_AUTH_DISABLED`, `DEV_USER`,
  `TRUST_X_USER_HEADER`, `KERBEROS_DEV_PRINCIPAL`) : l'API **refuse de
  démarrer** si l'un d'eux est armé avec `API_ENV=production`, plutôt que
  de l'ignorer. Hors production, encadré au démarrage et ligne de log à
  chaque usage.

## Sécurité

- **ACL POSIX + LDAP/AD** : chaque recherche est filtrée par appartenance
  de l'utilisateur (public, propriétaire, utilisateurs et groupes
  autorisés).
- **Authentification par jeton signé** (RS256, clé publiée en JWKS),
  vérifiée **par l'application elle-même** à chaque requête — jamais
  déléguée à une ligne de configuration du reverse-proxy, qui serait
  court-circuitée par tout ce qui atteint l'API autrement. Session en
  cookie `httpOnly`, révocable : la déconnexion invalide réellement le
  jeton de renouvellement côté serveur.
- **Deux fournisseurs derrière une interface unique** : l'annuaire
  LDAP/AD, et des comptes de secours locaux (Argon2id) qui portent leurs
  propres groupes — sans eux, une panne d'annuaire rendrait DocSearch
  totalement inaccessible, administration comprise. Le serveur choisit
  seul le fournisseur ; aucun repli de l'un vers l'autre, qui masquerait
  les pannes et trahirait la nature du compte.
- **Connexion automatique Kerberos/SPNEGO** — l'utilisateur déjà
  authentifié sur le domaine arrive connecté, sans saisie. Désactivée par
  défaut (interrupteur dans le panneau d'administration) ; le formulaire
  reste toujours disponible, la tentative échoue en silence sur un poste
  hors domaine.
- **Message d'erreur générique unique** sur échec de connexion, quelle
  que soit la cause — et **jamais un 401 pour une panne** : annuaire ou
  Redis indisponible répond 503, ce qui envoie chercher au bon endroit.
- **Limitation des tentatives** (Redis), par identifiant *et* par
  adresse IP, fenêtre ancrée au premier échec.
- **Journal des connexions** (index Elasticsearch dédié) : succès,
  identifiants refusés, blocages, indisponibilités — le mot de passe n'y
  transite sous aucune forme, ce qu'un test vérifie.
- **Protection zip slip / zip bomb** sur l'indexation d'archives, avec
  limites configurables (nombre de fichiers, taille décompressée,
  profondeur d'imbrication).
- **DSN de connexion SQL chiffrés** (Fernet) s'ils sont enregistrés
  depuis l'admin plutôt que par variable d'environnement — jamais
  réaffichés en clair après coup.
- **Résilience de configuration** : Redis injoignable → repli automatique
  sur des valeurs par défaut codées en dur, jamais d'arrêt de service
  pour un problème de configuration.

## Infrastructure

- **Architecture multi-dépôts** (6 dépôts indépendants — ingestion, API,
  UI, orchestration, documents commerciaux, génération de jeux de test)
  pour des cycles de déploiement et un contexte de développement séparés.
- **Orchestration podman + systemd (Quadlet)** : chaque service est une
  unité systemd, démarrage au boot, journaux dans journald. Pile
  mono-hôte (ES single-node) ou déploiement 8 machines par rôle
  (cluster ES 3 nœuds, Nginx, TLS).
- **Scaling horizontal** des workers d'indexation — une unité systemd par
  worker, ajustable par `manage.sh scale-workers N`.
- **CLI complète** (`manage.sh`) : démarrage/arrêt, indexation, gestion
  des sources et de leur configuration, construction des images,
  sauvegarde, réinitialisation.
- **Déploiement hors ligne** : la production tourne sur un réseau isolé,
  les images y arrivent par transfert (`podman save`/`load`) et aucune
  construction n'a lieu au démarrage.
