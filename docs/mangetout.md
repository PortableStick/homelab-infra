# mangetout (PocketBase + proxy IA)

Backend d'une application mobile : un **PocketBase** (base + API + auth) et un **proxy IA** maison
devant OpenRouter. Contrairement aux autres services `*.vindiesel.vip` du dépôt, mangetout est
**public** (pas de filtrage VPN) — c'est le backend d'une app cliente. Déployé par Komodo sur l'hôte
**`vindiesel`** (serveur `docker-vindiesel`) en GitOps.

Sources : `hosts/vindiesel/stacks/mangetout/`, `secrets/vindiesel/mangetout.env`, `komodo/stacks.toml`,
`hosts/vps-prod/stacks/traefik/dynamic/home-vindiesel.yaml`, `hosts/vps-prod/stacks/authelia/configuration.yaml`.

## Composants

| Service | Image | Rôle | Exposition |
| --- | --- | --- | --- |
| `pocketbase` | `ghcr.io/portablestick/mangetout-pocketbase:${PB_IMAGE_TAG:-latest}` | Base + API + auth (OIDC) | `pb.vindiesel.vip` (**public**), port interne `8090` |
| `ai-proxy` | `ghcr.io/portablestick/mangetout-ai-proxy:${AI_IMAGE_TAG:-latest}` | Proxy IA devant OpenRouter | `ai.vindiesel.vip` (**public**), port interne `8787` |

- **Réseaux** : les deux services joignent `proxy` (externe, pour le Traefik local vindiesel) **et**
  `mangetout_internal` (privé — l'`ai-proxy` parle à PocketBase en `http://pocketbase:8090`, cf.
  `PB_INTERNAL_URL`).
- **Stockage** : `pocketbase` bind-monte `/data/mangetout/pb_data` (à créer avant le 1ᵉʳ déploiement)
  et **les migrations de schéma versionnées** `./pb_migrations` (montées en lecture seule, elles sont
  dans le dépôt, pas dans l'image).
- `restart: unless-stopped`, `logging` json-file (10 m × 3) sur les deux services ; healthcheck
  `/api/health` sur PocketBase.

!!! warning "Images en `:latest` par défaut"
    `PB_IMAGE_TAG` / `AI_IMAGE_TAG` valent `latest` par défaut : ces deux images (construites depuis
    `PortableStick/*`) **ne sont pas épinglées** au digest, contrairement aux images tierces du dépôt.
    `GlobalAutoUpdate` peut donc tirer une nouvelle version sans validation — fixer un tag précis via ces
    variables pour un déploiement déterministe.

### Config de l'`ai-proxy` (non-secrets, dans `compose.yaml`)

| Variable | Valeur |
| --- | --- |
| `OPENROUTER_BASE_URL` | `https://openrouter.ai/api/v1` |
| `AI_MODEL_TEXT` | `deepseek/deepseek-v4-flash` |
| `AI_MODEL_TEXT_PRO` | `deepseek/deepseek-v4-pro` |
| `AI_MODEL_VISION` | `google/gemini-2.5-flash` |
| `PB_INTERNAL_URL` | `http://pocketbase:8090` |
| `AI_RATE_LIMIT_PER_MIN` | `20` |

## Exposition Traefik (**public**) — deux endroits

Même mécanique de reverse proxy que les autres services vindiesel (Traefik local vindiesel en HTTP nu
sur `100.65.11.58:80`, TLS wildcard terminé par le Traefik du VPS — voir
[Reverse proxy & TLS](reverse-proxy-tls.md)), **mais sans middleware `int-vpn`** : ces deux hôtes sont
publics.

1. **Labels** dans `hosts/vindiesel/stacks/mangetout/compose.yaml` (Traefik local vindiesel), ex. pour
   PocketBase :

    ```yaml
    - "traefik.enable=true"
    - "traefik.docker.network=proxy"
    - "traefik.http.routers.mangetout-pb.rule=Host(`pb.vindiesel.vip`)"
    - "traefik.http.routers.mangetout-pb.entrypoints=web"
    - "traefik.http.services.mangetout-pb.loadbalancer.server.port=8090"
    ```

2. **Routeurs** dans `hosts/vps-prod/stacks/traefik/dynamic/home-vindiesel.yaml` (Traefik VPS, TLS) —
   **pas** de `middlewares: [int-vpn]`, à la différence des routeurs `*.int` :

    ```yaml
    mangetout-pb:
      rule: "Host(`pb.vindiesel.vip`)"
      entryPoints: [websecure]
      service: home-vindiesel
      tls: {}
    mangetout-ai:
      rule: "Host(`ai.vindiesel.vip`)"
      entryPoints: [websecure]
      service: home-vindiesel
      tls: {}
    ```

!!! danger "Public = pas de filet `int-vpn`"
    `pb.vindiesel.vip` et `ai.vindiesel.vip` sont accessibles depuis Internet. La sécurité repose donc
    entièrement sur **PocketBase** (auth OIDC + règles d'API) et sur le **rate-limit** de l'`ai-proxy`
    (`AI_RATE_LIMIT_PER_MIN`, + `PB_SERVICE_TOKEN` pour authentifier le proxy auprès de PocketBase). Il
    n'y a **aucun** forward-auth Authelia devant ces domaines.

### DNS

Contrairement aux noms `*.int.vindiesel.vip` (DNS-only → IP Tailscale), `pb.` et `ai.vindiesel.vip` sont
**publics** : leur enregistrement DNS pointe vers l'edge **VPS** (qui termine le TLS wildcard
`*.vindiesel.vip` et forwarde vers vindiesel). Le certificat est le wildcard déjà émis, consommé en
`tls: {}` nu (jamais de `certresolver` sur ces routeurs — cf. [Reverse proxy & TLS](reverse-proxy-tls.md)).

## Secrets (SOPS/age)

`secrets/vindiesel/mangetout.env`, chiffré pour la clé age du dépôt (règle `secrets/vindiesel/*.env`,
cf. [Secrets](secrets-sops.md)). Rendu en `.env` par le `pre_deploy` de Komodo, consommé par `env_file:`
de l'`ai-proxy` (et lu par PocketBase pour l'OIDC).

