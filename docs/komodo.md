# Komodo

[Komodo](https://komo.do) est le système de build & déploiement qui orchestre l'infra en mode
GitOps : il lit la configuration depuis ce dépôt et lance les stacks `docker compose`.

Source principale : `hosts/vps-prod/stacks/komodo/compose.yaml` et `komodo/stacks.toml`.

## Composants (compose Komodo)

Le `compose.yaml` de Komodo déploie quatre services :

| Service | Image | Rôle | Notes |
| --- | --- | --- | --- |
| `postgres` | `ghcr.io/ferretdb/postgres-documentdb` | Stockage sous-jacent de FerretDB | Volume `postgres-data`. Label `komodo.skip` pour que Komodo ne l'arrête pas avec *StopAllContainers*. |
| `ferretdb` | `ghcr.io/ferretdb/ferretdb` | Adaptateur compatible MongoDB au-dessus de Postgres | Volume `ferretdb-state`. Dépend de `postgres`. Label `komodo.skip`. |
| `core` | `ghcr.io/moghtech/komodo-core:${COMPOSE_KOMODO_IMAGE_TAG:-2}` | UI + API Komodo | Port `9120`. Dépend de `ferretdb`. `KOMODO_DATABASE_ADDRESS: ferretdb:27017`. |
| `periphery` | `ghcr.io/moghtech/komodo-periphery:${COMPOSE_KOMODO_IMAGE_TAG:-2}` | Agent qui exécute Docker sur l'hôte | Accède à `docker.sock`, `/proc`, au répertoire racine Periphery, et monte le binaire `sops` de l'hôte + `SOPS_AGE_KEY_FILE` (voir plus bas *pourquoi*). Dépend de `core`. |

!!! warning "Versions d'images"
    Les tags `core`/`periphery` utilisent `${COMPOSE_KOMODO_IMAGE_TAG:-2}` (par défaut la série
    majeure `2`). Les images **`postgres-documentdb` et `ferretdb` ne sont pas épinglées** — le compte
    le signale lui-même : *« 🚨 Pin to a specific version. Updates can be breaking. »*. Une mise à jour
    automatique de ces deux images peut casser la base. À épingler avant de fiabiliser la prod.

## Volumes et chemins

| Volume / chemin | Monté dans | Contenu |
| --- | --- | --- |
| `postgres-data` (nommé) | `/var/lib/postgresql/data` | Données Postgres (donc toute la base Komodo) |
| `ferretdb-state` (nommé) | `/state` | État FerretDB |
| `keys` (nommé) | `/config/keys` (core **et** periphery) | Clés de communication Core ↔ Periphery |
| `${COMPOSE_KOMODO_BACKUPS_PATH}` | `/backups` | Sauvegardes datées de la base (voir [Procédures](procedures-planifiees.md)) |
| `${PERIPHERY_ROOT_DIRECTORY:-/etc/komodo}` | identique dans le conteneur | Racine Periphery : **tous** les repos/configs gérés doivent être enfants de ce dossier |
| `/var/run/docker.sock` | `/var/run/docker.sock` | Permet à Periphery de piloter Docker |
| `/proc` | `/proc` | Permet à Periphery de voir les process hôte |
| `/usr/local/bin/sops` (hôte, `:ro`) | `/usr/local/bin/sops` | Binaire `sops` de l'hôte, absent de l'image `komodo-periphery` (voir ci-dessous) |

!!! info "Le répertoire racine Periphery doit être identique dedans et dehors"
    Le compose le rappelle : le chemin doit être le **même** à l'intérieur et à l'extérieur du
    conteneur, sinon Docker se mélange (réf. discussion Komodo #180 citée en commentaire). Défaut :
    `/etc/komodo`.

!!! info "Pourquoi `sops` est monté à la main dans la Periphery du serveur `Local`"
    Les stacks `lldap`, `authelia` et `smtp-relay` (serveur `Local`, voir `komodo/stacks.toml`) ont un
    `pre_deploy.command` qui lance `sops -d ...`. Mais l'image `ghcr.io/moghtech/komodo-periphery`
    **n'embarque pas** `sops` : sans ce montage, le `pre_deploy` échoue (`sops: command not found`).
    Le compose monte donc `/usr/local/bin/sops` de l'hôte VPS en lecture seule et expose
    `SOPS_AGE_KEY_FILE=/etc/komodo/age/key.txt` (clé déjà présente via le montage du répertoire racine
    Periphery). Sur `docker-vindiesel`, la Periphery tourne en **binaire systemd** (pas conteneurisée,
    voir [Rattacher un hôte](rattacher-hote-periphery.md)) : `scripts/bootstrap-periphery.sh` y
    installe `sops` directement sur l'hôte, donc pas de bind-mount à prévoir dans ce cas — c'est
    uniquement la Periphery **conteneurisée** qui a besoin de ce contournement.

## Secrets (compose.env)

Le Core et la Periphery chargent leurs variables via `env_file: ./compose.env`. Ce fichier
**n'est pas dans Git** : il est produit en déchiffrant `secrets/vps/komodo.env` (SOPS/age).

Variables présentes dans `secrets/vps/komodo.env` (noms visibles, valeurs chiffrées) :

`COMPOSE_KOMODO_IMAGE_TAG`, `COMPOSE_KOMODO_BACKUPS_PATH`, `KOMODO_DATABASE_USERNAME`,
`KOMODO_DATABASE_PASSWORD`, `TZ`, `KOMODO_HOST`, `KOMODO_TITLE`, `KOMODO_PERIPHERY_PUBLIC_KEY`,
`KOMODO_LOCAL_AUTH`, `KOMODO_INIT_ADMIN_USERNAME`, `KOMODO_INIT_ADMIN_PASSWORD`,
`KOMODO_FIRST_SERVER_NAME`, `KOMODO_DISABLE_CONFIRM_DIALOG`, `KOMODO_DISABLE_INIT_RESOURCES`,
`KOMODO_WEBHOOK_SECRET`, `KOMODO_JWT_SECRET`, `KOMODO_JWT_TTL`, `KOMODO_MONITORING_INTERVAL`,
`KOMODO_RESOURCE_POLL_INTERVAL`, `KOMODO_DISABLE_USER_REGISTRATION`,
`KOMODO_ENABLE_NEW_USERS`, `KOMODO_DISABLE_NON_ADMIN_CREATE`, `KOMODO_TRANSPARENT_MODE`,
`KOMODO_LOGGING_PRETTY`, `KOMODO_PRETTY_STARTUP_CONFIG`, `KOMODO_GITHUB_OAUTH_ENABLED`,
`KOMODO_GOOGLE_OAUTH_ENABLED`, `KOMODO_AWS_ACCESS_KEY_ID`, `KOMODO_AWS_SECRET_ACCESS_KEY`,
`KOMODO_OIDC_ENABLED`, `KOMODO_OIDC_PROVIDER`, `KOMODO_OIDC_CLIENT_ID`, `KOMODO_OIDC_CLIENT_SECRET`,
`PERIPHERY_CORE_ADDRESS`, `PERIPHERY_CONNECT_AS`, `PERIPHERY_CORE_PUBLIC_KEYS`,
`PERIPHERY_ROOT_DIRECTORY`, `PERIPHERY_DISABLE_TERMINALS`, `PERIPHERY_DISABLE_CONTAINER_TERMINALS`,
`PERIPHERY_INCLUDE_DISK_MOUNTS`, `PERIPHERY_LOGGING_PRETTY`, `PERIPHERY_PRETTY_STARTUP_CONFIG`.

Les quatre `KOMODO_OIDC_*` configurent le login via **Authelia** (SSO/OIDC) — voir
[Authelia (SSO / 2FA)](authelia.md).

!!! danger "`KOMODO_HOST` doit correspondre au domaine réellement routé par Traefik"
    Piège vécu : `KOMODO_HOST` valait `komodo.vindiesel.vip` (sans `.int`) alors que le routeur
    Traefik du `core` route sur le domaine `komodo.int.vindiesel.vip` (label
    `traefik.http.routers.komodo.rule` dans le compose). Le frontend Komodo s'appuie sur
    `KOMODO_HOST` pour construire ses appels API ; avec la mauvaise valeur, il vise une URL non
    routée et **la page de login s'affiche sans aucun champ à remplir** (pas d'erreur explicite).
    Correctif : aligner `KOMODO_HOST` sur le domaine du label Traefik de `core` dans
    `hosts/vps-prod/stacks/komodo/compose.yaml`.

```bash
# Rendu du compose.env à partir du secret chiffré (étape manuelle actuelle)
sops -d secrets/vps/komodo.env > hosts/vps-prod/stacks/komodo/compose.env
```

!!! warning "Bootstrap manuel, pas géré par Komodo lui-même"
    La stack Komodo (Core + Periphery + base) **ne figure pas** dans la liste des `[[stack]]` de
    `komodo/stacks.toml` : Komodo ne se déploie pas lui-même. Au premier boot, on lance Komodo **à la
    main** (`docker compose up -d` dans `hosts/vps-prod/stacks/komodo/`), après avoir rendu
    `compose.env`. Ensuite seulement, Komodo reprend la main sur les autres stacks via le resource
    sync. `scripts/bootstrap.sh` automatise ces étapes sur un VPS nu : réseau `frontend`, répertoires
    de données (dont `/data/authelia` et `/data/lldap` pour la stack auth), clé age, rendu du
    `compose.env` et `docker compose up -d`. Il génère aussi, de façon idempotente,
    `/data/authelia/oidc-issuer.pem` (`openssl genrsa`) : la clé privée de signature OIDC d'Authelia,
    qui ne peut pas venir de Git au même titre que la clé age. Voir
    [Restauration complète](restauration.md).

## GitOps : `komodo/stacks.toml`

Ce fichier est la **source de vérité** que Komodo applique. Il déclare :

- **Serveurs** : `Local` (Periphery conteneurisée, même hôte que le Core) et `docker-vindiesel`
  (Periphery binaire+systemd distante, voir [Rattacher un hôte](rattacher-hote-periphery.md)).
- **Repo `homelab-infra`** lié à `PortableStick/homelab-infra`, builder `Local`.
- **Builder `Local`** de type `Server`.
- **Resource sync `homelab-infra`** : `linked_repo = "homelab-infra"`,
  `resource_path = ["komodo/stacks.toml"]`, **`delete = true`**.
- Les **stacks** déployées par Komodo, par tag :
    - `edge` : `acme-dns`, `traefik` (serveur `Local`), `traefik-vindiesel` (serveur
      `docker-vindiesel`).
    - `app` : `portfolio`, `forgejo`, `whoami` (après `traefik`), `immich-1`, `immich-2` (après
      `traefik-vindiesel`, serveur `docker-vindiesel`).
    - `auth` : `lldap`, `authelia` (après `traefik`, `lldap`, `smtp-relay`).
    - `infra` : `smtp-relay`.
    - Chaque stack pointe vers son `compose.yaml` dans `hosts/<serveur>/stacks/...` ; celles avec un
      secret chiffré déclarent un `pre_deploy.command = "sops -d ... > .env"`.
- Trois **procédures planifiées** (voir page dédiée).

!!! danger "`delete = true` sur le resource sync"
    Avec `delete = true`, toute ressource gérée par Komodo qui **n'est plus** dans `stacks.toml` est
    **supprimée** lors de la synchronisation. C'est voulu (config déclarative stricte), mais ça veut
    dire qu'éditer ce fichier peut détruire des stacks. Modifier en connaissance de cause.

## Sauvegarde & restauration de la base

La base Komodo (dans `postgres-data`) est sauvegardée par la procédure **Backup Core Database**
(quotidienne, 01:00) vers `/backups`. La sauvegarde et la restauration passent par la **CLI Komodo**
(`km`), incluse dans l'image Core :

```yaml
# Restauration depuis une sauvegarde (image komodo-cli)
services:
  cli:
    image: ghcr.io/moghtech/komodo-cli
    command: km database restore -y   # --restore-folder 2025-08-14_03-00-01 pour cibler un dossier
    volumes:
      - /chemin/vers/backups:/backups
    environment:
      KOMODO_CLI_DATABASE_TARGET_ADDRESS: <hôte:27017>
      KOMODO_CLI_DATABASE_TARGET_USERNAME: <db username>
      KOMODO_CLI_DATABASE_TARGET_PASSWORD: <db password>
      KOMODO_CLI_DATABASE_TARGET_DB_NAME: komodo
```

!!! warning "La restauration ne vide pas la base cible"
    D'après la doc officielle : `km database restore` n'efface pas la base avant de restaurer. Si la
    cible contient déjà des documents, ils subsistent. Restaurer dans une base **vide** (ou la
    supprimer avant). Les sauvegardes **ne sont pas chiffrées** par Komodo — c'est à prévoir si on les
    pousse hors-site.

## Dépannage (pièges rencontrés)

| Symptôme | Cause | Correctif |
| --- | --- | --- |
| `pre_deploy` échoue : `sops: command not found` (stacks `lldap`/`authelia`/`smtp-relay`, serveur `Local`) | L'image `komodo-periphery` n'embarque pas `sops` | Monter le binaire `sops` de l'hôte + `SOPS_AGE_KEY_FILE` sur le service `periphery` (déjà fait dans `hosts/vps-prod/stacks/komodo/compose.yaml`) |
| Page de login Komodo affichée **sans aucun champ** à remplir | `KOMODO_HOST` ne correspond pas au domaine réellement routé par Traefik (`komodo.int.vindiesel.vip`) : le frontend appelle une URL non routée | Aligner `KOMODO_HOST` sur le `Host()` du label Traefik de `core` |
| Après un `docker compose up`, le conteneur ne voit pas les variables attendues | Confusion entre `--env-file` (CLI) et `env_file:` (compose) : `--env-file` ne sert **qu'à** l'interpolation `${...}` dans le YAML, ce n'est pas lui qui injecte les variables dans le conteneur | Vérifier que le fichier déclaré par `env_file:` dans le `compose.yaml` (`compose.env` pour `core`/`periphery`, `.env` pour les autres stacks) existe bien et est à jour — c'est lui qui compte pour le conteneur |

---

**Sources :** `hosts/vps-prod/stacks/komodo/compose.yaml`, `komodo/stacks.toml`,
`secrets/vps/komodo.env`, `scripts/bootstrap.sh` du dépôt ·
[Komodo — Backup and Restore](https://komo.do/docs/setup/backup) ·
[Komodo — CLI](https://komo.do/docs/ecosystem/cli).
