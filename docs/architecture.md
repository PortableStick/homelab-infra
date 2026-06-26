# Architecture

## Hôte

| Élément | Valeur | Source |
| --- | --- | --- |
| Nom logique (Komodo) | `vps-prod` | `komodo/stacks.toml` (serveur `Local`) / ancien `komodo/server.toml` du dépôt `infra` |
| Fournisseur | VPS Hetzner | indiqué par l'opérateur ; commentaire « VPS Hetzner — OS nu + Docker » (dépôt `infra`) |
| OS | Ubuntu Server | indiqué par l'opérateur |
| Adresse IP publique | `116.202.22.50` | `hosts/vps-prod/stacks/acme-dns/compose.yaml` et `.../acme-dns/config.cfg` |
| Moteur conteneurs | Docker + Docker Compose | tous les stacks sont des `compose.yaml` |
| Accès admin | Tailscale installé sur le VPS | indiqué par l'opérateur |

!!! note "Komodo : serveur « Local »"
    Dans `homelab-infra`, le serveur déclaré dans `komodo/stacks.toml` s'appelle **`Local`**
    (la Periphery tourne sur le même hôte que le Core). Le nom `vps-prod` venait de l'étape
    intermédiaire (dépôt `infra`, fichier `komodo/server.toml`). À uniformiser si besoin — voir
    [Komodo](komodo.md).

## Réseau Docker

Les stacks exposées (`acme-dns`, `traefik`) partagent un réseau Docker **externe** nommé `frontend` :

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

*(Source : `hosts/vps-prod/stacks/{acme-dns,traefik}/compose.yaml`. La commande de création est la
commande Docker standard pour un réseau externe.)*

## Domaines & DNS

| Domaine | Usage | Source |
| --- | --- | --- |
| `vindiesel.vip` | Domaine principal + wildcard `*.vindiesel.vip` (certs Traefik) | `traefik/compose.yaml` |
| `lucasmasse.net` | Domaine secondaire + wildcard `*.lucasmasse.net` (certs Traefik) | `traefik/compose.yaml` |
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
| 9120 | TCP | Komodo Core (UI/API) | toutes interfaces | `komodo/compose.yaml` |
| 8081 | TCP | whoami (stack de test) | toutes interfaces | `whoami/compose.yaml` |

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

Komodo utilise par ailleurs des **volumes Docker nommés** (`postgres-data`, `ferretdb-state`, `keys`)
et deux chemins paramétrés par variables (`${COMPOSE_KOMODO_BACKUPS_PATH}` pour les sauvegardes,
`${PERIPHERY_ROOT_DIRECTORY:-/etc/komodo}` pour la Periphery). Détails dans [Komodo](komodo.md).

!!! info "À compléter — valeurs réelles des chemins paramétrés"
    Les valeurs déchiffrées de `COMPOSE_KOMODO_BACKUPS_PATH` et `PERIPHERY_ROOT_DIRECTORY` vivent dans
    `secrets/vps/komodo.env` (chiffré). Renseigner ici les chemins réels une fois confirmés, car ils
    sont nécessaires à la restauration.
