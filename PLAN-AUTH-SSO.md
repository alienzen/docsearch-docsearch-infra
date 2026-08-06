# Authentification DocSearch alignée sur Charlie, SSO compris — plan d'intégration

Objectif : donner à DocSearch une authentification réelle — de la même facture que
`charlie/app-api-auth` — et une connexion automatique par ticket Kerberos/SPNEGO pour qui
est déjà authentifié sur le domaine. Périmètre : `docsearch-api`, `docsearch-ui-vue`,
`docsearch-infra`. Rien de `charlie` n'est déployé ici (voir §0.1).

Référence permanente : `~/charlie/app-api-auth/README.md` (architecture, format des JWT,
régimes d'erreur) et `~/charlie/PLAN-SSO-KERBEROS.md` (SSO, dont les trois pièges de
déploiement, qui sont les mêmes ici). Ce document ne les recopie pas : il dit ce qui se
transpose tel quel, ce qui doit diverger, et pourquoi.

---

## État d'avancement (2026-08-06)

**Tout le code est écrit ; ce qui reste ne s'écrit pas, cela se demande à
l'exploitation.** 82 tests passent, dont ceux qui tapent le vrai annuaire de dev et le
vrai Redis ; `npm run build` (typage compris) et les 105 tests du front passent ; les deux
configurations Nginx sont validées par `nginx -t` ; l'image se construit et `gssapi` y est
réellement sollicitée (un keytab vide y produit une vraie `GSSError`, correctement
traduite en indisponibilité — la seule part de l'acceptation qui s'éprouve sans KDC).

**Rien n'est déployé** : la pile de développement tourne toujours sur l'image précédente.
La bascule demande trois décisions d'exploitation (génération des clés, `API_ENV`,
dérogation LDAP en clair si l'annuaire n'expose pas LDAPS) — voir
[HOWTO-simuler-utilisateur.md](HOWTO-simuler-utilisateur.md).

| § | Sujet | État |
|---|---|---|
| 0bis | Annuaire durci (`auth/directory.py`), garde-fous, harnais pytest | **fait** |
| 1 | Fournisseurs, jetons RS256+JWKS, sessions révocables, rate limiting, `login_events` | **fait** |
| 1.4 | Bascule des points d'appel de `search_api.py` | **fait** — 26 signatures, 20 corps |
| 1.7-1.8 | Page de connexion, déconnexion, renouvellement transparent, Nginx | **fait** |
| 2 | Kerberos : mapping, acceptation GSSAPI, route, réglage, image, tampons | **fait** — non éprouvé sur un ticket authentique, faute de KDC |
| 2b | Image : `gssapi` compilée puis compilateur purgé, `klist` conservé | **fait** — vérifié dans le conteneur construit |
| 2.5a-b | FQDN/DNS/SPN/certificat, stratégie de parc navigateur | **à faire — dépend de l'infra** |
| 4.1 | Keytab, compte de service | **à faire — dépend de l'infra** |

**Le test qui mesure tout ce chantier**, et qui échouait au départ :

```bash
curl -H "X-User: alice.admin" http://192.168.56.101:8000/admin/status   # 200 avant → 401 après
```

**Ce que la mise en œuvre a appris et que ce plan n'avait pas vu :**

- **Le jeton de rafraîchissement ne servant qu'une fois, le renouvellement doit être
  mutualisé côté client.** Une page de recherche lance cinq appels en parallèle au
  chargement ; à l'expiration du jeton d'accès ils reçoivent tous 401 en même temps, et
  cinq renouvellements concurrents auraient déconnecté l'utilisateur — le premier
  réussissant, les quatre autres présentant un jeton déjà consommé. Corrigé dans
  `client.ts` (une seule promesse partagée).
- **`error_page 401` ne doit surtout pas s'appliquer aux routes proxifiées.** Il ne
  s'applique en fait qu'aux 401 produits par Nginx lui-même (`auth_request`), les réponses
  d'un `proxy_pass` n'étant interceptées que si `proxy_intercept_errors` est activé — ce
  qui tombe juste, mais par chance : activer cette directive un jour transformerait les
  401 d'API en redirections HTML que le front ne saurait pas lire.
- **Le contrôle d'`ACCESS_GROUP` a été déplacé à la connexion**, en plus de chaque
  requête. Sans cela, quelqu'un hors du groupe repartait avec une session parfaitement
  valide et voyait chaque page échouer sans comprendre pourquoi.
- **Le refus du bind LDAP en clair est un changement cassant** pour toute installation
  existante (`LDAP_HOST=ldap://…` dans le `.env` d'aujourd'hui). Traité comme tel :
  dérogation explicite, documentée dans `.env.example` et dans le README, et **non**
  fatale — en faire une erreur couperait l'application au lieu de la sécuriser.

---

## Ce dont on part — constat sur pièces

**L'autorisation est complète ; l'authentification n'existe pas.**

- `require_access` / `require_admin`
  ([access_auth.py](../docsearch-api/app/access_auth.py),
  [admin_auth.py](../docsearch-api/app/admin_auth.py)) refusent en 401 sans en-tête
  `X-User`, puis résolvent les groupes par LDAP. C'est solide, et ça n'a aucune valeur
  tant que rien ne garantit d'où vient `X-User`.
- Dans [nginx.conf](nginx/nginx.conf), les huit blocs `auth_request` sont commentés
  (« *SSO — décommenter en production* »), la `location /auth/validate` qui interrogerait
  Keycloak aussi, et aucun Keycloak n'existe dans les unités Quadlet. Le SSO y est une
  intention documentée, jamais exercée.
- Conséquence directe, énoncée sans détour par
  [HOWTO-simuler-utilisateur.md](HOWTO-simuler-utilisateur.md) : « attaquer directement le
  port 8080 renvoie 401 : rien n'y injecte `X-User` ». L'inverse est tout aussi vrai —
  `curl -H "X-User: alice.admin" http://<hôte>:8000/admin/status` répond **200
  aujourd'hui**, l'unité `docsearch-api.container` publiant le port 8000. La sécurité
  repose entièrement sur la configuration du proxy plus l'isolation réseau.