| Variable | Rôle |
| --- | --- |
| `OPENROUTER_API_KEY` | Clé OpenRouter utilisée par l'`ai-proxy`. |
| `PB_SERVICE_TOKEN` | Jeton d'un compte de service PocketBase — **émis APRÈS le 1ᵉʳ déploiement** (cf. post-install). |
| `OIDC_CLIENT_SECRET` | Secret du client OIDC `mangetout` (côté Authelia), saisi dans l'UI OAuth2 de PocketBase. |
| `PB_ADMIN_EMAIL` / `PB_ADMIN_PASSWORD` | Superuser PocketBase initial (à créer à la main au 1ᵉʳ lancement). |

## Déploiement (Komodo)

Entrée `[[stack]] mangetout` dans `komodo/stacks.toml` : `server = "docker-vindiesel"`,
`after = ["traefik-vindiesel"]`, tags `["app","vindiesel"]`, `pre_deploy` SOPS (même mécanisme
qu'Immich / Pelican) :

```toml
[[stack]]
name = "mangetout"
# ...
file_paths = ["hosts/vindiesel/stacks/mangetout/compose.yaml"]
pre_deploy.path = "hosts/vindiesel/stacks/mangetout"
pre_deploy.command = "sops -d ../../../../secrets/vindiesel/mangetout.env > .env"
```

**Ordre :** créer `/data/mangetout/pb_data` + les enregistrements DNS, puis déployer via Komodo (le
`pre_deploy` rend le `.env`, `after` garantit que `traefik-vindiesel` est up).

## Post-install (1ᵉʳ lancement)

1. **Superuser PocketBase** : au 1ᵉʳ boot, créer le compte admin (via l'UI `/_/` ou les variables
   `PB_ADMIN_EMAIL` / `PB_ADMIN_PASSWORD`).
2. **Migrations** : les fichiers de `pb_migrations/` (montés en lecture seule) sont appliqués par
   PocketBase au démarrage.
3. **Compte de service + `PB_SERVICE_TOKEN`** : créer le compte de service que l'`ai-proxy` utilise pour
   parler à PocketBase, générer son jeton, puis le reporter dans `secrets/vindiesel/mangetout.env`
   (`PB_SERVICE_TOKEN`) et redéployer.
4. **OIDC** : configurer le provider OAuth2 « OIDC » dans l'UI PocketBase (voir ci-dessous).

## OIDC (login via Authelia)

PocketBase se logue via **Authelia** (client OIDC `mangetout`, **déjà déclaré** côté Authelia —
`hosts/vps-prod/stacks/authelia/configuration.yaml`, voir
[Authelia — mangetout](authelia.md#mangetout-pocketbase-client-oidc-actif)).

**Côté PocketBase** (UI admin → *Settings → Auth providers → OpenID Connect*) :

- Issuer / endpoints : `https://auth.vindiesel.vip`
- Client ID : `mangetout`
- Client secret : la valeur de `OIDC_CLIENT_SECRET` (`mangetout.env`)
- Scopes : `openid profile email`
- Redirect URL : `https://pb.vindiesel.vip/api/oauth2-redirect` (doit correspondre au `redirect_uris`
  déclaré côté Authelia).

**Côté Authelia** : client `mangetout` avec `require_pkce: true` (S256), `authorization_policy: two_factor`,
secret sous forme de **hash pbkdf2** (jamais en clair). Le secret en clair reste dans
`secrets/vindiesel/mangetout.env`. Générer le hash :

```bash
docker run --rm authelia/authelia:4.39 authelia crypto hash generate pbkdf2 --password 'LE_SECRET_EN_CLAIR'
```

!!! info "Redirection cross-domaine OK"
    `pb.vindiesel.vip` est public et Authelia (`auth.vindiesel.vip`) aussi ; le cookie de session posé
    sur `vindiesel.vip` couvre les deux sous-domaines, donc le flux OIDC fonctionne sans configuration
    supplémentaire.

## Dépannage

| Symptôme | Cause probable | Correctif |
| --- | --- | --- |
| `pb.`/`ai.vindiesel.vip` en 404 / 502 via le VPS | Labels Traefik local manquants **ou** routeur absent de `home-vindiesel.yaml` | Vérifier les **deux** endroits (labels compose + routeur dynamique VPS) |
| L'`ai-proxy` répond `401`/`403` vers PocketBase | `PB_SERVICE_TOKEN` absent ou périmé | Régénérer le jeton du compte de service et le remettre dans `mangetout.env`, puis redéployer |
| Login OIDC échoue (`invalid client`/redirect mismatch) | `OIDC_CLIENT_SECRET` désynchronisé, ou `redirect_uris` ≠ URL PocketBase | Aligner le secret (clair côté PB / hash côté Authelia) et l'URL de callback |
| Migrations non appliquées | `pb_migrations/` non monté (ro) ou vide | Vérifier le bind mount `./pb_migrations:/pb/pb_migrations:ro` |
| Nouvelle version tirée par surprise | `PB_IMAGE_TAG`/`AI_IMAGE_TAG` en `latest` + `GlobalAutoUpdate` | Épingler un tag précis dans l'environnement de la stack |

---

**Sources :** `hosts/vindiesel/stacks/mangetout/` (`compose.yaml`, `.env.example`, `pb_migrations/`),
`secrets/vindiesel/mangetout.env`, `komodo/stacks.toml`,
`hosts/vps-prod/stacks/traefik/dynamic/home-vindiesel.yaml`,
`hosts/vps-prod/stacks/authelia/configuration.yaml` du dépôt ·
[PocketBase](https://pocketbase.io/docs/) · [OpenRouter](https://openrouter.ai/docs).
