# Authelia (SSO / 2FA)

Portail d'authentification centralisé, exposé **publiquement** sur **`auth.vindiesel.vip`**. Il protège
les services sensibles via **forward-auth Traefik** et servira de **fournisseur OIDC** (phase 2).
Backend d'utilisateurs : **lldap**. Envoi de mail : stack **smtp-relay** (→ Brevo).

Sources : `hosts/vps-prod/stacks/{authelia,lldap,smtp-relay}/`, `komodo/stacks.toml`,
`secrets/vps/{authelia,lldap,smtp-relay}.env`.

!!! info "Pourquoi le portail est **public** (et pas en `*.int` VPN-only)"
    La zone `*.int.vindiesel.vip` est réservée aux services VPN-only. Le portail Authelia, lui, reste
    **public** : le flux **OIDC de Forgejo** (service public sur `git.lucasmasse.net`) redirige les
    utilisateurs vers le portail — s'il était VPN-only, l'OIDC public serait cassé. Le cookie de
    session posé sur `vindiesel.vip` couvre malgré tout `komodo.int.vindiesel.vip` (correspondance par
    suffixe RFC 6265), donc le forward-auth VPN-only fonctionne quand même.

## Vue d'ensemble

| Élément | Choix | Source |
| --- | --- | --- |
| Portail | `auth.vindiesel.vip` (**public**, wildcard `*.vindiesel.vip`) | `authelia/compose.yaml` |
| Rôles | forward-auth Traefik **+** OIDC (phase 2) | `authelia/compose.yaml` |
| Backend | **lldap** (`ldap://lldap:3890`), base DN `dc=vindiesel,dc=vip` | `configuration.yaml` |
| Politique par défaut | `two_factor` (default_policy `deny`) | `configuration.yaml` |
| 2FA | TOTP + WebAuthn/Passkeys | `configuration.yaml` |
| Sessions | cookie sur `vindiesel.vip`, stockage mémoire | `configuration.yaml` |
| Stockage | SQLite local (`/data/db.sqlite3`) | `configuration.yaml` |
| Mail | relais interne `smtp-relay:587` → Brevo | `configuration.yaml`, `smtp-relay/compose.yaml` |

## Composants (3 stacks)

| Stack | Image | Rôle | Exposition |
| --- | --- | --- | --- |
| `authelia` | `authelia/authelia:4.39` | Portail + moteur d'autorisation | `auth.vindiesel.vip` (**public**) |
| `lldap` | `lldap/lldap:v0.6.1-alpine` | Annuaire LDAP + UI d'admin | `ldap.int.vindiesel.vip` (**VPN-only**) |
| `smtp-relay` | `boky/postfix:v4.3.0` | Relais Postfix → smarthost Brevo | interne uniquement (aucun port publié) |

Toutes partagent le réseau Docker externe **`frontend`** : Authelia joint lldap en `ldap://lldap:3890`
et le relais en `submission://smtp-relay:587`, sans publier ces ports sur l'hôte. Les certificats
(`*.vindiesel.vip`, `*.int.vindiesel.vip`) sont déjà émis par le routeur générateur
(voir [Reverse proxy & TLS](reverse-proxy-tls.md)) : **aucun `certresolver`** sur nos routeurs.

## Le middleware forward-auth

La stack `authelia` définit un middleware Traefik réutilisable **`authelia@docker`** :

```yaml
- "traefik.http.middlewares.authelia.forwardauth.address=http://authelia:9091/api/authz/forward-auth"
- "traefik.http.middlewares.authelia.forwardauth.trustForwardHeader=true"
- "traefik.http.middlewares.authelia.forwardauth.authResponseHeaders=Remote-User,Remote-Groups,Remote-Name,Remote-Email"
```

**Protéger un service** = ajouter `authelia@docker` à la liste `middlewares` de son routeur, et une
règle dans `access_control` de `configuration.yaml`. Exemple sur Komodo
(`hosts/vps-prod/stacks/komodo/compose.yaml`) :

```yaml
- "traefik.http.routers.komodo.middlewares=komodo-vpn,authelia@docker"
```