**Trois défauts de `ldap_resolver.py`**, à corriger avant tout le reste puisque tout le
contrôle d'accès en dépend : filtre construit en f-string sans `escape_filter_chars`
(injection de filtre LDAP par un identifiant contrôlé), aucun TLS ni validation de
certificat, aucun `receive_timeout`, et un `lru_cache` qui ne s'invalide qu'au
redémarrage (une exclusion de groupe met un redémarrage à être prise en compte).

**Le reste du terrain :**

| Fait | Conséquence pour ce plan |
|---|---|
| Aucun PostgreSQL dans la pile (ES, Kafka, Redis, Tika) | Les comptes locaux vont en Redis, §0.3 |
| Redis persistant (`redis-data.volume`) déjà source de vérité de la configuration | Support naturel des sessions, du rate limiting et des comptes |
| Aucun test dans `docsearch-api`, CI = `ruff` + `docker build` | Le harnais de test fait partie du chantier, pas d'un « après » |
| `search_api.py` : 2876 lignes, 55 usages de `x_user`, 50 `Depends(require_admin)` | La bascule est mécanique mais large — à faire d'un coup, §1.4 |
| Front Vue multi-pages (6 entrées HTML), gardées une à une par `auth_request` | Une session en mémoire JS ne protège rien : il faut un cookie, §0.4 |
| Production sans accès Internet (`HOWTO-deploiement-hors-ligne.md`) | Aucun OIDC externe possible. Kerberos contre l'AD interne est le **seul** SSO cohérent |
| `ACCESS_AUTH_DISABLED` / `ADMIN_AUTH_DISABLED` contournent *aussi* la vérification de l'en-tête | Défaut relevé par le dossier Charlie ; corrigé en §0.2 |

---

## §0. Les quatre arbitrages préalables

### 0.1 DocSearch porte sa propre intégration, il ne consomme pas `app-api-auth`

La règle « un seul point de contact avec l'annuaire » du `CLAUDE.md` global vaut **par
projet**, pas par VM — elle est déjà tranchée ainsi pour `processus/bpmn-api`, et pour un
motif qui s'applique mot pour mot ici : la production de DocSearch est déconnectée, elle
doit être déployable sans aucun élément de `charlie`, et dépendre d'`app-api-auth`
obligerait à embarquer un service entier d'un autre projet — plus son PostgreSQL, plus sa
table `users` possédée par `app-api-core` — pour la seule authentification.

**Ce qui est « identique à Charlie » est donc l'architecture, pas l'instance.** Interface
`AuthProvider`, RS256 + `kid` + JWKS, refresh révocable en Redis, rate limiting à deux
clés, message d'erreur générique unique, 503 franc sur annuaire injoignable, journal des
connexions sur toutes les branches de sortie.

### 0.2 Un module dans `docsearch-api`, pas un vingt-et-unième conteneur

Chez Charlie, le service séparé achète une propriété précise : `app-api-core` ne parle
jamais à l'annuaire ni aux mots de passe. **Cette propriété est inatteignable ici**, et
c'est ce qui tranche : `docsearch-api` interroge déjà LDAP sur le chemin de recherche
(`search_query.py`, 3 appels ; `search_api.py`, 4 appels) parce que le filtrage ACL des
documents se fait par groupes, à chaque requête. Un service d'authentification séparé
laisserait donc l'annuaire dans l'API de toute façon, en ajoutant un aller-retour HTTP
par recherche.

Le clou : **le worker d'alertes rejoue les recherches enregistrées pour le compte
d'utilisateurs absents** (`alert_worker.py` → `search_query.py`). Il n'a ni requête HTTP,
ni cookie, ni jeton — seulement un identifiant. La résolution des groupes par l'annuaire à
partir d'un identifiant seul doit donc rester possible hors de toute session : c'est une
contrainte structurelle de DocSearch que Charlie n'a pas.

Arborescence cible, dans `docsearch-api/app/auth/` :

```
auth/
  base.py            AuthProvider, LoginCredentials, ResolvedIdentity, les 2 exceptions
  ldap.py            LdapAuthProvider   (bind technique + bind utilisateur)
  local.py           LocalAuthProvider  (Argon2id, comptes de secours en Redis)
  kerberos.py        KerberosAuthProvider (§2) — quasi-copie de celui de Charlie
  directory.py       remplace ldap_resolver.py : recherche, groupes, TLS, cache TTL
  tokens.py          RS256, kid, JWKS, émission/validation access + refresh
  sessions.py        refresh révocable, rate limiting — clés Redis
  events.py          login_events → index ES
  router.py          /auth/*
  deps.py            current_user(), require_access(), require_admin()
```

*Si l'exploitation préfère malgré tout un service séparé* (`docsearch-auth`), rien de ce
plan n'est perdu : le contenu de `auth/` devient le service, `deps.py` reste dans l'API et
valide les jetons par JWKS. Le coût est un conteneur, une unité Quadlet, un rôle de plus
dans le guide d'installation 8 serveurs et une image de plus à transférer hors ligne — pour
un unique consommateur.

### 0.3 Les comptes locaux vivent en Redis, et portent leurs groupes

Pas de PostgreSQL dans la pile ; en ajouter un pour une poignée de comptes serait un
service avec état, une sauvegarde et une procédure de restauration de plus.

Ces comptes sont des **comptes de secours**, au sens exact où `processus/bpmn-api` en a :
une panne d'annuaire rend aujourd'hui DocSearch totalement inaccessible, administration
comprise (`require_access` refuse quand `get_user_groups` ne rend rien). Ils ne sont pas
un système de comptes utilisateurs — pas d'inscription, pas d'écran de gestion, création
par un script d'exploitation.

