# Reverse proxy & TLS (Traefik)

Traefik est le reverse proxy en bordure : il termine HTTPS et route vers les conteneurs.

Source : `hosts/vps-prod/stacks/traefik/compose.yaml`. Déployé par Komodo (stack `traefik`, tag `edge`).

## Image et durcissement

| Élément | Valeur |
| --- | --- |
| Image | `traefik:v3.3` |
| Redémarrage | `unless-stopped` |
| Durcissement | `security_opt: no-new-privileges:true` |
| Réseau | `frontend` (externe — voir [Architecture](architecture.md)) |
| Ports | `80:80`, `443:443` |

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

```
--entrypoints.websecure.http.tls.domains[0].main=vindiesel.vip
--entrypoints.websecure.http.tls.domains[0].sans=*.vindiesel.vip
--entrypoints.websecure.http.tls.domains[1].main=lucasmasse.net
--entrypoints.websecure.http.tls.domains[1].sans=*.lucasmasse.net
```

Deux certificats wildcard sont demandés : `vindiesel.vip` (+ `*.vindiesel.vip`) et `lucasmasse.net`
(+ `*.lucasmasse.net`). Les wildcards **imposent** le challenge DNS (impossible en HTTP-01).

## Résolveur ACME (challenge DNS via acme-dns)

```
--certificatesresolvers.letsencrypt.acme.dnschallenge=true
--certificatesresolvers.letsencrypt.acme.dnschallenge.provider=acme-dns
--certificatesresolvers.letsencrypt.acme.email=kastu69@proton.me
--certificatesresolvers.letsencrypt.acme.storage=/acme/acme.json
--certificatesresolvers.letsencrypt.acme.caserver=https://acme-staging-v02.api.letsencrypt.org/directory
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
| Identifiants acme-dns | `/acme-dns/storage.json` (ro) → bind `/data/traefik/acme-dns/storage.json` | `traefik/compose.yaml` |

!!! danger "Actuellement en Let's Encrypt **staging**"
    Le `caserver` pointe sur `acme-staging-v02` : les certificats émis **ne sont pas reconnus par les
    navigateurs** (c'est l'environnement de test, sans limite de taux stricte). C'est volontaire le
    temps de valider la chaîne acme-dns. **Pour passer en production**, remplacer la ligne `caserver`
    par l'endpoint de production de Let's Encrypt :

    ```
    --certificatesresolvers.letsencrypt.acme.caserver=https://acme-v02.api.letsencrypt.org/directory
    ```

    Puis **supprimer l'ancien `acme.json`** (`/data/traefik/acme/acme.json`) qui contient des certs
    staging, sinon Traefik ne re-demandera pas de certs prod. Recréer un `acme.json` vide avec les
    droits `600`.

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