!!! note "Komodo : double verrou VPN + 2FA"
    Komodo (`komodo.int.vindiesel.vip`) garde son `ipAllowList` Tailscale (`komodo-vpn`) **et** ajoute
    `authelia@docker`. Il faut donc être sur le tailnet **et** s'authentifier en 2FA. Rappel : la zone
    `int` exige `userland-proxy: false` pour que l'`ipAllowList` voie la vraie IP source — cf.
    [Exposer un service en VPN-only](exposer-service-vpn-only.md).

## Chemins de données sur l'hôte (à créer avant déploiement)

| Chemin hôte | Monté dans | Service |
| --- | --- | --- |
| `/data/authelia` | `/data` | Authelia (base SQLite `db.sqlite3`) |
| `/data/lldap` | `/data` | lldap (base + config) |

```bash
sudo mkdir -p /data/authelia /data/lldap
```

## Secrets (déchiffrement automatique par Komodo)

Trois fichiers chiffrés SOPS/age (mêmes règles que le reste, cf. [Secrets](secrets-sops.md)) :

| Fichier | Variables |
| --- | --- |
| `secrets/vps/authelia.env` | `AUTHELIA_SESSION_SECRET`, `AUTHELIA_STORAGE_ENCRYPTION_KEY`, `AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET`, `AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD` |
| `secrets/vps/lldap.env` | `LLDAP_JWT_SECRET`, `LLDAP_KEY_SEED`, `LLDAP_LDAP_USER_PASS` |
| `secrets/vps/smtp-relay.env` | `RELAYHOST_USERNAME`, `RELAYHOST_PASSWORD` |

Contrairement au bootstrap manuel de Komodo, ces stacks utilisent le **`pre_deploy`** de
`komodo/stacks.toml` : à chaque déploiement, Komodo rend le `.env` de la stack avant `docker compose up`
(même mécanisme que les stacks Immich) :

```toml
[[stack]]
name = "authelia"
# ...
pre_deploy.path = "hosts/vps-prod/stacks/authelia"
pre_deploy.command = "sops -d ../../../../secrets/vps/authelia.env > .env"
```

Le compose consomme ce fichier via `env_file: .env` (ignoré par `.gitignore`). Pour Authelia, les
variables `AUTHELIA_*` **surchargent** la configuration YAML (les secrets ne sont donc jamais en clair
dans `configuration.yaml`).