Point à ne pas manquer : **le compte local porte sa propre liste de groupes**. Sans cela,
il ne servirait à rien — l'annuaire étant en panne, `get_user_groups` rend `[]` et le
compte de secours se ferait refuser par le contrôle d'accès qu'il est censé contourner. La
fonction unique `directory.get_effective_groups(login)` rend donc l'union des `memberOf`
annuaire et des groupes du compte local s'il existe, et **tout** le code (accès, admin,
ACL, worker d'alertes) passe par elle.

```
docsearch:auth:user:<login>   hash  { password_hash, display_name, groups (JSON), disabled, created_at }
docsearch:auth:refresh:<jti>  string TTL = durée de vie du refresh — absence = révoqué
docsearch:auth:rl:<clé>       compteur TTL = fenêtre de rate limiting
```

### 0.4 La session voyage en cookie httpOnly, pas en en-tête `Authorization`

Le front est un build **multi-pages** : six fichiers HTML physiques, chacun gardé par un
`auth_request` nginx — c'est écrit dans `vite.config.ts` et c'est la raison d'être de ce
choix de build. Un jeton gardé en mémoire JavaScript ne peut pas protéger le chargement
d'une page : au moment où le navigateur demande `/admin.html`, aucun JavaScript de
DocSearch ne tourne encore. Il faut donc quelque chose que le navigateur envoie tout seul,
et qui reste hors de portée du JS : cookie `httpOnly`, `Secure`, `SameSite=Strict`,
`Path=/`.

Écart assumé avec Charlie, qui garde l'access token en mémoire JS et ne met que le refresh
en cookie : son front est une SPA à point d'entrée unique, le nôtre ne l'est pas.

---

## Les six invariants

**1. Le jeton est validé DANS l'application.** Jamais seulement dans le proxy. Le dossier
Charlie tire précisément cette leçon de l'état actuel de DocSearch : « un mécanisme dont la
moitié sensible tient dans des lignes commentées se déploie à moitié sans que personne s'en
aperçoive ». Variante écartée pour la même raison : `spnego-http-auth-nginx-module` (nginx
à recompiler, keytab confié au proxy) et l'en-tête de confiance posé par le proxy.

**2. `X-User` cesse d'être une entrée de confiance.** L'identité vient d'un claim de jeton
signé. `X-User` ne subsiste que comme harnais de développement, sous condition
`API_ENV != "production"` — sinon l'API **refuse de démarrer**, elle ne se contente pas
d'ignorer le réglage. Même traitement pour `ACCESS_AUTH_DISABLED`, `ADMIN_AUTH_DISABLED`,
`DEV_USER` et `KERBEROS_DEV_PRINCIPAL` : un seul contrôle, au même endroit.

**3. Un humain = un identifiant, en minuscules.** `resolve_user()` fait déjà `.lower()`,
mais les clés Redis des recherches enregistrées, des collections et des alertes ont été
écrites avec cette forme sans que rien ne la garantisse ailleurs. La forme canonique
devient explicite et unique — la casse est la faille qui a coûté le plus cher chez Charlie
(§1 de leur plan), et pour un motif transposable : le KDC rend la forme canonique du
compte, le formulaire rend la forme saisie. Deux formes = deux jeux de recherches
enregistrées.

**4. Kerberos authentifie, l'annuaire renseigne.** Le ticket prouve *qui*. Le nom,
le mail et les `memberOf` viennent d'une recherche par bind technique. Le PAC d'AD n'est
pas décodé.

**5. Le SSO est une tentative, jamais une exigence.** Poste hors domaine, navigateur non
configuré, compte de secours : le formulaire reste pleinement fonctionnel et la tentative
échoue en silence.

**6. Annuaire injoignable ⇒ 503 franc.** Jamais « identifiant ou mot de passe
incorrect ». Une panne ne se déguise pas en échec d'authentification.

---

## Architecture cible

```
navigateur                nginx infra (TLS)      nginx ui-vue         docsearch-api
─ page ────────────────►  proxy_pass ────────►   auth_request ────►   GET /auth/check-access
                                                 (cookie relayé)      valide le cookie JWT
                                                                      → 200 / 401 / 403
   401 ◄── error_page 401 = /connexion?next=…
─ /connexion ──────────►  (page publique, sans auth_request)
   ├─ tentative SSO ───►  GET /auth/login/kerberos   401 + WWW-Authenticate: Negotiate
   │  (rejeu automatique du navigateur)             → gssapi → principal → annuaire
   │                                                → 200 + Set-Cookie
   └─ formulaire ──────►  POST /auth/login  {identifiant, mot de passe}
                                                    → LDAP ou local → 200 + Set-Cookie
─ appels API ──────────►  cookie envoyé seul par le navigateur (même origine)
                                                    Depends(current_user) → login
```

`X-User` n'apparaît plus nulle part sur ce schéma. C'est le but.

---

## §0bis. Lot 0 — Durcir l'existant

Sans ce lot, tout le reste est décoratif : le contrôle d'accès reposerait sur une
résolution de groupes vulnérable et un interrupteur de contournement toujours actif.

1. **Réécrire `ldap_resolver.py`** en `auth/directory.py`, sur le modèle de
   [`app-api-auth/app/ldap_client.py`](../../charlie/app-api-auth/app/ldap_client.py) :
   `escape_filter_chars` sur l'identifiant, filtre `(|(uid={u})(sAMAccountName={u}))`
   (déjà compatible AD), LDAPS avec `ssl.CERT_REQUIRED` et validation de CA réelle,
   `connect_timeout` **et** `receive_timeout` typés `int`, dérogation dev-only
   `LDAP_ALLOW_PLAINTEXT_INSECURE` bruyamment journalisée, cache à TTL (60 s) plutôt
   qu'un `lru_cache` infini. Ajouter `get_effective_groups()` (§0.3).
   *Piège connu, à ne pas réintroduire : `ldap3` 2.9.1 casse sur Python 3.14 si les deux
   timeouts sont passés en `float`. L'image de l'API est en 3.12, l'hôte de dev en 3.14 —
   garder les deux en `int` dans les deux cas.*
