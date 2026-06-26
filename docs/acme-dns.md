# acme-dns

[acme-dns](https://github.com/joohoi/acme-dns) est un serveur DNS minimal, dédié **uniquement** à la
résolution des enregistrements `_acme-challenge` pour le challenge DNS-01 de Let's Encrypt. Il évite
de donner à Traefik un accès en écriture à toute la zone DNS : Traefik n'écrit que dans acme-dns.

Source : `hosts/vps-prod/stacks/acme-dns/compose.yaml` et `.../acme-dns/config.cfg`. Déployé par
Komodo (stack `acme-dns`, tag `edge`).

## Conteneur

| Élément | Valeur | Source |
| --- | --- | --- |
| Image | `joohoi/acme-dns:latest` | `compose.yaml` |
| Ports | `116.202.22.50:53:53/udp` **et** `/tcp` | `compose.yaml` |
| Config | `./config.cfg` → `/etc/acme-dns/config.cfg` (ro) | `compose.yaml` |
| Données | `/data/acme-dns` → `/var/lib/acme-dns` (base SQLite) | `compose.yaml` |
| Réseau | `frontend` (externe) | `compose.yaml` |

!!! warning "Image en `:latest`"
    `joohoi/acme-dns:latest` n'est pas épinglée. Pour de la prod, figer un tag/digest précis afin
    d'éviter une mise à jour surprise (cohérent avec la même remarque côté Komodo).

## Configuration (`config.cfg`)

```toml
[general]
listen = "0.0.0.0:53"
protocol = "both"
domain = "acme.vindiesel.vip"
nsname = "acmens.vindiesel.vip"
nsadmin = "admin.vindiesel.vip"
records = [
    "acme.vindiesel.vip. NS acmens.vindiesel.vip.",
    "acmens.vindiesel.vip. A 116.202.22.50",
]
[database]
engine = "sqlite"
connection = "/var/lib/acme-dns/acme-dns.db"
[api]
ip = "0.0.0.0"
port = "80"
tls = "none"
[logconfig]
loglevel = "info"
```

| Clé | Valeur | Signification |
| --- | --- | --- |
| `domain` | `acme.vindiesel.vip` | Zone que acme-dns fait autorité |
| `nsname` | `acmens.vindiesel.vip` | Nom du serveur DNS (NS) de cette zone |
| `nsadmin` | `admin.vindiesel.vip` | Contact admin de la zone (champ SOA) |
| `records` | NS + A | Enregistrements que acme-dns sert lui-même pour sa propre zone |
| `[database]` | SQLite | Base stockée dans le bind `/data/acme-dns` |
| `[api]` | `0.0.0.0:80`, `tls = none` | API HTTP interne (jointe par Traefik via `http://acme-dns` sur le réseau `frontend`) |

!!! danger "`listen = 0.0.0.0:53` vs binding `116.202.22.50` & systemd-resolved"
    En interne, acme-dns écoute sur `0.0.0.0:53` ; mais le **mapping Docker** ne publie le port 53 que
    sur l'IP publique `116.202.22.50` (et pas sur `127.0.0.53`/`0.0.0.0` de l'hôte). C'est ce qui
    permet de cohabiter avec `systemd-resolved` d'Ubuntu, qui occupe le port 53 sur l'interface locale.
    Un commit du dépôt traite explicitement ce conflit (*« Fix pour éviter conflit acme-dns et
    systemd-resolved »*). Si une restauration réactive `systemd-resolved` sur toutes les interfaces,
    le conflit peut revenir.

## Délégation DNS à créer chez Cloudflare (DNS-only)

Pour que le monde extérieur (et donc Let's Encrypt) interroge acme-dns, la zone `vindiesel.vip` chez
Cloudflare doit **déléguer** la sous-zone `acme.vindiesel.vip` vers le serveur acme-dns :

| Type | Nom | Valeur | Proxy |
| --- | --- | --- | --- |
| `NS` | `acme.vindiesel.vip` | `acmens.vindiesel.vip` | DNS-only |
| `A` | `acmens.vindiesel.vip` | `116.202.22.50` | DNS-only (obligatoire : un NS ne peut pas être proxifié) |

Ces deux enregistrements correspondent exactement à ce que `config.cfg` sert dans sa section
`records`. La délégation NS « passe la main » à acme-dns pour tout ce qui est sous `acme.vindiesel.vip`.

## Liaison avec Traefik (CNAME `_acme-challenge`)

Mécanisme acme-dns standard : lors de sa première utilisation, le client ACME (le provider `acme-dns`
de Traefik/lego) **s'enregistre** auprès de l'API acme-dns et reçoit un sous-domaine aléatoire sous
`acme.vindiesel.vip` ainsi que des identifiants, stockés dans `storage.json`
(`/data/traefik/acme-dns/storage.json`). Il faut alors créer, dans la zone du domaine à certifier, un
**CNAME** qui pointe `_acme-challenge` vers ce sous-domaine acme-dns :

Comme on utilise des certificats **wildcard** (`*.lucasmasse.net`, `*.vindiesel.vip`), **un seul**
CNAME par domaine de base suffit — il couvre tous les sous-domaines présents et futurs. Valeurs
réelles posées chez Cloudflare (DNS-only), lues depuis `storage.json` :

| Type | Nom (dans la zone) | Valeur |
| --- | --- | --- |
| `CNAME` | `_acme-challenge.lucasmasse.net` | `a2f5ff5b-dba9-4a7e-9144-9ad40f5ac009.acme.vindiesel.vip` |
| `CNAME` | `_acme-challenge.vindiesel.vip` | `c08c5d9d-12de-4b5e-8f62-4886134fc30d.acme.vindiesel.vip` |

!!! note "Ces CNAME sont permanents"
    Le compte acme-dns créé pour chaque domaine est conservé dans `storage.json` et **réutilisé** à
    chaque renouvellement. Tu ne reposes jamais ces CNAME. Si tu détruis `storage.json`, de nouveaux
    sous-domaines seront générés et il faudra réécrire les CNAME avec les nouvelles valeurs.

!!! warning "Ne crée PAS de CNAME par sous-domaine"
    `storage.json` peut contenir d'anciennes entrées **par hôte** (`git.lucasmasse.net`,
    `portfolio.lucasmasse.net`…), héritées d'une époque où des routers demandaient des certs par hôte.
    Avec le wildcard, elles sont **inutiles** : seuls les CNAME des domaines de base ci-dessus comptent.
    Voir la « règle d'or » dans [Reverse proxy & TLS](reverse-proxy-tls.md).

---

**Sources :** `hosts/vps-prod/stacks/acme-dns/{compose.yaml,config.cfg}` du dépôt ·
[acme-dns (joohoi/acme-dns)](https://github.com/joohoi/acme-dns).
