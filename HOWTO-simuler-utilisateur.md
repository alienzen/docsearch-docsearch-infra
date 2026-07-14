# HOWTO — Simuler un utilisateur connecté

DocSearch identifie l'utilisateur via le header HTTP `X-User`, normalement
injecté par Nginx après validation SSO (voir `nginx/nginx.conf`). En
développement/test, sans SSO, il faut fournir ce header soi-même. Trois
méthodes, du plus simple au plus proche de la navigation réelle.

## Utilisateurs de test disponibles

Fournis par la stack `~/ldap-test-stack` (base `dc=docsearch,dc=test`,
voir `bootstrap-ldifs/03-users.ldif`) :

| Utilisateur    | Mot de passe  | Groupes                                |
|----------------|---------------|------------------------------------------|
| `alice.admin`  | `testpass123` | `docsearch-admins`, `docsearch-users`  |
| `bob.user`     | `testpass123` | `docsearch-users`                      |

Seul `alice.admin` a accès au panneau `/admin.html` (`ADMIN_GROUP=docsearch-admins`).

## 1. curl / Postman / httpie (tester l'API directement)

Le plus simple, pas d'installation :

```bash
curl -H "X-User: alice.admin" http://localhost:8000/admin/status
curl -H "X-User: bob.user"    http://localhost:8000/admin/status   # → 403
```

Fonctionne aussi via l'UI (port 8080), qui relaie le header tel quel
vers l'API sans le modifier (voir `docsearch-ui/nginx.conf:145`).

## 2. Proxy de test local (naviguer au navigateur, sans extension)

Un service Nginx dédié (`docker-compose.dev-user-proxy.yml`) injecte
`X-User` sur toutes les requêtes vers `ui` — reproduit ce que fait Nginx
en prod après SSO, mais avec une identité fixe. Évite toute dépendance à
une extension de navigateur (ModHeader a été retiré du Chrome Web Store
et d'Edge début juillet 2026 pour collecte de données non consentie —
voir les alternatives ci-dessous si besoin d'un outil plus flexible).

```bash
cd docsearch-infra

# Démarrer (utilisateur par défaut : alice.admin)
docker compose -f docker-compose.dev-user-proxy.yml up -d

# Changer d'utilisateur simulé
TEST_X_USER=bob.user docker compose -f docker-compose.dev-user-proxy.yml up -d --force-recreate

# Arrêter
docker compose -f docker-compose.dev-user-proxy.yml down
```

Puis naviguer sur `http://192.168.56.101:8090/` (ou `http://localhost:8090/`
si le navigateur tourne sur la même machine que Docker).

⚠️ Ce conteneur est **partagé** : changer `TEST_X_USER` change l'identité
pour toute session déjà ouverte sur le port 8090, pas seulement la vôtre.
Aucune authentification réelle — réservé au réseau de test isolé
(`192.168.56.0/24`), jamais à exposer au-delà.

## 3. Extension navigateur (si le proxy local ne suffit pas)

Utile pour alterner rapidement entre plusieurs headers/valeurs sans
recréer de conteneur. Éviter ModHeader (retiré des stores, voir plus
haut) ; alternatives open source réputées :
[Header Editor](https://github.com/FirefoxBar/HeaderEditor) (simple) ou
[Requestly](https://requestly.com/) (plus complet). Vérifier les
permissions demandées avant d'installer.

## À savoir : `DEV_USER` ne couvre pas tout

`.env` contient une variable `DEV_USER` qui simule un utilisateur — mais
uniquement pour `resolve_user()` (recherche, ACL, collections...), voir
`docsearch-api/app/search_api.py:233`. Le panneau admin
(`require_admin`, `docsearch-api/app/admin_auth.py:39`) exige le header
`X-User` explicitement et ne consulte jamais `DEV_USER`. Pour tester
`/admin/*`, une des trois méthodes ci-dessus est nécessaire.
