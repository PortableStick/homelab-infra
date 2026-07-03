# Reverse proxy & TLS (Traefik)

Traefik est le reverse proxy en bordure : il termine HTTPS et route vers les conteneurs.

Source : `hosts/vps-prod/stacks/traefik/compose.yaml`. Déployé par Komodo (stack `traefik`, tag `edge`).

## Image et durcissement

| Élément | Valeur |
| --- | --- |
| Image | `traefik:v3.6` |
| Redémarrage | `unless-stopped` |
| Durcissement | `security_opt: no-new-privileges:true` |
| Réseau | `frontend` (externe — voir [Architecture](architecture.md)) |
| Ports | `80:80`, `443:443` |

!!! note "Pourquoi `v3.6` (et non `v3.3`)"
    Traefik v3.6+ **auto-négocie la version de l'API Docker**. Sans ça, le client Docker embarqué
    force l'API `1.24`, refusée par Docker 29+ (qui exige `>= 1.40`) — d'où l'erreur
    *« client version 1.24 is too old »*. Le tag `v3.6` suit les correctifs de la branche 3.6 sans
    saut de version mineure (important car la procédure `GlobalAutoUpdate` tire les images chaque nuit).

## Découverte des services (provider Docker)

```
--providers.docker=true
--providers.docker.exposedbydefault=false
--providers.docker.network=frontend
```

- `exposedbydefault=false` : un conteneur n'est exposé que s'il porte explicitement
  `traefik.enable=true` dans ses labels. C'est le comportement sûr (rien n'est publié par accident).
- `providers.docker.network=frontend` : Traefik joint les services via le réseau `frontend`.

## Entrypoints et redirection HTTPS

```
--entrypoints.web.address=:80
--entrypoints.websecure.address=:443
--entrypoints.web.http.redirections.entrypoint.to=websecure
--entrypoints.web.http.redirections.entrypoint.scheme=https
--entrypoints.websecure.http.tls.certresolver=letsencrypt
```

Tout le trafic HTTP (`:80`) est redirigé en HTTPS (`:443`). L'entrypoint `websecure` utilise par
défaut le resolver de certificats **`letsencrypt`**.

!!! note "Nom du resolver : `letsencrypt`"
    Le resolver s'appelait `letencrypt` (faute de frappe) dans une version précédente ; il a été
    corrigé en `letsencrypt`. Comme un changement de nom de resolver invalide les entrées stockées
    sous l'ancien nom dans `acme.json`, Traefik régénère les certificats sous le nouveau nom.

## Certificats wildcard

**Trois** certificats wildcard sont demandés : `*.vindiesel.vip`, `*.lucasmasse.net` et
`*.int.vindiesel.vip` (zone interne VPN-only). Les wildcards **imposent** le challenge DNS (impossible
en HTTP-01).

### Où la génération est déclenchée : le routeur générateur

La génération n'est **pas** portée par les services applicatifs, mais par un **routeur générateur
dédié** dans la stack `whoami` (`hosts/vps-prod/stacks/whoami/compose.yaml`) :

```yaml
- "traefik.http.routers.wildcard-generator.rule=Host(`cert.vindiesel.vip`)"
- "traefik.http.routers.wildcard-generator.service=noop@internal"   # ne sert rien : juste le déclencheur
- "traefik.http.routers.wildcard-generator.tls=true"
- "traefik.http.routers.wildcard-generator.tls.certresolver=letsencrypt"
- "traefik.http.routers.wildcard-generator.tls.domains[0].main=vindiesel.vip"
- "traefik.http.routers.wildcard-generator.tls.domains[0].sans=*.vindiesel.vip"
- "traefik.http.routers.wildcard-generator.tls.domains[1].main=lucasmasse.net"
- "traefik.http.routers.wildcard-generator.tls.domains[1].sans=*.lucasmasse.net"
- "traefik.http.routers.wildcard-generator.tls.domains[2].main=int.vindiesel.vip"
- "traefik.http.routers.wildcard-generator.tls.domains[2].sans=*.int.vindiesel.vip"
```

