# Architecture

## Hôtes

Trois hôtes, trois serveurs Komodo distincts (`komodo/stacks.toml`) :

| Élément | `vps-prod` (serveur `Local`) | `vindiesel` (serveur `docker-vindiesel`) | `tyron` (serveur `docker-tyron`) |
| --- | --- | --- | --- |
| Rôle | Core + Periphery Komodo, edge public (Traefik, acme-dns), Forgejo, portfolio, stack auth | Periphery distante rattachée au Core, hébergement Immich (2 instances) derrière un Traefik maison | Periphery distante, seedbox (rTorrent derrière ProtonVPN), Jellyfin, Filestash |
| Fournisseur | VPS Hetzner | machine personnelle (« maison ») | VM Docker sur l'hôte Proxmox `tyron` (« maison ») |
| OS | Ubuntu Server | indiqué par l'opérateur | Debian 13 (trixie) |
| Adresse | IP publique `116.202.22.50` | jointe via Tailscale (`https://100.65.11.58:8120` pour la Periphery) | jointe via Tailscale (`https://100.92.25.102:8120` pour la Periphery), LAN `192.168.1.21` |
| Moteur conteneurs | Docker + Docker Compose | Docker + Docker Compose | Docker + Docker Compose |
| Réseau Docker externe | `frontend` | `proxy` | `proxy` |

*(Source : `komodo/stacks.toml`, `hosts/vps-prod/`, `hosts/vindiesel/`, `hosts/tyron/`.)* Le rattachement d'un nouvel
hôte Periphery suit une procédure documentée : voir [Rattacher un hôte (Periphery)](rattacher-hote-periphery.md).
`vindiesel` (Traefik maison + Immich) n'a pas encore de page dédiée ; `tyron` est documenté par
service : [Seedbox](seedbox.md), [Jellyfin](jellyfin.md), [Filestash](filestash.md).

!!! note "Komodo : serveur « Local »"
    Dans `homelab-infra`, le serveur qui porte le Core Komodo s'appelle **`Local`**
    (la Periphery tourne sur le même hôte que le Core). Le nom `vps-prod` venait de l'étape
    intermédiaire (dépôt `infra`, fichier `komodo/server.toml`). À uniformiser si besoin — voir
    [Komodo](komodo.md).

## Réseau Docker

Sur `vps-prod`, toutes les stacks exposées via Traefik (`acme-dns`, `traefik`, `portfolio`, `forgejo`,
`whoami`, `komodo`, et la stack auth `lldap`/`authelia`/`smtp-relay`) partagent un réseau Docker
**externe** nommé `frontend` :

```yaml
networks:
  frontend:
    name: frontend
    external: true
```

`external: true` signifie que **Docker ne crée pas ce réseau** : il doit déjà exister sur l'hôte,
sinon `docker compose up` échoue. Il faut donc le créer une fois, manuellement, avant de déployer
quoi que ce soit :

```bash
docker network create frontend
```

*(Source : `hosts/vps-prod/stacks/*/compose.yaml`. La commande de création est la commande Docker
standard pour un réseau externe.)*

Sur `vindiesel` **et** sur `tyron`, l'équivalent est un réseau externe `proxy`
(`hosts/vindiesel/stacks/traefik/compose.yaml`, `hosts/tyron/stacks/traefik/compose.yaml`), propre à
chaque hôte — ces réseaux ne communiquent pas entre eux malgré leur nom identique.

## Domaines & DNS

| Domaine | Usage | Source |
| --- | --- | --- |
| `vindiesel.vip` | Domaine principal + wildcard `*.vindiesel.vip` (certs Traefik) | `traefik/compose.yaml` |
| `lucasmasse.net` | Domaine secondaire + wildcard `*.lucasmasse.net` (certs Traefik) | `traefik/compose.yaml` |
| `int.vindiesel.vip` | Zone **interne VPN-only** + wildcard `*.int.vindiesel.vip`. Tout service sous ce nom pointe vers l'IP Tailscale et n'est joignable que sur le tailnet (voir [Exposer un service en VPN-only](exposer-service-vpn-only.md)) | `whoami/compose.yaml` (générateur), `komodo/compose.yaml` |
| `acme.vindiesel.vip` | Zone déléguée à acme-dns pour le challenge ACME | `acme-dns/config.cfg` |
| `acmens.vindiesel.vip` | Serveur de noms (NS) de la zone acme, pointant vers `116.202.22.50` | `acme-dns/config.cfg` |

Les zones DNS sont gérées chez **Cloudflare en mode DNS-only** (pas de proxy « orange cloud »),
d'après l'opérateur. Le mode DNS-only est nécessaire ici car :

- le challenge DNS ACME doit pouvoir résoudre publiquement les enregistrements `_acme-challenge`
  via la délégation vers acme-dns ;
- acme-dns écoute directement sur l'IP publique du VPS (port 53), donc la délégation NS doit pointer
  vers cette IP sans interposition de Cloudflare.

Voir [acme-dns](acme-dns.md) pour les enregistrements de délégation exacts à créer chez Cloudflare.

## Ports exposés sur l'hôte