2. **Verrouiller les contournements** : un module `auth/guardrails.py` lu à l'import qui
   lève si `API_ENV=production` et qu'un des interrupteurs de dev est armé. Conserver
   l'encadré ASCII au démarrage, qui est un bon réflexe et que Charlie a copié.
3. **Monter le harnais de test** : `pytest`, `conftest.py`, marqueur `requires_ldap` qui
   *skippe* proprement si `~/ldap-test-stack` est injoignable, Redis réel nettoyé
   avant/après (motif exact de Charlie). Ajouter le job `pytest` à
   `.github/workflows/ci.yml`, qui ne fait aujourd'hui que `ruff` et `docker build`.

---

## §1. Lot 1 — Le socle d'authentification (sans SSO)

### 1.1 Les fournisseurs

`AuthProvider` copié tel quel de
[`base.py`](../../charlie/app-api-auth/app/auth_providers/base.py) — y compris la
séparation `AuthenticationError` (→ 401, message générique unique) /
`AuthProviderUnavailableError` (→ 503).

- **`LdapAuthProvider`** : bind technique pour trouver le DN, puis bind avec les
  identifiants de l'utilisateur. Mot de passe jamais stocké, jamais journalisé, jamais
  transmis au-delà.
- **`LocalAuthProvider`** : Argon2id (`argon2-cffi`, roue pure disponible, aucun
  compilateur requis), vérification seule, et vérification contre un hash factice quand le
  compte est inconnu pour ne pas laisser le temps de réponse dire s'il existe.

**Le client ne choisit pas le fournisseur** (règle Charlie du 2026-08-05) : l'existence
d'une entrée `docsearch:auth:user:<login>` est le discriminant, un seul fournisseur est
sollicité par tentative, et il n'y a **aucun repli** de l'un vers l'autre — sans quoi un
annuaire en panne afficherait « identifiants incorrects » à quelqu'un dont les
identifiants sont parfaitement valides.

### 1.2 Les jetons

RS256 avec `kid` dès le départ, `GET /auth/.well-known/jwks.json` au format JWKS
(RFC 7517) structuré en liste pour accueillir une rotation future. Clés générées par un
`scripts/generer-cles.py`, stockées **hors du dépôt**, montées en lecture seule par
l'unité Quadlet — même régime que les secrets déjà en place.

```jsonc
// access token — TTL 15 min
{
  "iss": "docsearch-api", "aud": "docsearch",
  "sub": "alice.admin",        // identifiant annuaire canonique (minuscules)
  "iat": …, "nbf": …, "exp": …, "jti": "…",
  "token_type": "access",
  "auth_method": "ldap",       // "ldap" | "local" | "kerberos" — INFORMATIF, journalisation
  "name": "Alice Admin", "email": "alice.admin@…"
}
```

**Écart assumé avec Charlie : `sub` est l'identifiant annuaire, pas un `users.id`.**
Charlie a une table `users` et des rôles applicatifs (`group_roles`) qui exigent une clé
interne stable. DocSearch n'a ni table d'utilisateurs ni rôles — deux groupes annuaire
(`ACCESS_GROUP`, `ADMIN_GROUP`) et des données personnelles déjà indexées par login dans
Redis et Elasticsearch (recherches enregistrées, collections, alertes, journaux). Y
introduire un identifiant interne obligerait à migrer toutes ces clés pour n'acheter
aucune propriété. L'invariant 3 (forme canonique unique) est ce qui joue ici le rôle que
`users.id` joue là-bas.

**Pas de claim `groups`.** Une seule source pour les groupes,
`directory.get_effective_groups()`, parce que le worker d'alertes doit pouvoir la
solliciter sans session (§0.2). Un claim `groups` serait une seconde source, périmée dès
qu'un compte change de groupe, et l'une des deux finirait par être lue là où l'autre était
attendue.

Refresh : TTL 7 jours, contenu volontairement minimal, valide **seulement** s'il existe
aussi en Redis — un jeton correctement signé mais absent (déconnexion, révocation) est
refusé.

### 1.3 Les routes

| Méthode | Chemin | Rôle |
|---|---|---|
| `POST` | `/auth/login` | `{identifiant, mot_de_passe}` → cookies + `{user, display_name, is_admin}` |
| `GET` | `/auth/login/kerberos` | §2 |
| `POST` | `/auth/refresh` | rejoue le cookie de refresh, ré-émet l'access |
| `POST` | `/auth/logout` | révoque le refresh en Redis, efface les cookies |
| `GET` | `/auth/me` | identité + groupes + `is_admin` |
| `GET` | `/auth/check-access` | **inchangé pour nginx** — alimenté par le cookie |
| `GET` | `/auth/check-admin` | idem |
| `GET` | `/auth/.well-known/jwks.json` | clé publique |

Les deux `check-*` gardent leur contrat HTTP actuel (seul le code compte, 200/401/403) :
la configuration nginx du conteneur `ui-vue` ne change que sur un point, relayer le cookie
au lieu de `X-User`.

Un point de passage unique — `_finaliser_connexion()` — pour tout chemin aboutissant à une
session, quel que soit le fournisseur. C'est ce qui rendra le SSO du §2 additif plutôt
qu'invasif, et c'est exactement ce que Charlie a retiré de la sienne.

### 1.4 La bascule des 55 points d'appel

`x_user: str | None = Header(default=None)` + `resolve_user(x_user)` devient
`user: str = Depends(current_user)`. Mécanique, sans exception, et **à faire d'un coup** :
un point d'appel oublié est un point d'appel qui continue de croire un en-tête.

