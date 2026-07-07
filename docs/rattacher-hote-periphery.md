# Rattacher un hôte (Periphery) au Core

Procédure **rejouable** pour rattacher une machine Docker au Core Komodo unique du VPS en tant que
**Periphery**, et faire gérer ses stacks en GitOps — sans perdre les données. Documentée ici sur
l'exemple **`docker-vindiesel`** (VM Docker à la maison : deux instances Immich + un Traefik local,
en VPN-only).

## Vue d'ensemble

- **Un seul Core** (sur le VPS). Chaque autre hôte n'exécute qu'une **Periphery** pilotée par ce Core.
- **Traefik VPS = edge** : il termine le TLS avec le wildcard `*.int.vindiesel.vip` déjà émis, puis
  **forwarde en HTTP dans le tunnel Tailscale** vers le Traefik local de l'hôte.
- **Traefik local = routeur HTTP pur** : reçoit le trafic du tailnet et dispatche par `Host:` vers les
  services locaux. Pas de certs, pas de token Cloudflare.
- **VPN-only** : les noms `*.int.vindiesel.vip` pointent (DNS) vers l'IP Tailscale du VPS et sont
  filtrés par `ipAllowList 100.64.0.0/10` (voir [Exposer un service en VPN-only](exposer-service-vpn-only.md)).
- **Secrets** : chiffrés SOPS/age dans le repo, rendus en `.env` clair par le hook `pre_deploy` du
  stack, sur la Periphery.

```
Internet/Tailscale ──443──▶ Traefik VPS (edge, TLS *.int) ──HTTP tailnet──▶ Traefik local ──▶ service
```

!!! note "Poule / œuf : la Periphery ne se déploie pas via Komodo"
    Un hôte ne peut pas s'auto-enrôler par GitOps (comme le Core, qui s'amorce à la main). Le
    rattachement passe par un **script versionné** (`scripts/bootstrap-periphery.sh`) lancé une fois
    sur la machine, puis par une **acceptation de clé** côté Core (un clic).

## Prérequis

- L'hôte est une VM Docker déjà sur le **tailnet** (Tailscale installé, IP `100.x` stable). Exemple :
  `docker-vindiesel` = `100.65.11.58` ; VPS = `100.67.165.98`.
- **Sauvegarde avant bascule** : les services seront hors ligne le temps du redéploiement.

    ```bash
    # snapshot Proxmox de la VM, puis, sur l'hôte :
    tar czf /root/backup-$(date +%F).tgz /data/immich-1 /data/immich-2
    ```

## 1. Déclarer l'hôte et ses stacks dans le repo

Tout est déclaratif dans `komodo/stacks.toml` (lu par le Core depuis `main`) :

```toml
[[server]]
name = "docker-vindiesel"
[server.config]
enabled = true
address = "https://100.65.11.58:8120"

[[stack]]
name = "immich-1"
description = "Immich photos"
deploy = true
after = ["traefik-vindiesel"]
tags = ["app", "vindiesel"]
[stack.config]
server = "docker-vindiesel"
git_provider = "github.com"
repo = "PortableStick/homelab-infra"
file_paths = ["hosts/vindiesel/stacks/immich-1/compose.yaml"]
pre_deploy.path = "hosts/vindiesel/stacks/immich-1"
pre_deploy.command = "sops -d ../../../../secrets/vindiesel/immich.env > .env"
```

Les composes vivent dans `hosts/vindiesel/stacks/<stack>/compose.yaml` :

- **chemins de données absolus** identiques à l'existant (`/data/immich-1/library`, `.../postgres`),
- labels Traefik **HTTP pur** (`entrypoints=web`, pas de `tls`/`certresolver`/redirect),
- secret DB via `env_file: .env`, avec `DB_PASSWORD` (immich) **et** `POSTGRES_PASSWORD` (postgres),
- le Traefik local publie son port `80` **sur l'IP tailnet** (`100.65.11.58:80:80`).