!!! danger "Mot de passe admin = mot de passe de bind"
    `LLDAP_LDAP_USER_PASS` (mot de passe de l'admin lldap **Cassetout**) et
    `AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD` (mot de passe de bind d'Authelia) doivent être
    **identiques** : Authelia se connecte à lldap avec le compte admin pour rechercher les
    utilisateurs.

## DNS à créer chez Cloudflare (DNS-only)

Le wildcard `*.vindiesel.vip` et `*.int.vindiesel.vip` couvrent déjà les certificats — **aucun CNAME
`_acme-challenge` supplémentaire**. Il faut seulement les enregistrements d'adresse :

| Type | Nom | Valeur | Proxy |
| --- | --- | --- | --- |
| `A` | `auth.vindiesel.vip` | `116.202.22.50` (IP publique — le portail doit être joignable) | DNS-only |
| `A` | `ldap.int.vindiesel.vip` | `<IP Tailscale 100.x du VPS>` (UI d'admin VPN-only) | DNS-only |

## Déploiement (ordre)

1. Créer les dossiers de données (ci-dessus) et les enregistrements DNS.
2. Déployer via Komodo dans l'ordre **smtp-relay → lldap → authelia** (le `after` de `stacks.toml`
   gère l'ordre : `authelia` after `["traefik","lldap","smtp-relay"]`). Le `pre_deploy` rend les `.env`
   automatiquement.
3. **Brevo** : vérifier que l'expéditeur `lucasmasseh@outlook.com` est **validé** comme sender dans
   l'interface Brevo, sinon les mails sont rejetés.
4. Premier login : ouvrir `https://auth.vindiesel.vip`, se connecter avec **Cassetout** + le mot de
   passe admin, puis **enrôler un TOTP et/ou une passkey**.

**Vérifications :**

```bash
dig +short auth.vindiesel.vip            # -> 116.202.22.50
curl -I https://auth.vindiesel.vip       # 200, cert *.vindiesel.vip valide
docker logs authelia 2>&1 | grep -i ldap # bind lldap OK au démarrage
```

Accès à Komodo (`komodo.int.vindiesel.vip`, sur le VPN) : redirige désormais vers le portail Authelia
avant d'afficher l'UI.

## Gestion des utilisateurs

Les utilisateurs et groupes se gèrent dans l'**UI lldap** (`https://ldap.int.vindiesel.vip`,
VPN-only), pas dans Authelia. Un groupe `admins` peut ensuite servir de `subject: 'group:admins'` dans
des règles `access_control` plus fines.

!!! note "Casse du nom d'utilisateur"
    lldap traite les identifiants sans tenir compte de la casse ; le bind DN
    `uid=Cassetout,ou=people,dc=vindiesel,dc=vip` matche donc quelle que soit la casse stockée. Si un
    bind échoue au démarrage, essayer l'identifiant en minuscules.

## OIDC — Komodo se logue via Authelia

Komodo n'utilise **pas** son login intégré : il est client OIDC d'Authelia
([guide officiel](https://www.authelia.com/integration/openid-connect/clients/komodo/)).

- Client `komodo` déclaré dans `identity_providers.oidc` de `configuration.yaml` (secret client sous forme
  de **hash pbkdf2** ; le secret en clair est `KOMODO_OIDC_CLIENT_SECRET` dans `komodo.env`).
- Komodo : `KOMODO_OIDC_ENABLED=true`, `KOMODO_OIDC_PROVIDER=https://auth.vindiesel.vip`,
  `KOMODO_OIDC_CLIENT_ID/SECRET` (dans `komodo.env`). Callback `…/auth/oidc/callback`.
- `hmac_secret` OIDC → `AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET` (`authelia.env`).
- La route Komodo n'a **plus** `authelia@docker` (l'OIDC fait l'auth) — seulement `komodo-vpn`.

!!! danger "Clé de signature OIDC = fichier sur l'hôte (hors git), à sauvegarder"
    Authelia signe les jetons OIDC avec une clé RSA privée, montée depuis `/data/authelia/oidc-issuer.pem`
    (`AUTHELIA_IDENTITY_PROVIDERS_OIDC_JWKS_0_KEY_FILE=/data/oidc-issuer.pem`). Comme la clé age, elle
    **vit sur l'hôte**, pas dans le dépôt. `scripts/bootstrap.sh` la génère automatiquement (idempotent)
    en même temps que les dossiers de données ; à sauvegarder (Bitwarden). Génération manuelle si besoin :

    ```bash
    openssl genrsa -out /data/authelia/oidc-issuer.pem 4096
    chmod 600 /data/authelia/oidc-issuer.pem
    ```

    Sa perte n'est pas dramatique (regénérer invalide juste les sessions OIDC en cours).

!!! note "Premier login OIDC : promouvoir l'utilisateur admin"
    Le compte créé au 1ᵉʳ login OIDC n'est pas forcément admin. `KOMODO_LOCAL_AUTH` reste `true` comme
    filet : se connecter en `admin` local pour activer/promouvoir l'utilisateur OIDC, puis (optionnel)
    passer `KOMODO_LOCAL_AUTH=false` pour ne garder qu'Authelia.

**Forgejo (à venir)** : même principe, déclarer un client `forgejo` et brancher l'auth source OIDC côté
`git.lucasmasse.net` (portail public → redirection cross-domaine OK).

---

**Sources :** `hosts/vps-prod/stacks/{authelia,lldap,smtp-relay}/`, `komodo/stacks.toml`,
`secrets/vps/*.env` du dépôt · [Authelia](https://www.authelia.com/) ·
[lldap](https://github.com/lldap/lldap) · [boky/postfix](https://github.com/bokysan/docker-postfix) ·
[Brevo SMTP](https://www.brevo.com/).
