# Pelican (Panel jeux)

Panel de gestion de serveurs de jeu, exposé **VPN-only** sur **`mcwings.int.vindiesel.vip`**. Déployé
par Komodo sur l'hôte **`vindiesel`** (serveur `docker-vindiesel`). Seul le **Panel** (+ sa base MariaDB
et son Redis) est géré ici en GitOps ; le daemon **Wings** et les serveurs de jeu sont hors dépôt
(phase 2, voir plus bas).

Sources : `hosts/vindiesel/stacks/pelican/`, `secrets/vindiesel/pelican.env`, `komodo/stacks.toml`,
`hosts/vps-prod/stacks/traefik/dynamic/home-vindiesel.yaml`, `hosts/mc-wings/stacks/wings/`.

!!! info "Pelican, pas Pterodactyl"
    On déploie **[Pelican](https://pelican.dev)** (successeur de Pterodactyl, même équipe fondatrice),
    choisi pour son **SSO/OIDC** de première classe (via plugin) — absent de Pterodactyl 1.x. Le daemon
    reste **Wings**, compatible avec le modèle node/allocation habituel. Image officielle :
    `ghcr.io/pelican-dev/panel`.

!!! warning "Déploiement Docker « work in progress » côté Pelican"
    La doc Pelican qualifie encore le déploiement Docker de *work in progress* et le pilote via un
    **installeur web** (`/installer`) + un **Caddy embarqué**. On garde donc le pattern maison du dépôt
    (conteneurs en GitOps, **finalisation manuelle documentée** — comme
    [mangetout](https://github.com/PortableStick/homelab-infra) pour son superuser/OIDC) : le premier
    boot passe par l'installeur, puis l'OIDC se configure dans l'UI. Ce n'est pas du 100 % déclaratif,
    c'est assumé.

## Composants

| Service | Image | Rôle | Exposition |
| --- | --- | --- | --- |
| `panel` | `ghcr.io/pelican-dev/panel:latest` | UI + API Pelican (Caddy + PHP-FPM) | `mcwings.int.vindiesel.vip` (**VPN-only**) |
| `database` | `mariadb:11.4` | Base du Panel | interne (réseau `pelican_backend`) |
| `cache` | `redis:7.4-alpine` | Cache / sessions / queue | interne (réseau `pelican_backend`) |

- Réseaux : `panel` joint `proxy` (externe, pour Traefik) **et** `pelican_backend` ; `database` et
  `cache` restent sur `pelican_backend` (aucun port publié sur l'hôte).
- `restart: unless-stopped`, `healthcheck` et `logging` (json-file, 10 m × 3) sur les trois services,
  comme les autres stacks vindiesel.
- Données sur l'hôte (bind mounts, à créer avant le 1ᵉʳ déploiement) :

  ```bash
  sudo mkdir -p /data/pelican/pelican-data /data/pelican/logs /data/pelican/database /data/pelican/redis
  ```

## Exposition Traefik (VPN-only) — **deux endroits**

`vindiesel` a son **propre** Traefik (réseau `proxy`, entrypoint `web` en **HTTP nu** sur l'IP Tailscale
`100.65.11.58:80`). Le **TLS wildcard `*.int.vindiesel.vip`** est terminé par le Traefik du **VPS**, qui
forwarde vers vindiesel. Exposer un service vindiesel = **deux modifications** (voir
[Reverse proxy & TLS](reverse-proxy-tls.md) et [Exposer un service en VPN-only](exposer-service-vpn-only.md)) :

1. **Labels** dans `hosts/vindiesel/stacks/pelican/compose.yaml` (Traefik local vindiesel) :

    ```yaml
    - "traefik.enable=true"
    - "traefik.docker.network=proxy"
    - "traefik.http.routers.pelican.rule=Host(`mcwings.int.vindiesel.vip`)"
    - "traefik.http.routers.pelican.entrypoints=web"
    - "traefik.http.services.pelican.loadbalancer.server.port=80"
    ```

2. **Routeur** dans `hosts/vps-prod/stacks/traefik/dynamic/home-vindiesel.yaml` (Traefik VPS, TLS +
   filtrage VPN via le middleware `int-vpn`) :

    ```yaml
    pelican:
      rule: "Host(`mcwings.int.vindiesel.vip`)"
      entryPoints:
        - websecure
      service: home-vindiesel
      middlewares:
        - int-vpn
      tls: {}
    ```

!!! warning "Pas de `certresolver` — on consomme le wildcard"
    Le routeur est en `tls: {}` **nu** : il réutilise le wildcard `*.int.vindiesel.vip` déjà émis par le
    routeur générateur. Ne jamais ajouter `tls.certresolver` (règle d'or, cf.
    [Reverse proxy & TLS](reverse-proxy-tls.md)).

### DNS à créer (Cloudflare, DNS-only)

| Type | Nom | Valeur | Proxy |
| --- | --- | --- | --- |
| `A` | `mcwings.int.vindiesel.vip` | `100.65.11.58` (IP Tailscale de **vindiesel**) | **DNS-only** |

### Caddy derrière le reverse proxy

Le Panel embarque **Caddy**. Comme le TLS est terminé en amont (Traefik VPS), on bind-monte un
`Caddyfile` custom (`hosts/vindiesel/stacks/pelican/Caddyfile`) qui écoute en `:80` **sans** demander de
certificat, avec `trusted_proxies static private_ranges`.

!!! danger "`trusted_proxies` obligatoire, sinon les uploads cassent"
    Sans `trusted_proxies` correctement réglé, Caddy ne fait pas confiance à l'IP du proxy et les
    **uploads de fichiers échouent**. `private_ranges` couvre les IP des réseaux Docker (Traefik parle au
    Panel via le réseau `proxy`). En complément, `TRUSTED_PROXIES: "*"` est passé côté Laravel pour que
    le Panel construise ses URLs en `https://`.

## Secrets (SOPS/age)

`secrets/vindiesel/pelican.env`, chiffré pour la clé age du dépôt (règle `secrets/vindiesel/*.env` de
`.sops.yaml`, cf. [Secrets](secrets-sops.md)). Rendu automatiquement en `.env` par le `pre_deploy` de
Komodo, consommé par `env_file:`.

| Variable | Rôle |
| --- | --- |
| `APP_KEY` | Clé de chiffrement Laravel (`base64:…`). **Générée, ne pas changer après install.** |
| `DB_PASSWORD` | Mot de passe MariaDB de l'utilisateur `pelican` (côté Panel). |
| `MARIADB_PASSWORD` | **Identique** à `DB_PASSWORD` (MariaDB crée l'utilisateur avec cette valeur). |
| `MARIADB_ROOT_PASSWORD` | Mot de passe root MariaDB. |
| `REDIS_PASSWORD` | Mot de passe Redis. |
| `PELICAN_OIDC_CLIENT_SECRET` | Secret **en clair** du client OIDC `pelican` (phase OIDC). |

Les **non-secrets** (`APP_URL`, `DB_CONNECTION=mariadb`, `DB_HOST=database`, `CACHE_STORE=redis`,
`REDIS_HOST=cache`, timezone, etc.) sont dans `compose.yaml` (`environment:`). Un
[`.env.example`](https://github.com/PortableStick/homelab-infra) documente chaque placeholder.

!!! danger "`DB_PASSWORD` et `MARIADB_PASSWORD` doivent être identiques"
    Le Panel se connecte en tant qu'utilisateur `pelican` avec `DB_PASSWORD` ; MariaDB **crée** cet
    utilisateur avec `MARIADB_PASSWORD`. S'ils diffèrent, la connexion échoue (`Access denied`).

## Déploiement (Komodo)

Entrée `[[stack]] pelican` dans `komodo/stacks.toml` : `server = "docker-vindiesel"`,
`after = ["traefik-vindiesel"]`, tags `["app","vindiesel"]`, et `pre_deploy` SOPS (même mécanisme
qu'Immich / mangetout) :

```toml
[[stack]]
name = "pelican"
# ...
file_paths = ["hosts/vindiesel/stacks/pelican/compose.yaml"]
pre_deploy.path = "hosts/vindiesel/stacks/pelican"
pre_deploy.command = "sops -d ../../../../secrets/vindiesel/pelican.env > .env"
```

**Ordre :** créer les dossiers de données + l'enregistrement DNS, puis déployer la stack `pelican` via
Komodo (le `pre_deploy` rend le `.env`, `after` garantit que `traefik-vindiesel` est up).

## Post-install (1ᵉʳ lancement)

1. **Sauvegarder l'`APP_KEY`** (déjà fixée par le secret, mais le conteneur la logue au 1ᵉʳ boot) :

    ```bash
    docker compose logs panel | grep 'Generated app key' || true
    ```

2. **Installeur web** : ouvrir `https://mcwings.int.vindiesel.vip/installer` (sur le VPN). Les valeurs
   DB/Redis sont déjà fournies par l'environnement — confirmer :
    - Database : **MariaDB**, hôte `database`, base `panel`, user `pelican`.
    - Cache/Session/Queue : **Redis**, hôte `cache`.
   Puis **créer le compte administrateur**.

    !!! note "Migrations au démarrage"
        Après l'install (et à chaque mise à jour d'image), le conteneur applique les migrations au boot ;
        le Panel est indisponible quelques minutes le temps qu'elles passent.

3. **Alternative CLI** (si tu préfères éviter l'installeur, une fois la base joignable) :

    ```bash
    docker compose exec panel php artisan migrate --force
    docker compose exec panel php artisan p:user:make   # créer un admin
    ```

## OIDC (login via Authelia)

Le Panel de base **n'a pas** d'OIDC générique : Pelican passe par **Laravel Socialite** + le plugin
officiel **`generic-oidc-providers`** (auteur *Boy132*, tire `kovah/laravel-socialite-oidc`), configuré
**dans l'UI admin** (stocké en base, pas en variable d'env).

**Côté Panel :**

1. Installer le plugin via le **[Hub Pelican](https://hub.pelican.dev/plugins/generic-oidc-providers)**
   (login Discord → *Connect your panel* → *Install*).
2. *Admin → OAuth / OIDC Providers* → créer un provider pointant sur Authelia :
    - Base/Issuer : `https://auth.vindiesel.vip`
    - Client ID : `pelican`
    - Client secret : la valeur de `PELICAN_OIDC_CLIENT_SECRET`
    - Scopes : `openid profile email`
    - L'UI affiche l'**URL de callback** exacte à reporter côté Authelia (`redirect_uris`).

**Côté Authelia** (VPS) — même pattern que le client Komodo (voir
[Authelia — OIDC](authelia.md#oidc-komodo-se-logue-via-authelia)) :

- Déclarer un client `pelican` dans `identity_providers.oidc.clients` de
  `hosts/vps-prod/stacks/authelia/configuration.yaml`, avec le **hash pbkdf2** du secret (jamais le
  secret en clair) et le `redirect_uris` affiché par le plugin. Générer le hash :

  ```bash
  docker run --rm authelia/authelia:4.39 authelia crypto hash generate pbkdf2 --password 'LE_SECRET_EN_CLAIR'
  ```

- Le secret en clair reste, lui, dans `secrets/vindiesel/pelican.env` (`PELICAN_OIDC_CLIENT_SECRET`).

!!! info "Redirections cross-domaine OK sur le VPN"
    Authelia (`auth.vindiesel.vip`) est **public**, le Panel est **VPN-only** : sur le tailnet, le
    navigateur atteint les deux, la redirection OIDC fonctionne (cf. l'encadré « portail public » dans
    [Authelia](authelia.md)).

## Phase 2 — Wings (hôte `mc-wings`, PLUS TARD)

Wings (le daemon d'exécution) tourne sur la VM **séparée `mc-wings`**, **hors Komodo** et **jamais
derrière Traefik**. Scaffold : `hosts/mc-wings/stacks/wings/` (compose + `config.yml.example` + README
détaillé). Résumé du flux :

1. Créer le **node** dans le Panel (*Admin → Nodes*), FQDN ex. `node1.int.vindiesel.vip`, port `8080`,
   SSL activé.
2. DNS `A node1.int.vindiesel.vip → IP Tailscale de mc-wings` (DNS-only).
3. Fournir un **certificat valide** au node (le Panel étant en HTTPS, Wings doit l'être aussi).
4. Copier le `config.yml` **généré par le Panel** dans `/etc/pelican/config.yml` sur `mc-wings` (jamais
   committé : contient un token — ignoré par le `.gitignore` du dossier).
5. `docker compose up -d` sur `mc-wings`.

!!! danger "Wings n'est JAMAIS derrière Traefik"
    Wings expose l'API + websocket console (`8080`) et surtout le **SFTP** (`2022`) : proxifier ces flux
    TCP bruts via Traefik (HTTP) **casse le SFTP**. L'isolation vient du VPN Tailscale, pas d'un proxy.
    Détails dans [`hosts/mc-wings/stacks/wings/README.md`](https://github.com/PortableStick/homelab-infra).

## Dépannage

| Symptôme | Cause probable | Correctif |
| --- | --- | --- |
| Uploads de fichiers en échec dans le Panel | `trusted_proxies` Caddy mal réglé (l'IP du proxy Docker n'est pas de confiance) | Vérifier `trusted_proxies static private_ranges` dans le `Caddyfile` bind-monté |
| Le Panel construit des URLs en `http://` / boucles de redirection | `APP_URL` ou trusted proxies incorrects | `APP_URL=https://mcwings.int.vindiesel.vip` + `TRUSTED_PROXIES: "*"` (déjà dans `compose.yaml`) |
| `SQLSTATE… Access denied for user 'pelican'` | `DB_PASSWORD` ≠ `MARIADB_PASSWORD` | Aligner les deux dans le secret puis redéployer |
| Accès refusé / 403 depuis le tailnet | `userland-proxy` masque l'IP source → `int-vpn` rejette | Prérequis `{"userland-proxy": false}`, cf. [Exposer un service en VPN-only](exposer-service-vpn-only.md) |
| Node Wings reste **rouge** dans le Panel | Cert/URL du node, ou Wings derrière un proxy | Vérifier le `config.yml`, le cert du node, l'accès direct `:8080` sur le VPN (jamais via Traefik) |

---

**Sources :** `hosts/vindiesel/stacks/pelican/`, `secrets/vindiesel/pelican.env`, `komodo/stacks.toml`,
`hosts/vps-prod/stacks/traefik/dynamic/home-vindiesel.yaml`, `hosts/mc-wings/stacks/wings/` du dépôt ·
[Pelican — Docker](https://pelican.dev/docs/panel/advanced/docker/) ·
[Pelican — Installing Wings](https://pelican.dev/docs/wings/install/) ·
[Plugin Generic OIDC Providers](https://hub.pelican.dev/plugins/generic-oidc-providers) ·
[Authelia — OpenID Connect](https://www.authelia.com/integration/openid-connect/introduction/).