`current_user()` lit le cookie, valide signature/`iss`/`aud`/`exp`, et rend le login. En
dehors de la production, et seulement là, elle accepte le repli `X-User` puis `DEV_USER` —
ce qui préserve intégralement les trois méthodes de
[HOWTO-simuler-utilisateur.md](HOWTO-simuler-utilisateur.md), proxy `dev-user` compris.

`require_admin` / `require_access` gardent leur nom, leur sémantique et leurs messages ;
seule leur source d'identité change. `is_admin()` (version non levante, pour l'affichage
des liens) suit.

### 1.5 Le journal des connexions

Nouvel index ES `login_events`, sur le motif de
[`audit_log.py`](../docsearch-api/app/audit_log.py) et `search_log.py` (index dédié,
pagination native). Écrit sur **chaque** branche de sortie, pas seulement le succès :
rate limit dépassé, échec d'authentification, fournisseur indisponible, succès. Champs :
`timestamp`, `identifiant_tenté`, `resultat`, `methode` (`ldap`/`local`/`kerberos`), `ip`,
`user_agent`. **Le mot de passe ne transite jamais dans ce payload, sous aucune forme** —
avec le test qui le vérifie, comme chez Charlie.

Le panneau d'administration a déjà tout ce qu'il faut pour l'afficher (les écrans de
`/admin/search-logs` et du journal d'audit servent de modèle).

### 1.6 Le rate limiting

Redis, deux compteurs par tentative (par identifiant et par IP), 5 essais / 15 min par
défaut, indexés sur le **fournisseur réellement sollicité** et non sur la route appelée.

### 1.7 Le front

- **Nouvelle page `connexion.html`** (7ᵉ entrée du build multi-pages), **publique** — le
  seul `location` sans `auth_request`.
  ⚠️ Rappel de collision de préfixes : les fichiers servis par le conteneur `ui-vue` ne
  doivent pas commencer par un préfixe déjà proxifié (`/search`, `/admin`, `/ask`,
  `/alerts`, `/collections`, `/document`…). `/connexion` est libre ; `/login` le serait
  aussi mais `/auth/*` ne l'est pas.
- **`error_page 401 = /connexion?next=$request_uri`** dans le nginx `ui-vue`, pour que
  l'échec d'`auth_request` mène au formulaire plutôt qu'à une page blanche.
- **Un bouton « Se déconnecter »** dans l'en-tête, à côté de l'identité déjà affichée
  (`/is-admin` rend déjà `user` et `groups`).
- Sur 401 en cours de navigation, `api()` dans
  [`client.ts`](../docsearch-ui-vue/src/api/client.ts) tente **une** fois
  `POST /auth/refresh` puis rejoue ; second échec ⇒ redirection vers `/connexion`. Un seul
  endroit à modifier, `ApiError` portant déjà le statut.

### 1.8 nginx

- Retirer les huit blocs `auth_request` commentés et la `location /auth/validate` de
  [nginx.conf](nginx/nginx.conf) : ils décrivent une architecture qui n'aura pas lieu.
  Le proxy d'entrée redevient ce qu'il est — TLS, limitation de débit, routage.
- **Supprimer `proxy_set_header X-User $http_x_user;`** des deux sous-requêtes internes du
  nginx `ui-vue` et relayer `Cookie` à la place. C'est cette ligne qui, aujourd'hui, fait
  de n'importe quel en-tête client une identité.
- Ajouter `location = /connexion` et `location = /connexion.html` sans `auth_request`.

---

## §2. Lot 2 — SSO Kerberos/SPNEGO

Le code de `auth/kerberos.py` est **déjà écrit et éprouvé** dans
[`charlie/app-api-auth/app/auth_providers/kerberos.py`](../../charlie/app-api-auth/app/auth_providers/kerberos.py)
(302 lignes, quatre décisions documentées dans ses docstrings). Il se transpose presque
sans modification — seuls changent l'import de l'annuaire et le retour, qui devient un
identifiant plutôt qu'un `ResolvedIdentity` vers une table `users`. **Ne pas le réécrire :
le relire, y compris les commentaires, qui portent des arbitrages trouvés par l'échec.**

### 2.1 La route et le dialogue

`GET /auth/login/kerberos` — un `GET`, parce que le navigateur le rejoue seul et qu'un
corps de requête ne survit pas au rejeu d'un défi HTTP.

| Situation | Réponse |
|---|---|
| Réglage `sso_kerberos` désactivé | `501` |
| Pas d'en-tête `Authorization` | `401` + `WWW-Authenticate: Negotiate` (le défi) |
| Ticket invalide / realm refusé | `401` **sans** `WWW-Authenticate` — redéfier ferait boucler le navigateur |
| Keytab absent, `gssapi` absente, annuaire injoignable | `503` — une panne franche, jamais « identifiants incorrects », sans quoi personne ne diagnostique un keytab manquant |
| Ticket valide | `200` + cookies, par le même `_finaliser_connexion()` que le formulaire |

Quatre points portés par le code de Charlie, à ne pas défaire : import de `gssapi` tardif
et protégé ; **une seule passe** de négociation (aucune affinité de connexion derrière
nginx) ; **NTLM refusé**, vérifié sur le mécanisme réellement négocié *après* complétion du
contexte ; contrôle du keytab **avant** l'import de `gssapi`, ordre trouvé par un test.

Deux étages de rate limiting, à clés différentes : avant acceptation seule l'IP est
imputable, après le principal l'est. Ne jamais utiliser de clé constante au premier étage —
un seul poste mal configuré bloquerait toute l'installation.

### 2.2 Du principal à l'identifiant

`identifier_from_principal(principal, realm=…)` — fonction **pure**, donc testable seule,
et c'est elle qui décide qui entre. Trois refus : realm différent de `KERBEROS_REALM`
(comparaison **sensible à la casse**, RFC 4120 §6.1 — sans ce contrôle, une relation
d'approbation entre domaines laisserait entrer `alice@AUTRE-REALM` sous l'identité de
`alice`), principal à plusieurs composants (`HTTP/hôte@REALM`, `alice/admin@REALM`),
identifiant vide. Realm non configuré ⇒ 503, pas 401.