C'est le **seul** routeur qui porte `certresolver` **et** `tls.domains`. Son `service=noop@internal`
ne route vers rien (un accès à `cert.vindiesel.vip` renvoie un 404 — normal, personne n'y va) : son
unique rôle est de faire émettre les trois wildcards. `traefik/compose.yaml` déclare aussi ces
domaines au niveau de l'entrypoint `websecure` ; c'est redondant avec le générateur (d'où le
warning bénin *« Domain … is duplicated »* dans les logs), mais sans danger.

!!! warning "Règle d'or : `certresolver` + `tls.domains` UNIQUEMENT sur le routeur générateur"
    Un service applicatif doit se contenter de `traefik.enable=true`, sa règle `Host(...)`,
    `entrypoints=websecure`, `tls=true` (nu) et son port — **sans** `tls.certresolver`. Il consomme
    alors le wildcard déjà émis.

    Si un router de service ajoute `tls.certresolver=...`, Traefik demande un **certificat par hôte**
    (un challenge DNS + un CNAME `_acme-challenge` par sous-domaine) au lieu d'utiliser le wildcard.
    Pire, si le nom du résolveur ne correspond pas exactement (`letsencrypt`), le router tombe en
    erreur *« nonexistent certificate resolver »* et ne sert aucun certificat. C'est précisément ce
    qui a bloqué la mise en place initiale (et ce qui donnait des certs par hôte à `git`/`portfolio`).

    Pour ajouter une nouvelle zone wildcard : **une ligne** `tls.domains[n]` sur le générateur **+**
    un CNAME `_acme-challenge.<zone>` vers le sous-domaine acme-dns (voir [acme-dns](acme-dns.md)).

## Résolveur ACME (challenge DNS via acme-dns)

```
--certificatesresolvers.letsencrypt.acme.dnschallenge=true
--certificatesresolvers.letsencrypt.acme.dnschallenge.provider=acme-dns
--certificatesresolvers.letsencrypt.acme.email=kastu69@proton.me
--certificatesresolvers.letsencrypt.acme.storage=/acme/acme.json
--certificatesresolvers.letsencrypt.acme.caserver=https://acme-v02.api.letsencrypt.org/directory
```

Le provider DNS est **`acme-dns`** (serveur DNS auto-hébergé, voir [acme-dns](acme-dns.md)). Traefik
parle à acme-dns via deux variables d'environnement :

```yaml
environment:
  - ACME_DNS_API_BASE=http://acme-dns
  - ACME_DNS_STORAGE_PATH=/acme-dns/storage.json
```

| Élément | Valeur | Source |
| --- | --- | --- |
| Email ACME | `kastu69@proton.me` | `traefik/compose.yaml` |
| Stockage certs | `/acme/acme.json` → bind `/data/traefik/acme` | `traefik/compose.yaml` |
| API acme-dns | `http://acme-dns` (réseau `frontend`) | `traefik/compose.yaml` |
| Comptes acme-dns | `/acme-dns/storage.json` (**lecture-écriture**) → bind `/data/traefik/acme-dns/storage.json` | `traefik/compose.yaml` |

!!! success "En production"
    Le `caserver` pointe sur l'endpoint **production** de Let's Encrypt
    (`acme-v02`) : les certificats wildcard sont **valides et reconnus par les navigateurs**.

!!! note "Bascule staging → production (historique / si à refaire)"
    Le déploiement a d'abord été validé en **staging** (`acme-staging-v02`, sans limite de débit
    stricte), puis basculé en production. Si tu dois refaire la manip un jour :

    1. Remplacer le `caserver` par `https://acme-v02.api.letsencrypt.org/directory`.
    2. **Vider** `/data/traefik/acme/acme.json` (il contient le compte + les certs staging, sinon
       Traefik ne re-demande rien) puis recréer un fichier vide en `600` :
       `rm -f /data/traefik/acme/acme.json && install -m 600 /dev/null /data/traefik/acme/acme.json`.
    3. Recréer le conteneur Traefik.

    ⚠️ La prod a des **limites de débit strictes** : on valide toujours le challenge en staging
    **avant** de basculer, pour ne pas se faire bloquer sur une config cassée.

## Volumes

| Bind hôte | Conteneur | Rôle |
| --- | --- | --- |
| `/var/run/docker.sock` (ro) | `/var/run/docker.sock` | Découverte des conteneurs |
| `/data/traefik/acme` | `/acme` | Stockage `acme.json` (certificats + clés) |
| `/data/traefik/acme-dns/storage.json` | `/acme-dns/storage.json` | Comptes/sous-domaines acme-dns — **en lecture-écriture** (le provider y écrit lors de l'enregistrement). Doit exister comme **fichier** avant le `up`, sinon Docker crée un dossier. |

!!! info "À compléter — tableau de bord Traefik"
    L'étape intermédiaire (dépôt `infra`) exposait un dashboard Traefik protégé par basicauth sur
    `traefik-dashboard.lucasmasse.net`. Le `compose.yaml` actuel de `homelab-infra` **n'expose pas** de
    dashboard. Documenter ici si/quand il est réactivé.

---

**Sources :** `hosts/vps-prod/stacks/traefik/compose.yaml` du dépôt ·
[Traefik — ACME / certificatesResolvers](https://doc.traefik.io/traefik/https/acme/) ·
endpoints Let's Encrypt : [letsencrypt.org — ACME staging environment](https://letsencrypt.org/docs/staging-environment/).
