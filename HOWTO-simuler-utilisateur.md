# HOWTO — Se connecter, et simuler un utilisateur en recette

**Ce qui a changé (2026-08-06).** DocSearch identifiait l'utilisateur par
l'en-tête HTTP `X-User`, censé être injecté par Nginx après validation
SSO. Le SSO n'a jamais été branché (les blocs `auth_request` de
`nginx/nginx.conf` étaient commentés), et l'API publiant son port,
n'importe qui pouvait poser cet en-tête lui-même :

```bash
curl -H "X-User: alice.admin" http://192.168.56.101:8000/admin/status   # → 200 avant
curl -H "X-User: alice.admin" http://192.168.56.101:8000/admin/status   # → 401 désormais
```

L'identité vient maintenant d'un **jeton de session signé par
l'application**, posé en cookie `httpOnly` par `/auth/login`. L'en-tête
`X-User` n'est plus qu'un **harnais de développement**, explicitement
armé, et refusé en production.

## Utilisateurs de test disponibles

Fournis par la stack `~/ldap-test-stack` (base `dc=docsearch,dc=test`,
voir `bootstrap-ldifs/03-users.ldif`) :

| Utilisateur    | Groupes                               |
|----------------|---------------------------------------|
| `alice.admin`  | `docsearch-admins`, `docsearch-users` |
| `bob.user`     | `docsearch-users`                     |

(Mot de passe : voir `userPassword` dans `bootstrap-ldifs/03-users.ldif`,
pas reproduit ici.)

Seul `alice.admin` a accès au panneau `/admin.html`
(`ADMIN_GROUP=docsearch-admins`).

---

## 0. La vraie connexion — à préférer à tout le reste

C'est désormais le chemin normal, y compris en développement, et il ne
demande aucune configuration particulière : ouvrir
`http://192.168.56.101:8090/`, se laisser rediriger vers `/connexion`,
saisir un identifiant de l'annuaire de dev.

En ligne de commande, le cookie se garde dans un bocal :

```bash
curl -c bocal.txt -X POST http://192.168.56.101:8000/auth/login \
     -H "Content-Type: application/json" \
     -d '{"identifiant":"alice.admin","mot_de_passe":"…"}'

curl -b bocal.txt http://192.168.56.101:8000/admin/status
```

**Prérequis, une seule fois :** les clés de signature doivent exister,
sinon `/auth/login` répond `503` :

```bash
sudo install -d -o 1000 -g 1000 -m 700 /etc/docsearch/jwt
sudo podman run --rm -v /etc/docsearch/jwt:/etc/docsearch/jwt:Z \
     localhost/docsearch/api:latest python scripts/generer-cles.py
```

⚠️ Un conteneur **jetable**, et non `podman exec` dans le conteneur qui
tourne : l'unité monte `/etc/docsearch/jwt` en **lecture seule** (c'est
voulu — le service signe avec ces clés, il n'a aucune raison de pouvoir
les réécrire), un `podman exec` échouerait donc sur un système de
fichiers en lecture seule. Le `install -d -o 1000` donne le dossier à
l'UID de l'utilisateur *dans* le conteneur : root-owned, les clés
seraient générées puis illisibles par le service.

La commande affiche les trois lignes (`JWT_ACTIVE_KID`,
`JWT_PRIVATE_KEY_PATH`, `JWT_PUBLIC_KEY_PATH`) à reporter dans
`/etc/docsearch/docsearch.env`, puis `sudo systemctl restart docsearch-api`.

---

### `COOKIE_SECURE` — false ici, true en production (arbitré le 2026-08-06)

Le port 8090 est en **clair**. Un cookie `Secure` n'y serait jamais
renvoyé par le navigateur : la connexion réussirait, puis chaque page
ramènerait au formulaire — symptôme muet qu'on prend volontiers pour un
échec d'authentification ou un bug du front.

`/etc/docsearch/docsearch.env` porte donc `COOKIE_SECURE=false` sur cette
VM, tandis que `quadlet/common/docsearch.env.example` — le modèle des
installations de production, servies en HTTPS — livre `true`. Ne pas
aligner l'un sur l'autre « par cohérence » : ce sont deux réglages
corrects pour deux modes d'accès différents.

L'API avertit d'elle-même en cas d'incohérence, une fois par démarrage :

```
[auth] COOKIE_SECURE=true mais cette requête est arrivée en http : le
navigateur ACCEPTERA la connexion puis refusera de renvoyer le cookie…
```

Derrière le reverse-proxy TLS, c'est `X-Forwarded-Proto` qui fait foi —
l'API voit du HTTP en interne alors que le navigateur est bien en HTTPS.

---

## 1. Proxy de test local (naviguer sans saisir de mot de passe)

Un Nginx dédié (unité `docsearch-dev-user-proxy`, port **8090**) injecte
`X-User` sur toutes les requêtes vers l'interface — reproduit ce que
faisait le proxy de production, avec une identité fixe.

**Il ne fonctionne plus tout seul :** l'API ignore désormais cet en-tête
sauf si elle a été démarrée avec le harnais correspondant. Dans
`/etc/docsearch/docsearch.env` :

