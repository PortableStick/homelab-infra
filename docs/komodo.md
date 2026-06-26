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
| `periphery` | `ghcr.io/moghtech/komodo-periphery:${COMPOSE_KOMODO_IMAGE_TAG:-2}` | Agent qui exécute Docker sur l'hôte | Accède à `docker.sock`, `/proc`, et au répertoire racine Periphery. Dépend de `core`. |

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

!!! info "Le répertoire racine Periphery doit être identique dedans et dehors"
    Le compose le rappelle : le chemin doit être le **même** à l'intérieur et à l'extérieur du
    conteneur, sinon Docker se mélange (réf. discussion Komodo #180 citée en commentaire). Défaut :
    `/etc/komodo`.

## Secrets (compose.env)

Le Core et la Periphery chargent leurs variables via `env_file: ./compose.env`. Ce fichier
**n'est pas dans Git** : il est produit en déchiffrant `secrets/vps/komodo.env` (SOPS/age).

Variables présentes dans `secrets/vps/komodo.env` (noms visibles, valeurs chiffrées) :

`COMPOSE_KOMODO_IMAGE_TAG`, `COMPOSE_KOMODO_BACKUPS_PATH`, `KOMODO_DATABASE_USERNAME`,
`KOMODO_DATABASE_PASSWORD`, `TZ`, `KOMODO_HOST`, `KOMODO_TITLE`, `KOMODO_PERIPHERY_PUBLIC_KEY`,
`KOMODO_LOCAL_AUTH`, `KOMODO_INIT_ADMIN_USERNAME`, `KOMODO_INIT_ADMIN_PASSWORD`,
`KOMODO_FIRST_SERVER_NAME`, `KOMODO_DISABLE_CONFIRM_DIALOG`, `KOMODO_DISABLE_INIT_RESOURCES`,
`KOMODO_WEBHOOK_SECRET`, `KOMODO_JWT_SECRET`, `KOMODO_JWT_TTL`, `KOMODO_MONITORING_INTERVAL`,
`KOMODO_RESOURCE_POLL_INTERVAL`, `KOMODO_DISABLE_USER_REGISTRATION`.

```bash
# Rendu du compose.env à partir du secret chiffré (étape manuelle actuelle)
sops -d secrets/vps/komodo.env > hosts/vps-prod/stacks/komodo/compose.env
```

!!! warning "Bootstrap manuel, pas géré par Komodo lui-même"
    La stack Komodo (Core + Periphery + base) **ne figure pas** dans la liste des `[[stack]]` de
    `komodo/stacks.toml` : Komodo ne se déploie pas lui-même. Au premier boot, on lance Komodo **à la
    main** (`docker compose up -d` dans `hosts/vps-prod/stacks/komodo/`), après avoir rendu
    `compose.env`. Ensuite seulement, Komodo reprend la main sur les autres stacks via le resource
    sync. Voir [Restauration complète](restauration.md).

## GitOps : `komodo/stacks.toml`

Ce fichier est la **source de vérité** que Komodo applique. Il déclare :

- **Serveur `Local`** (`enabled = true`) : la Periphery locale, même hôte que le Core.
- **Repo `homelab-infra`** lié à `PortableStick/homelab-infra`, builder `Local`.
- **Builder `Local`** de type `Server`.
- **Resource sync `homelab-infra`** : `linked_repo = "homelab-infra"`,
  `resource_path = ["komodo/stacks.toml"]`, **`delete = true`**.
- Les **stacks** déployées par Komodo : `acme-dns` et `traefik` (tags `edge`), chacune pointant vers
  son `compose.yaml` dans `hosts/vps-prod/stacks/...`.
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

---

**Sources :** `hosts/vps-prod/stacks/komodo/compose.yaml`, `komodo/stacks.toml`,
`secrets/vps/komodo.env` du dépôt · [Komodo — Backup and Restore](https://komo.do/docs/setup/backup) ·
[Komodo — CLI](https://komo.do/docs/ecosystem/cli).