| Port | Protocole | Service | Liaison | Source |
| --- | --- | --- | --- | --- |
| 53 | UDP + TCP | acme-dns | **uniquement** sur `116.202.22.50` | `acme-dns/compose.yaml` |
| 80 | TCP | Traefik (HTTP, redirige vers HTTPS) | toutes interfaces | `traefik/compose.yaml` |
| 443 | TCP | Traefik (HTTPS) | toutes interfaces | `traefik/compose.yaml` |

!!! note "Komodo et whoami ne publient plus de port sur l'hôte"
    Komodo Core (`9120`) et whoami (anciennement `8081`) **n'exposent plus de port** : leurs blocs
    `ports:` sont commentés. On les atteint désormais **uniquement via Traefik** (réseau `frontend`) :
    Komodo sur `komodo.int.vindiesel.vip` en VPN-only, whoami sur ses trois noms de test. Voir
    [Exposer un service en VPN-only](exposer-service-vpn-only.md).

!!! warning "acme-dns sur le port 53 et systemd-resolved"
    Un commit du dépôt corrige un conflit entre acme-dns (port 53) et `systemd-resolved`
    (*« Fix pour éviter conflit acme-dns et systemd-resolved »*). Sur Ubuntu Server, `systemd-resolved`
    occupe le port 53 par défaut ; il faut le libérer pour qu'acme-dns puisse écouter dessus. Le
    binding est volontairement restreint à l'IP publique `116.202.22.50` (et non `0.0.0.0`) pour cette
    raison. Voir [acme-dns](acme-dns.md).

## Chemins de données sur l'hôte (bind mounts)

Ces chemins persistent les données hors des conteneurs. Ils doivent exister (ou être recréés) sur
l'hôte lors d'une restauration.

| Chemin hôte | Monté dans | Service | Source |
| --- | --- | --- | --- |
| `/data/acme-dns` | `/var/lib/acme-dns` | acme-dns (base SQLite) | `acme-dns/compose.yaml` |
| `/data/traefik/acme` | `/acme` | Traefik (stockage des certificats `acme.json`) | `traefik/compose.yaml` |
| `/data/traefik/acme-dns/storage.json` | `/acme-dns/storage.json` | Traefik (comptes acme-dns, **lecture-écriture**) | `traefik/compose.yaml` |
| `/var/run/docker.sock` | `/var/run/docker.sock` | Traefik (ro) et Komodo Periphery | `traefik/` et `komodo/compose.yaml` |
| `/data/authelia` | `/data` | Authelia (base SQLite, clé de signature OIDC) | `authelia/compose.yaml` |
| `/data/lldap` | `/data` | lldap (annuaire) | `lldap/compose.yaml` |
| `/srv/seedbox` | `/data`, `/downloads`, `/passwd` | seedbox — **disque dédié de 700 Go** (`/dev/sdb`) monté par UUID sur `tyron` | `tyron/stacks/seedbox/compose.yaml` |
| `/data/seedbox/gluetun` | `/gluetun` | gluetun (état VPN, port forwardé) | `tyron/stacks/seedbox/compose.yaml` |
| `/data/jellyfin/{config,cache}` | `/config`, `/cache` | Jellyfin (base + transcodage) | `tyron/stacks/jellyfin/compose.yaml` |
| `/data/filestash` | `/app/data/state` | Filestash (config, mot de passe admin) | `tyron/stacks/filestash/compose.yaml` |

Komodo utilise par ailleurs des **volumes Docker nommés** (`postgres-data`, `ferretdb-state`, `keys`)
et deux chemins paramétrés par variables (`${COMPOSE_KOMODO_BACKUPS_PATH}` pour les sauvegardes,
`${PERIPHERY_ROOT_DIRECTORY:-/etc/komodo}` pour la Periphery). Détails dans [Komodo](komodo.md).

!!! info "Valeurs réelles des chemins paramétrés"
    Confirmées le 2026-09-11 en déchiffrant `secrets/vps/komodo.env` — nécessaires à la restauration :

    | Variable | Valeur sur `vps-prod` |
    | --- | --- |
    | `COMPOSE_KOMODO_BACKUPS_PATH` | `/etc/komodo/backups` |
    | `PERIPHERY_ROOT_DIRECTORY` | `/etc/komodo` |

    Les sauvegardes de la base vivent donc **sous la racine Periphery**, sur le disque système du
    VPS. C'est le point aveugle rappelé en page d'accueil : une perte du VPS emporte la base **et**
    ses sauvegardes tant que la copie hors-site n'est pas en place, voir
    [Restauration complète](restauration.md).

## Authentification

Trois stacks (`lldap`, `authelia`, `smtp-relay`, tag `auth` dans `komodo/stacks.toml`) forment le
socle SSO/2FA de l'infra : portail Authelia public sur `auth.vindiesel.vip`, backend lldap en
VPN-only (`ldap.int.vindiesel.vip`), mails via smtp-relay (→ Brevo). Komodo s'authentifie désormais en
OIDC auprès d'Authelia. Détails complets : [Authelia (SSO / 2FA)](authelia.md).
