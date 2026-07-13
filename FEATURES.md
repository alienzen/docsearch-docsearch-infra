# Fonctionnalités de DocSearch

Catalogue des fonctionnalités actuelles, tous dépôts confondus. Pour le
détail technique de chacune, voir le README du dépôt concerné
([docsearch-api](../docsearch-api/README.md),
[docsearch-ingestion](../docsearch-ingestion/README.md),
[docsearch-ui](../docsearch-ui/README.md)) ou ce dépôt pour
l'orchestration.

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
- **Facettes** : type de fichier, période (date de modification), source,
  auteur, mots-clés, dossier — plus des facettes personnalisées par
  source SQL (colonnes marquées "facette" dans son mapping).
- **Tri** des résultats (pertinence, date...).
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
- **Assistant conversationnel (RAG)** — page dédiée (`chat.html`),
  interroge les documents indexés en langage naturel.
- **Gabarits d'affichage des résultats** configurables (6 styles :
  défaut, compact, minimal, dense, essentiel, complet sans extrait),
  assignables par source, composés champ par champ depuis l'admin.
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
  (`./manage.sh scale-workers N`).
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
  l'indexation, battement du watcher.
- **Gestion des sources** fichiers/SQL/web : création, retrait, libellé,
  description, activation OCR (fichiers) — plus une vue unifiée «
  Toutes les sources » avec bascules indépendantes « Recherche » et «
  Collections » et choix du gabarit d'affichage, tous types de source
  confondus.
- **Purge d'index** ciblée par motif de chemin (dry-run par défaut) et
  **déclenchement de scan** d'indexation à la demande.
- **Statistiques de recherche** (`stats.html`) : volumétrie, requêtes
  fréquentes, recherches sans résultat, export, journal d'audit des
  actions d'administration.
- **Bascules d'interface** granulaires : assistant IA, pied de page,
  liens Administration/Statistiques, export, aide, collections,
  mots-clés personnalisés, alertes — chacune indépendamment activable/
  désactivable, effectives immédiatement.
- **Mode test sans authentification** (`ADMIN_AUTH_DISABLED`), délibérément
  bruyant (bannière + log à chaque requête) pour ne jamais être oublié
  en production.

## Sécurité

- **ACL POSIX + LDAP/AD** : chaque recherche est filtrée par appartenance
  de l'utilisateur (public, propriétaire, utilisateurs et groupes
  autorisés).
- **Authentification déléguée au SSO** (Keycloak, AgentConnect...) via un
  header `X-User` injecté par Nginx après validation — simulable en
  développement sans SSO (`DEV_USER`).
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
- **Orchestration Docker Compose**, profils dev (ES single-node, 1
  worker) et prod (cluster ES 3 nœuds, Nginx, TLS).
- **Scaling horizontal** des workers d'indexation.
- **CLI complète** (`manage.sh`) : démarrage/arrêt, indexation, gestion
  des sources et de leur configuration, sauvegarde, réinitialisation.