Côté edge, `hosts/vps-prod/stacks/traefik/compose.yaml` active le **provider fichier**
(`--providers.file.directory=/dynamic`, montage `./dynamic:/dynamic:ro`) et
`hosts/vps-prod/stacks/traefik/dynamic/home-vindiesel.yaml` déclare les routes distantes :

```yaml
http:
  routers:
    immich-photos:
      rule: "Host(`photos.int.vindiesel.vip`)"
      entryPoints: [websecure]
      service: home-vindiesel
      middlewares: [int-vpn]
      tls: {}
  services:
    home-vindiesel:
      loadBalancer:
        servers:
          - url: "http://100.65.11.58:80"
  middlewares:
    int-vpn:
      ipAllowList:
        sourceRange: ["100.64.0.0/10"]
```

Le secret `secrets/vindiesel/immich.env` est chiffré (règle `.sops.yaml` : `secrets/vindiesel/.*.env`).

!!! danger "Le secret doit être NON VIDE avant chiffrement"
    Piège vécu : un `sops -e -i` sur un fichier **vide** produit un secret qui se déchiffre en **rien**
    → `.env` vide → `password authentication failed`. **Toujours** vérifier le contenu clair avant de
    chiffrer :

    ```bash
    printf 'DB_PASSWORD=<mot_de_passe_DB>\nPOSTGRES_PASSWORD=<mot_de_passe_DB>\n' > secrets/vindiesel/immich.env
    cat secrets/vindiesel/immich.env      # DOIT afficher les 2 lignes
    sops -e -i secrets/vindiesel/immich.env
    sops -d secrets/vindiesel/immich.env  # DOIT réafficher les 2 lignes
    ```

    `DB_PASSWORD` doit correspondre au mot de passe **déjà stocké** dans la base Postgres existante
    (Postgres ignore `POSTGRES_PASSWORD` sur une base déjà initialisée).

**Merger le tout sur `main`** (le Core ne lit `stacks.toml` que depuis la branche par défaut).

## 2. Amorcer la Periphery (script)

`scripts/bootstrap-periphery.sh` prépare l'hôte de bout en bout (idempotent) : installe `sops`+`age`,
pose et vérifie la clé privée age, installe la Periphery (binaire + systemd, HTTPS `:8120`, mode
**inbound**), autorise le Core (`core_public_keys`), restreint l'accès au tailnet (`allowed_ips`), et
expose `SOPS_AGE_KEY_FILE` au service (pour le `pre_deploy`).