Puis recherche annuaire par bind technique, sans aucune vérification de mot de passe : il
n'y a rien à vérifier, le ticket l'a déjà fait. **Un principal valide dont l'annuaire ne
connaît pas le porteur est un échec (401)**, jamais une identité provisionnée à l'aveugle
— et il reste ensuite soumis à `ACCESS_GROUP` comme tout le monde.

Application directe de l'invariant 3 : le principal donne l'identifiant, mis en minuscules,
qui est celui-là même sous lequel les recherches enregistrées de la personne sont stockées.

### 2.3 Le réglage

`sso_kerberos = {enabled, …}` dans la configuration runtime Redis
([`runtime_config.py`](../docsearch-api/app/runtime_config.py) — clé unique en JSON, cache
local, fusion clé par clé avec les défauts : **aucune migration**, une clé nouvelle hérite
de son défaut sans écriture). **Désactivé par défaut** : sans interrupteur serveur, un
déploiement sans keytab répondrait un défi que personne ne peut relever, à chaque
chargement de page.

Interrupteur dans le panneau d'administration, section Sécurité. Charlie a manqué ce point
dans son plan initial — le réglage n'était activable par personne sans passer par la base à
la main.

Ce réglage est aussi ce qui **dispense le front de toute configuration** : la tentative SSO
*est* la découverte. `501` = éteint, `401` non relevé = navigateur non configuré, les deux
se replient sur le formulaire. Pas d'endpoint de capacités à interroger d'abord.

### 2.4 Le front

Sur `connexion.html`, au montage : tentative `fetch('/auth/login/kerberos', {credentials:
'same-origin'})`, toute erreur avalée, repli silencieux sur le formulaire.

- **Le garde-fou anti-boucle est non négociable et s'écrit en même temps que la tentative,
  pas après.** Sans lui, qui se déconnecte est reconnecté au rechargement suivant et ne
  peut plus jamais atteindre le formulaire ni changer de compte. `logout()` pose un
  marqueur en `sessionStorage`, la tentative refuse de s'exécuter tant qu'il est là, et la
  portée « onglet » fait que le SSO reprend à la prochaine ouverture.
- **Bouton de rattrapage** « Se connecter avec ma session Windows », qui rejoue la
  tentative en ignorant le marqueur — pour se reconnecter après déconnexion, et pour
  diagnostiquer un poste dont on ne sait pas s'il est configuré. Masqué si la réponse était
  `501`.
- **Mémoriser le `501` pour la durée de l'onglet**, pour ne sonder qu'une fois au lieu
  d'ajouter une requête à chaque chargement sur toute installation sans SSO.

La MFA de Charlie n'existant pas ici, le piège qui l'a rattrapé (SSO interrompu par un
écran de MFA inexistant) est sans objet.

### 2.5 Les trois pièges de déploiement

Ce sont eux qui décident du succès, pas le code. Aucun n'est contournable.

**a) Le SPN se dérive de l'URL — donc l'IP est bloquante.** Le navigateur construit
`HTTP/<nom d'hôte de l'URL>`. Sur `https://192.168.56.101:8090/` — l'URL de recette
d'aujourd'hui — il n'y a pas de nom, et ni Chrome ni Firefox ne tentent Negotiate contre
une IP littérale. Il faut donc, **avant toute autre chose** : un FQDN, un enregistrement
DNS, un keytab `HTTP/<fqdn>@REALM`, et un certificat TLS émis pour ce même nom.
Conséquence directe sur le `server_name docsearch.local;` de [nginx.conf](nginx/nginx.conf)
et sur les certificats de dev.

**b) Aucun navigateur n'envoie de ticket spontanément.** Firefox exige
`network.negotiate-auth.trusted-uris`, Chrome/Edge la stratégie `AuthServerAllowlist`
(GPO). Déploiement de parc, pas du code — et sans lui le SSO ne fonctionnera jamais, quelle
que soit la qualité du reste. À documenter au même titre que les prérequis Podman.

**c) La taille des en-têtes — le piège le plus coûteux à diagnostiquer.** Un ticket AD
transporte le PAC, donc tous les SID de groupes du compte : sur un utilisateur à nombreux
groupes, `Authorization: Negotiate` dépasse couramment 8 Ko. nginx répond alors `400
Request Header Or Cookie Too Large` et uvicorn coupe la connexion — **sans rien journaliser
d'explicite ni l'un ni l'autre**. Deux étages plafonnent la même chose et **le plus bas
gagne** : les relever ensemble ou ne rien relever.

```nginx
# dans le bloc `server` — l'analyse des en-têtes précède le choix du `location`.
# À poser dans LES DEUX nginx : docsearch-infra/nginx/nginx.conf ET
# docsearch-ui-vue/nginx.conf (la sous-requête auth_request rejoue les en-têtes).
large_client_header_buffers 8 32k;
```

et côté uvicorn, `--h11-max-incomplete-event-size 65536` — dans le `Exec=` de
[`docsearch-api.container`](quadlet/dev/docsearch-api.container), **et** dans le `CMD` du
`Dockerfile`, sans quoi le réglage disparaît selon la façon dont le conteneur est lancé.

*Ne pas ajouter `proxy_buffer_size` / `proxy_buffers` :* ces directives concernent la
**réponse**, pas la requête — et `proxy_buffer_size` posé seul fait **refuser nginx de
démarrer** (`proxy_busy_buffers_size` vaut le double par défaut et doit rester sous « tous
les `proxy_buffers` moins un »). C'est arrivé chez Charlie ; leur mesure : aux défauts,
un en-tête de 4 Ko passe et 16 Ko donne un 400 ; avec le réglage, 30 Ko passent.