```
API_ENV=development
TRUST_X_USER_HEADER=true
```

puis `sudo systemctl restart docsearch-api`. Avec `API_ENV=production`,
l'API **refuse de démarrer** plutôt que d'ignorer ce drapeau — c'est
voulu, et c'est ce qui garantit qu'un oubli ne suit pas l'image jusqu'en
production.

```bash
cd docsearch-infra

# Démarrer, ou changer d'utilisateur simulé (régénère la conf et redémarre)
sudo ./manage.sh dev-user alice.admin
sudo ./manage.sh dev-user bob.user

# Arrêter
sudo systemctl stop docsearch-dev-user-proxy
```

Puis naviguer sur `http://192.168.56.101:8090/` (ou
`http://localhost:8090/` si le navigateur tourne sur la même machine que
les conteneurs).

La substitution de l'identité se fait à l'écriture de
`/etc/docsearch/nginx/dev-user-proxy.conf`, pas au démarrage du
conteneur : une unité Quadlet ne peut pas porter proprement un `sh -c`
avec `sed` et guillemets imbriqués, contrairement à la commande Compose
qu'elle remplace.

⚠️ Ce conteneur est **partagé** : changer `TEST_X_USER` change l'identité
pour toute session déjà ouverte sur le port 8090, pas seulement la vôtre.
Aucune authentification réelle — réservé au réseau de test isolé
(`192.168.56.0/24`), jamais à exposer au-delà.

---

## 2. `DEV_USER` — identité par défaut, sans en-tête

`DEV_USER=alice.admin` donne cette identité à **toute** requête non
authentifiée, y compris `/admin/*`. Plus simple que le proxy quand on
teste l'API seule, et soumis au même verrou : sans effet si
`API_ENV=production`, où l'API refuse alors de démarrer.

À la différence du comportement d'avant, `DEV_USER` couvre désormais le
panneau d'administration comme le reste : c'est la **même** résolution
d'identité pour toutes les routes (`app/auth/deps.py`), il n'y a plus deux
chemins qui divergent.

---

## 3. Comptes de secours locaux — tester sans annuaire

Utile pour éprouver le comportement quand `~/ldap-test-stack` est arrêté,
qui est le cas pour lequel ces comptes existent :

```bash
podman exec -it docsearch-api python scripts/gerer-comptes-locaux.py creer \
    secours.admin --groupes docsearch-users,docsearch-admins

podman exec -it docsearch-api python scripts/gerer-comptes-locaux.py lister
```

Le mot de passe est demandé interactivement — jamais en argument, il
resterait dans l'historique du shell et dans la liste des processus.
⚠️ Les groupes sont obligatoires : l'annuaire étant en panne au moment où
ce compte sert, c'est la seule chose qui dira que son porteur a le droit
d'entrer.

Chaque connexion par compte local est journalisée en `WARNING` — en
période normale, elle mérite un coup d'œil.

---

## 4. SSO Kerberos sans KDC

Il n'y a **aucun KDC** sur cette VM. Le harnais
`KERBEROS_DEV_PRINCIPAL=alice.admin@DOCSEARCH.TEST` court-circuite la
seule acceptation du ticket : tout le reste du chemin (mapping
principal → identifiant, recherche annuaire, contrôle d'accès, cookies,
audit) est exercé pour de bon. Il faut en plus activer le réglage
`sso_kerberos_enabled` depuis le panneau d'administration
(*Paramètres opérationnels*), désactivé par défaut.

Mêmes verrous que les précédents, plus un : l'événement de connexion est
marqué `simulated` dans l'index `login_events`, pour qu'aucune trace
d'audit ne laisse croire à un vrai ticket.

---

## 5. Extension navigateur (si le proxy local ne suffit pas)

Utile pour alterner rapidement entre plusieurs en-têtes sans recréer de
conteneur — et suppose là aussi `TRUST_X_USER_HEADER=true`. Éviter
ModHeader (retiré du Chrome Web Store et d'Edge début juillet 2026 pour
collecte de données non consentie) ; alternatives open source réputées :
[Header Editor](https://github.com/FirefoxBar/HeaderEditor) (simple) ou
[Requestly](https://requestly.com/) (plus complet). Vérifier les
permissions demandées avant d'installer.

---

## Récapitulatif des verrous

| Variable                 | Ce qu'elle ouvre                                      |
|--------------------------|-------------------------------------------------------|
| `TRUST_X_USER_HEADER`    | l'identité par simple en-tête HTTP                    |
| `DEV_USER`               | une identité par défaut, sans rien présenter          |
| `KERBEROS_DEV_PRINCIPAL` | une session Kerberos sans le moindre ticket           |
| `ACCESS_AUTH_DISABLED`   | l'accès à toutes les pages sans contrôle de groupe    |
| `ADMIN_AUTH_DISABLED`    | le panneau d'administration sans contrôle de groupe   |

Avec `API_ENV=production`, **un seul de ces cinq suffit à empêcher l'API
de démarrer** (`app/auth/guardrails.py`). Le message d'erreur nomme la
variable en cause. Hors production, un encadré d'avertissement s'affiche
au démarrage et chaque usage laisse une ligne de log.