!!! info "Pourquoi ce script installe `sops` alors que le Core n'en a pas besoin de la sorte"
    Ici la Periphery tourne en **binaire + systemd** directement sur l'hôte : `sops` est donc installé
    sur l'hôte lui-même (étape 1 du script), rien de plus à faire. Sur le VPS, la Periphery du serveur
    `Local` est **conteneurisée** (image `komodo-periphery`, qui n'embarque pas `sops`) : le
    `pre_deploy` `sops -d` de ses stacks a besoin d'un bind-mount du binaire hôte — voir
    [Komodo — pourquoi `sops` est monté à la main](komodo.md#volumes-et-chemins).

Récupérer la **Core Public Key** (UI Komodo du VPS → **Settings**, commence par `MCow…`), puis en root
sur l'hôte :

```bash
CORE_PUBLIC_KEY="MCow...clé_du_Core..." ./scripts/bootstrap-periphery.sh
```

Le script demande de **coller la clé privée age** (depuis Bitwarden) et vérifie qu'elle correspond bien
à la clé publique du repo. Pour un autre hôte, surcharger `CONNECT_AS` (ex. `CONNECT_AS=docker-tyron`).

## 3. Accepter la Periphery côté Core

Comme c'est une install neuve, sa clé publique n'est pas encore approuvée. UI Komodo → **Servers** →
`docker-vindiesel` → **accepter la clé publique tentée** (`attempted_public_key`, elle doit matcher
celle des logs `journalctl -u periphery`). L'état passe à **Ok / connecté**. Le TLS auto-signé de la
Periphery est déjà toléré (`insecure_tls = true` par défaut côté Core).

## 4. Retirer l'ancien déploiement (cas migration)

Si l'hôte tournait déjà avec un ancien Komodo local (Core + Mongo) et des stacks lancés à part :

```bash
# arrêter les 3 stacks (données conservées : jamais de -v)
docker compose ls
docker compose -p immich1 down
docker compose -p immich2 down
docker compose -p <projet_traefik> down

# retirer l'ancien Core + Mongo + ancienne Periphery
cd /data/komodo && docker compose --env-file compose.env -f mongo.compose.yaml down
```

!!! warning "Nettoyer les conflits de noms avant de redéployer"
    Les nouveaux stacks réutilisent les mêmes noms de conteneurs (`immich_server`, `traefik`…) et le
    réseau `proxy`. S'il reste des conteneurs/réseaux de l'ancien déploiement, le deploy échoue en
    `Conflict. The container name "/traefik" is already in use`. Nettoyer (les bind mounts `/data`
    restent intacts) :

    ```bash
    docker rm -f traefik \
      immich_server immich_machine_learning immich_redis immich_postgres \
      immich2_server immich2_machine_learning immich2_redis immich2_postgres 2>/dev/null
    docker network rm proxy backend immich2_backend 2>/dev/null
    ```

## 5. Déployer via le Core (GitOps)

UI Komodo → **Syncs** → `homelab-infra` → **Refresh/Preview** (vérifier qu'il **crée** le serveur + les
stacks et ne **supprime** rien) → **Execute**. Le sync déploie dans l'ordre `after` :
`traefik-vindiesel` → `immich-1` → `immich-2`. À chaque Immich, le `pre_deploy` rend le `.env`
(`sops -d`) puis lance `docker compose up`.

## 6. DNS + vérification VPN-only

| Type | Nom | Valeur | Proxy |
| --- | --- | --- | --- |
| `A` | `photos.int.vindiesel.vip` | `100.67.165.98` (tailnet VPS) | **DNS-only** |
| `A` | `pictures.int.vindiesel.vip` | `100.67.165.98` (tailnet VPS) | **DNS-only** |

```bash
# connecté au tailnet
curl -I https://photos.int.vindiesel.vip     # 200/302 + cert *.int.vindiesel.vip
# hors VPN : injoignable
```

Ouvrir Immich et confirmer que le **nombre de photos est identique** à avant. Mettre à jour l'URL dans
l'app mobile Immich.

## Dépannage (pièges rencontrés)

| Symptôme | Cause | Correctif |
| --- | --- | --- |
| Serveur absent côté Core | `stacks.toml` pas sur `main`, ou sync non exécuté | merger sur `main`, exécuter le sync |
| `password authentication failed for user "postgres"` | `.env` vide (secret chiffré vide) **ou** mot de passe ≠ base | recréer le secret **non vide** (§1) ; sinon réaligner la base : `docker exec -it immich_postgres psql -U postgres -c "ALTER USER postgres PASSWORD '<mdp>';"` |
| `container name "/traefik" already in use` | restes de l'ancien déploiement | nettoyer conteneurs + réseaux (§4) |
| `.env` rendu vide malgré un `pre_deploy` en succès | secret déchiffre en vide (`sops -d` sort rien, `EXIT=0`) | vérifier le contenu clair **avant** `sops -e -i` |

---

**Sources :** `komodo/stacks.toml`, `hosts/vindiesel/stacks/*`, `hosts/vps-prod/stacks/traefik/*`,
`secrets/vindiesel/immich.env`, `scripts/bootstrap-periphery.sh` du dépôt ·
[Komodo — Connect Servers](https://komo.do/docs/setup/connect-servers) ·
[Exposer un service en VPN-only](exposer-service-vpn-only.md) · [Secrets (SOPS/age)](secrets-sops.md).