Un dernier point invisible : **l'en-tête `Authorization` traverse par défaut**. Un
`proxy_pass_request_headers off;` ajouté « pour faire propre » couperait la connexion
automatique sans autre symptôme qu'un 401. À commenter dans les deux configurations.

### 2.6 L'image et le keytab

**Image.** `gssapi` compile contre `libkrb5-dev`/`krb5-config` : installer `gcc`,
`libkrb5-dev` **et les purger dans la même couche**, en gardant `libgssapi-krb5-2`
(exécution) et `krb5-user` (pour un `klist -k` de diagnostic dans le conteneur). L'image
est en `python:3.12-slim`, donc les roues manquantes en 3.14 ne se posent pas.

**La contrainte hors ligne ne s'y oppose pas**, mais mérite d'être dite : le build a lieu
sur une machine connectée, l'image part ensuite par `podman save`/`load` (voir
[HOWTO-deploiement-hors-ligne.md](HOWTO-deploiement-hors-ligne.md)). Rien de nouveau au
runtime — `gssapi` parle au KDC du domaine, qui est sur l'intranet. C'est même l'argument
qui rend Kerberos préférable à tout OIDC ici : aucune dépendance sortante.

`gssapi` ne s'installera **pas** dans un venv de l'hôte de dev — d'où l'import tardif et
protégé du §2.1, qui garde le reste du module (et la moitié de ses tests) importable.

**Keytab.** Jamais dans l'image, jamais dans le dépôt : hors-repo sur l'hôte
(`/etc/docsearch/krb5/docsearch.keytab`), monté en lecture seule au **même chemin absolu**
qu'en dev, chemin déclaré dans `KERBEROS_KEYTAB` et passé à GSSAPI par *credential store*
— jamais par la variable d'environnement `KRB5_KTNAME`, qui est un état global du processus
que n'importe quoi d'autre peut lire ou écraser. `KERBEROS_SPN` restreint le principal
accepté. Un `krb5.conf` minimal (realm + KDC) monté de même.

Deux vigilances propres à **Podman rootless**, toutes deux déjà rencontrées sur cette VM :
les permissions `0600` du keytab sont interprétées avec l'UID **mappé** dans le conteneur
(même piège que `PGDATA` chowné hors plage subuid) ; et le **cache de rejeu** GSSAPI est un
fichier `/tmp` non partagé entre processus — sans effet tant qu'uvicorn tourne en un seul
worker, ce qui est le cas, mais à noter le jour où il en aura plusieurs.

**Rotation** : renouveler le keytab = changer le mot de passe du compte de service côté AD,
ce qui invalide l'ancien. Opération d'exploitation, avec sa fenêtre de coupure.

---

## §3. Ce qui ne se transpose pas, et pourquoi

À dire d'emblée, sinon la question reviendra à chaque relecture du plan.

| Fonction de Charlie | Ici | Motif |
|---|---|---|
| MFA par email | **non** | Aucun SMTP dans DocSearch. Et pour une application intranet dont l'accès est déjà borné par un groupe annuaire, le second facteur emprunterait le même canal que le premier |
| Réinitialisation de mot de passe par email | **non** | Idem. Les mots de passe sont détenus par l'annuaire ; un compte de secours se recrée par script |
| Expiration des mots de passe | **non** | Ne vise que les comptes locaux, qui sont ici quelques comptes de secours administrés à la main |
| Inscription / demandes de compte | **non** | L'appartenance à `ACCESS_GROUP` *est* la demande de compte |
| ProConnect | **non** | Fédération OIDC : impossible en production déconnectée |
| Table `users`, `group_roles`, rôles applicatifs | **non** | Ni table d'utilisateurs ni rôles ; deux groupes annuaire suffisent (§1.2) |
| Provisionnement de groupes au login | **non** | Les groupes sont lus, jamais écrits |

Ce qui reste — fournisseurs, jetons, sessions révocables, rate limiting, journal des
connexions, SSO — est le cœur, et c'est ce qui rend l'authentification « identique à
Charlie » au sens qui compte.

---

## §4. Ordre de mise en œuvre

| # | Lot | Contenu | Dépend de l'infra ? |
|---|---|---|---|
| 1 | **Infra** | FQDN + DNS, compte de service AD, `setspn HTTP/<fqdn>`, keytab, certificat au même nom | **oui** — à lancer en premier parce que c'est le plus long à obtenir, pas parce que ça bloque |
| 2 | **Lot 0** | `directory.py`, garde-fous, harnais pytest + CI | non |
| 3 | **Lot 1 back** | fournisseurs, jetons, sessions, rate limiting, `login_events`, routes, bascule des 55 points d'appel | non |
| 4 | **Lot 1 front + nginx** | `connexion.html`, `error_page 401`, relais du cookie, déconnexion, refresh transparent | non |
| 5 | **Lot 2 back** | `kerberos.py`, route, réglage, image, tampons d'en-têtes | non — grâce au harnais du §5 |
| 6 | **Lot 2 front** | tentative, garde-fou anti-boucle, bouton de rattrapage, interrupteur admin | non |
| 7 | **Parc** | stratégie navigateur (§2.5b), documentation dans les HOWTO | **oui** |

Le chantier se coupe donc en deux moitiés dont **une seule dépend de l'infra Kerberos**,
et c'est le harnais `KERBEROS_DEV_PRINCIPAL` (§5) qui permet cette coupe. Elle vaut la
peine : elle décorrèle tout le travail applicatif du délai d'obtention d'un compte de
service et d'un SPN. Charlie a mené sa moitié applicative entière sans KDC.

Les lots 2 → 4 forment un tout déployable : à leur issue, DocSearch a une authentification
réelle, avec formulaire, sans SSO. C'est déjà l'essentiel du gain de sécurité.

---

## §5. Vérification

### Le harnais sans KDC, à monter en premier

