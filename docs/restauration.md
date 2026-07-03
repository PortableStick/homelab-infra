# Restauration complète

Objectif : remonter l'infrastructure **depuis un VPS nu** après une perte totale. Chaque étape
indique la commande **et** comment vérifier qu'elle a réussi.

!!! danger "Limite actuelle — restauration partielle"
    Une restauration **complète** suppose deux choses qui **n'existent pas encore** :

    1. **Une sauvegarde hors-site de la base Komodo.** Aujourd'hui les sauvegardes sont **locales** au
       VPS ; si le VPS est perdu, elles le sont aussi. La Storage Box Hetzner réservée est **vide**.
       → En l'état, on ne peut **pas** restaurer l'historique Komodo : on **réinitialise** une instance
       Komodo neuve (admin recréé via `KOMODO_INIT_ADMIN_*`), et c'est le **dépôt Git** qui reconstruit
       la configuration des stacks. Les étapes de restauration de base sont marquées
       *(quand backup hors-site disponible)*.
    2. **Le déchiffrement automatique des secrets par Komodo** (non testé). On part donc sur un
       **déchiffrement manuel** (`sops -d`).

## Prérequis (hors VPS)

| Élément | Où | Vérification |
| --- | --- | --- |
| Dépôt `homelab-infra` | GitHub `PortableStick/homelab-infra` | `git clone` fonctionne |
| Clé privée age maître | Bitwarden (break-glass) | `age-keygen -y` redonne `age16jmqm9c…` (voir [Poste de travail](poste-travail-sops-age.md)) |
| Accès DNS | Cloudflare (DNS-only) | Tu peux éditer les zones `vindiesel.vip` et `lucasmasse.net` |
| Sauvegarde base Komodo | *(à venir)* Storage Box Hetzner | **N'existe pas encore** |

## Étapes

### 1. Provisionner l'hôte

Commander un VPS Hetzner sous **Ubuntu Server**. Idéalement réattribuer l'IP `116.202.22.50` (sinon il
faut la remplacer dans `acme-dns/compose.yaml`, `acme-dns/config.cfg` et les enregistrements
Cloudflare). Installer Tailscale.

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

**Vérif :** `tailscale status` montre le nœud connecté ; `ip a` montre l'IP publique attendue.