Un `KERBEROS_DEV_PRINCIPAL` qui court-circuite **la seule** acceptation GSSAPI et retourne
le principal configuré. Il débloque tout le reste sans KDC, sans keytab et sans FQDN :
mapping principal→identifiant, résolution vers les données existantes de la personne,
réglage éteint ⇒ 501, tentative front, garde-fou anti-boucle, bouton de rattrapage,
enchaînement complet jusqu'à la session ouverte. Seule reste hors de portée l'acceptation
du ticket elle-même.

Trois garde-fous, non négociables : effet **seulement** si `API_ENV != "production"` (un
déploiement de prod **refuse de démarrer** plutôt que d'ignorer le réglage), encadré
d'avertissement au démarrage **et** ligne de log à chaque connexion ainsi ouverte, et
`login_events` marqué comme tel pour qu'aucune trace d'audit ne puisse laisser croire à une
vraie connexion Kerberos.

Le proxy `docsearch-dev-user-proxy` (port 8090, `sudo ./manage.sh dev-user <login>`) reste
en place et garde son rôle pour tout ce qui n'est pas l'authentification.

### Sans navigateur d'abord — c'est ce qui isole le serveur du poste client

**Le test qui compte le plus, et qui échoue aujourd'hui :**

```bash
curl -H "X-User: alice.admin" http://192.168.56.101:8000/admin/status
```

`200` aujourd'hui, doit répondre `401` à l'issue du lot 1. C'est la mesure de tout ce
chantier.

Puis : login formulaire (LDAP et compte de secours) → cookie posé → appel authentifié →
`/auth/refresh` → `/auth/logout` → refresh révoqué rejeté ; identifiant inconnu et mot de
passe faux donnent le **même** 401 générique ; annuaire arrêté donne un 503 et non un 401 ;
6 tentatives donnent un 429.

Enfin, avec un vrai KDC :

```bash
kinit alice@REALM.EXEMPLE
curl -k --negotiate -u : -v https://docsearch.<domaine>/auth/login/kerberos
```

`401` + `WWW-Authenticate: Negotiate`, puis rejeu, puis `200` portant les cookies. Si ça
marche ici et pas dans le navigateur, le problème est la liste de confiance (§2.5b), jamais
le code.

### Au navigateur

Rappels de la VM : le proxy de recette est sur `192.168.56.101:8090`, jamais `localhost` ;
toute modification back exige `./manage.sh build api` puis redémarrage de l'unité (sinon
les routes nouvelles répondent 404) ; toute modification front exige la reconstruction du
conteneur `ui-vue`.

Les quatre cas, dans cet ordre de valeur : session domaine (connexion transparente), poste
hors domaine (formulaire, sans latence perceptible), **déconnexion suivie d'un
rechargement — on reste sur le formulaire** (le garde-fou), compte de secours (formulaire,
annuaire arrêté, accès et administration toujours possibles).

### Tests automatisés

Le piège est d'écrire des tests qui ne testent que des mocks. Découper :

- **sans KDC ni annuaire** — mapping principal→identifiant (realm étranger refusé,
  principal multi-composant refusé, casse), signature/`kid`/JWKS, refus d'un refresh absent
  de Redis, refus d'un jeton expiré, forme canonique de l'identifiant, `X-User` ignoré hors
  dev, réglage éteint ⇒ 501, absence d'en-tête ⇒ 401 + défi, `login_events` sans mot de
  passe ;
- **contre l'annuaire de dev** (`requires_ldap`, *skip* propre s'il est injoignable) —
  login LDAP de bout en bout, groupes effectifs, `escape_filter_chars` sur un identifiant
  hostile ;
- **contre Redis réel** — rate limiting, révocation ;
- **exigeant un vrai KDC** — l'acceptation GSSAPI elle-même, marqueur `requires_kerberos`.
  À monter une fois, pas à simuler. À noter : une partie s'éprouve quand même sans KDC —
  avec un keytab *vide*, `gssapi` est réellement sollicitée et rend une vraie `GSSError`,
  ce qui prouve que la bibliothèque est câblée et que son refus devient bien une
  indisponibilité.

---

## À trancher, ou à demander à l'exploitation

1. **FQDN, realm, compte de service, SPN, keytab, certificat** *(entier)*. À demander en
   premier : le plus long à obtenir, et le certificat de recette en dépend (§2.5a).
2. **KDC de test** *(entier)*. Il n'y en a **aucun** sur cette VM — l'annuaire de dev
   (`~/ldap-test-stack`, OpenLDAP) n'a pas de Kerberos et `kinit` n'y est pas installé.
   Deux options : un KDC MIT jetable en conteneur, ou l'AD cible directement — plus fidèle,
   mais suppose un interlocuteur côté exploitation. Le harnais du §5 permet de différer ce
   choix, pas de s'en passer.
3. **Stratégie de parc navigateur** (§2.5b) : qui la pousse, sur quel périmètre.
4. **Comptes de secours** : combien, qui les crée, où sont conservés les hachages hors
   Redis pour la reconstruction, et quels groupes on leur attribue.
5. **`SameSite=Strict` ou `Lax`** : `Strict` est le bon défaut, mais casse l'arrivée sur
   DocSearch depuis un lien collé dans un mail ou un intranet — la première requête part
   sans cookie et renvoie au formulaire. À trancher sur l'usage réel.
   *(`COOKIE_SECURE`, la question voisine, est **tranchée** le 2026-08-06 : `false` sur la
   VM de développement, dont la recette se fait en clair sur le port 8090 ; `true` dans le
   modèle de production, servie en HTTPS. L'API avertit désormais quand les deux ne
   s'accordent pas — le symptôme, sinon, est une connexion qui réussit puis une page qui
   renvoie au formulaire, sans rien dans les journaux.)*
6. **Durée de vie de session** : 15 min d'access / 7 jours de refresh sont les valeurs de
   Charlie. Une application de recherche consultée toute la journée supporterait un refresh
   plus court ou une inactivité maximale.