!!! info "À compléter — durcissement hôte"
    Documenter ici la config réelle : utilisateur non-root, SSH (clé only ?), pare-feu (ufw / Hetzner
    firewall), quels ports ouverts au public (80/443, 53 sur l'IP) vs réservés à Tailscale.

### 2. Installer Docker

Suivre le dépôt officiel Docker pour Ubuntu (méthode utilisée dans l'ancien `Scripts/preparation.sh`
du dépôt `Infra-VPS`) : paquets `docker-ce docker-ce-cli containerd.io docker-buildx-plugin
docker-compose-plugin`.

**Vérif :** `docker version` et `docker compose version` répondent ; `docker run --rm hello-world` OK.

!!! warning "Désactiver le userland-proxy (obligatoire pour les services VPN-only)"
    Écrire `{"userland-proxy": false}` dans `/etc/docker/daemon.json` puis `systemctl restart docker`,
    **avant** de lancer les stacks. Sans ça, l'IP source des clients tailnet est masquée en
    `172.20.0.1` et l'`ipAllowList` des services `*.int.vindiesel.vip` rejette tout en 403. C'est
    fait automatiquement par `scripts/bootstrap.sh` (étape 2b). Voir
    [Exposer un service en VPN-only](exposer-service-vpn-only.md).

    **Vérif :** `docker info --format '{{.Driver}}'` répond, et après déploiement
    `docker logs traefik | grep -i reject` ne montre **pas** `Rejecting IP 172.20.0.1`.

### 3. Libérer le port 53 (pour acme-dns)

Sur Ubuntu, `systemd-resolved` occupe le port 53. acme-dns est mappé uniquement sur `116.202.22.50:53`,
mais il faut s'assurer qu'aucun autre service ne tient ce couple IP:port.

**Vérif :** `sudo ss -ulpn 'sport = :53'` ne montre rien d'autre lié à `116.202.22.50:53`.
Voir [acme-dns](acme-dns.md) pour le contexte du conflit.

### 4. Créer le réseau Docker externe

```bash
docker network create frontend
```

**Vérif :** `docker network ls | grep frontend`.

### 5. Recréer les répertoires de données

```bash
sudo mkdir -p /data/acme-dns /data/traefik/acme /data/traefik/acme-dns /etc/komodo/age
sudo touch /data/traefik/acme/acme.json && sudo chmod 600 /data/traefik/acme/acme.json
```

**Vérif :** les chemins de la section « Chemins de données » de [Architecture](architecture.md)
existent.

### 6. Restaurer la clé privée age

Récupérer la clé depuis Bitwarden et l'écrire sur l'hôte :

```bash
sudo $EDITOR /etc/komodo/age/key.txt      # coller la clé privée
sudo chmod 600 /etc/komodo/age/key.txt
export SOPS_AGE_KEY_FILE=/etc/komodo/age/key.txt
```

**Vérif :** `age-keygen -y /etc/komodo/age/key.txt` affiche
`age16jmqm9c42x330uyvdf07lq2qy892c7hdj96t6dw4m9rmhy4cw96spyc5cr`.

### 7. Cloner le dépôt sous la racine Periphery

Le dépôt doit être sous le répertoire racine Periphery (`/etc/komodo` par défaut, voir
[Komodo](komodo.md)).

```bash
cd /etc/komodo
sudo git clone https://github.com/PortableStick/homelab-infra.git
```

**Vérif :** `ls /etc/komodo/homelab-infra/hosts/vps-prod/stacks` liste `acme-dns traefik komodo whoami`.

### 8. Rendre le `compose.env` de Komodo (déchiffrement manuel)

```bash
cd /etc/komodo/homelab-infra
sops -d secrets/vps/komodo.env > hosts/vps-prod/stacks/komodo/compose.env
chmod 600 hosts/vps-prod/stacks/komodo/compose.env
```

**Vérif :** le fichier `compose.env` contient des valeurs **en clair** (plus de `ENC[`).

### 9. Bootstrapper Komodo (Core + Periphery + base)

```bash
cd /etc/komodo/homelab-infra/hosts/vps-prod/stacks/komodo
docker compose up -d
```

**Vérif :** `docker compose ps` montre `postgres`, `ferretdb`, `core`, `periphery` en route ; l'UI
répond sur `http://<hôte>:9120` (ou via Tailscale). Connexion avec
`KOMODO_INIT_ADMIN_USERNAME`/`KOMODO_INIT_ADMIN_PASSWORD` (issus du secret).

### 10. Restaurer la base Komodo *(quand backup hors-site disponible)*

!!! warning "Étape non réalisable aujourd'hui (pas de backup hors-site)"
    Tant que la Storage Box n'est pas alimentée, **sauter cette étape** : Komodo démarre vide et l'admin
    est recréé par les variables `KOMODO_INIT_ADMIN_*`. Quand un backup existera :

    ```bash
    # Récupérer le dossier de backup depuis la Storage Box vers /data/komodo/backups
    # puis restaurer avec la CLI Komodo (base cible vide impérativement)
    docker run --rm \
      -v /data/komodo/backups:/backups \
      -e KOMODO_CLI_DATABASE_TARGET_ADDRESS=ferretdb:27017 \
      -e KOMODO_CLI_DATABASE_TARGET_USERNAME=<db user> \
      -e KOMODO_CLI_DATABASE_TARGET_PASSWORD=<db pass> \
      -e KOMODO_CLI_DATABASE_TARGET_DB_NAME=komodo \
      ghcr.io/moghtech/komodo-cli km database restore -y
    ```

    Voir [Komodo — Backup and Restore](https://komo.do/docs/setup/backup). Rappel : `restore` ne vide
    pas la base cible — restaurer dans une base vide.

### 11. Laisser Komodo appliquer le resource sync

Une fois Komodo en route, le **resource sync `homelab-infra`** (défini dans `komodo/stacks.toml`)
applique la configuration et déploie les stacks `acme-dns` et `traefik` depuis GitHub.

!!! info "À compléter — déclenchement du 1er sync"
    Préciser ici le geste exact réalisé au premier boot (création/validation du resource sync via l'UI
    Komodo, ou via la connexion du compte Git + token de lecture). C'est l'étape « manuelle » de
    démarrage du GitOps qui n'est pas auto-documentée par le dépôt.

**Vérif :** dans l'UI Komodo, le sync est *in sync* ; `docker ps` montre `acme-dns` et `traefik`.

### 12. Vérifier le DNS et obtenir les certificats

1. Délégation chez Cloudflare : `NS acme.vindiesel.vip → acmens.vindiesel.vip` et
   `A acmens.vindiesel.vip → 116.202.22.50` (voir [acme-dns](acme-dns.md)).
2. CNAME `_acme-challenge.*` vers le sous-domaine acme-dns généré (lisible dans `storage.json`).

**Vérif :**

```bash
dig +short NS acme.vindiesel.vip
dig +short A acmens.vindiesel.vip            # -> 116.202.22.50
docker logs traefik 2>&1 | grep -i acme       # suivi de l'obtention des certs
```

### 13. Passer Let's Encrypt en production *(quand la chaîne staging est validée)*

Voir [Reverse proxy & TLS](reverse-proxy-tls.md) : remplacer le `caserver` staging par
`https://acme-v02.api.letsencrypt.org/directory`, supprimer l'ancien `acme.json` (certs staging),
recréer un `acme.json` vide `600`, redéployer Traefik.

**Vérif :** un navigateur affiche un certificat valide (émis par Let's Encrypt, pas « staging »).

## Ordre résumé

```text
1 hôte+Tailscale → 2 Docker (+ userland-proxy off) → 3 port 53 → 4 réseau frontend → 5 dossiers /data
→ 6 clé age → 7 clone repo → 8 sops -d compose.env → 9 docker compose up komodo
→ 10 restore DB (si backup) → 11 resource sync → 12 DNS + certs → 13 LE prod
```

---

**Sources :** dépôt `homelab-infra` (compose, `komodo/stacks.toml`, `secrets/`, `.sops.yaml`) ·
ancien `Infra-VPS/Scripts/preparation.sh` (méthode Docker/Tailscale) ·
[Komodo — Backup and Restore](https://komo.do/docs/setup/backup) ·
[Tailscale — install](https://tailscale.com/download).
