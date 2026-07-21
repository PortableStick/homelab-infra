# Obsidian LiveSync (CouchDB)

Synchronisation des coffres [Obsidian](https://obsidian.md/) entre appareils via le plugin
communautaire [Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync). Le plugin tourne
**côté clients** (PC, mobile) : le seul composant serveur est un **CouchDB** dédié, exposé en
**public** sur `obsidian.lucasmasse.net` (obligatoire pour la sync mobile hors du domicile). Déployé
par Komodo sur l'hôte **`vps-prod`** (serveur `Local`) en GitOps.

Sources : `hosts/vps-prod/stacks/obsidian-livesync/`, `secrets/vps/obsidian-livesync.env`,
`komodo/stacks.toml`.

## Composants

| Service | Image | Rôle | Exposition |
| --- | --- | --- | --- |
| `couchdb` | `couchdb:3.5.2@sha256:7feb744b…` (épinglée tag + digest) | Base de sync (une base par coffre, créée par le plugin) | `obsidian.lucasmasse.net` (**public**), port interne `5984` |

- **Réseau** : `frontend` (externe), routé par le Traefik du VPS comme les autres services
  `*.lucasmasse.net` — voir [Reverse proxy & TLS](reverse-proxy-tls.md).
- **Stockage** : bind mount `/data/obsidian-livesync` → `/opt/couchdb/data` (convention `/data/<stack>`).
  À créer avant le 1ᵉʳ déploiement, propriété de l'utilisateur CouchDB de l'image :

    ```bash
    mkdir -p /data/obsidian-livesync && chown -R 5984:5984 /data/obsidian-livesync
    ```

- `restart: unless-stopped`, `user: "5984:5984"` (utilisateur `couchdb` de l'image — **ne pas retirer**,
  voir Dépannage).

## Configuration CouchDB (`local.ini`)

Le fichier `hosts/vps-prod/stacks/obsidian-livesync/local.ini` est monté **en lecture seule** dans
`/opt/couchdb/etc/local.d/`. Il applique les réglages **requis par le plugin** (repris de
[`utils/couchdb/local.ini`](https://github.com/vrtmrz/obsidian-livesync/blob/main/utils/couchdb/local.ini)
du dépôt vrtmrz) :

| Réglage | Rôle |
| --- | --- |
| `single_node = true` | Mode mono-nœud (pas de cluster). |
| `require_valid_user = true` (`chttpd` + `chttpd_auth`) | **Aucun accès anonyme** — toute requête exige l'admin. C'est la seule barrière d'accès, il n'y a pas de forward-auth devant (voir plus bas). |
| `enable_cors` + section `[cors]` | Autorise les origines des clients Obsidian : `app://obsidian.md` (desktop) et `capacitor://localhost` (mobile). Sans ça, le plugin ne peut pas se connecter. |
| `max_document_size` / `max_http_request_size` | Limites relevées pour accepter les gros documents/chunks du plugin. |

L'admin (`COUCHDB_USER` / `COUCHDB_PASSWORD`, depuis le `.env` déchiffré) est écrit par l'entrypoint
de l'image dans `local.d/docker.ini` au démarrage — c'est pour ça que `local.ini` peut rester en
lecture seule.

!!! danger "Public, sans Authelia — c'est voulu"
    Les clients Obsidian (desktop **et** mobile) parlent directement à l'API CouchDB en **Basic auth**.
    Un middleware forward-auth Authelia devant ce domaine **casserait la synchronisation** : ne pas en
    ajouter. La sécurité repose sur `require_valid_user = true` + mot de passe fort (SOPS), le TLS
    wildcard, et idéalement le **chiffrement de bout en bout du plugin** (passphrase E2E — le serveur
    ne voit alors que des blobs chiffrés). **Activer l'E2E est fortement recommandé.**

## Exposition Traefik & DNS

Labels classiques dans `compose.yaml` (routeur `obsidian`, entrypoint `websecure`, `tls=true` — le
wildcard `*.lucasmasse.net` déjà émis est servi, jamais de `certresolver` sur le routeur, cf.
[Reverse proxy & TLS](reverse-proxy-tls.md)) :

```yaml
- "traefik.http.routers.obsidian.rule=Host(`obsidian.lucasmasse.net`)"
- "traefik.http.routers.obsidian.entrypoints=websecure"
- "traefik.http.routers.obsidian.tls=true"
- "traefik.http.services.obsidian.loadbalancer.server.port=5984"
```

**DNS** : créer l'enregistrement `obsidian.lucasmasse.net` → IP du VPS (comme `git.lucasmasse.net`),
s'il n'existe pas déjà.

!!! note "HTTPS valide obligatoire pour le mobile"
    L'app Obsidian mobile (iOS surtout) refuse les connexions non-TLS ou en certificat auto-signé.
    Le wildcard Let's Encrypt production du VPS règle la question.

## Secrets (SOPS/age)

`secrets/vps/obsidian-livesync.env`, chiffré pour la clé age du dépôt (règle `secrets/vps/*.env`,
cf. [Secrets](secrets-sops.md)). Rendu en `.env` par le `pre_deploy` de Komodo, consommé par
`env_file:` du service.

| Variable | Rôle |
| --- | --- |
| `COUCHDB_USER` | Admin CouchDB (aussi l'identifiant saisi dans le plugin). |
| `COUCHDB_PASSWORD` | Mot de passe associé. |

## Déploiement (Komodo)

Entrée `[[stack]] obsidian-livesync` dans `komodo/stacks.toml` : `server = "Local"`,
`after = ["traefik"]`, tags `["app"]`, `pre_deploy` SOPS (même mécanisme que les autres stacks) :

```toml
[[stack]]
name = "obsidian-livesync"
# ...
file_paths = ["hosts/vps-prod/stacks/obsidian-livesync/compose.yaml"]
pre_deploy.path = "hosts/vps-prod/stacks/obsidian-livesync"
pre_deploy.command = "sops -d ../../../../secrets/vps/obsidian-livesync.env > .env"
```

**Ordre :** créer `/data/obsidian-livesync` (chown `5984:5984`) + l'enregistrement DNS, puis déployer
via Komodo (le `pre_deploy` rend le `.env`, `after` garantit que `traefik` est up).

**Vérification :** `curl -u 'obsidian:…' https://obsidian.lucasmasse.net/_up` doit répondre
`{"status":"ok"}`. Sans credentials, un `401` est **normal** (`require_valid_user`).

## Configuration du plugin (côté Obsidian)

Dans Obsidian → *Self-hosted LiveSync* → **Setup wizard** (ou *Remote configuration*) :

- **URI** : `https://obsidian.lucasmasse.net` (sans port ni chemin)
- **Username / Password** : les valeurs de `obsidian-livesync.env`
- **Database name** : au choix, ex. `obsidian` (une base **par coffre** — le plugin la crée tout seul)
- **End-to-end encryption** : activer + passphrase (recommandé, cf. plus haut)

Le bouton **« Check database configuration »** du plugin vérifie les réglages serveur ; tout doit être
vert (les réglages sont déjà appliqués par `local.ini`). Pour rattacher les autres appareils, utiliser
la **Setup URI** chiffrée générée par le premier appareil (*Copy setup URI*) plutôt que de tout
ressaisir.

## Dépannage

| Symptôme | Cause probable | Correctif |
| --- | --- | --- |
| `401 Unauthorized` sur tout | Normal sans credentials (`require_valid_user`) | S'authentifier ; vérifier `COUCHDB_USER`/`COUCHDB_PASSWORD` du `.env` rendu |
| Le plugin ne se connecte pas depuis le mobile mais OK sur PC | CORS : origine `capacitor://localhost` manquante | Vérifier la section `[cors]` de `local.ini` et que le fichier est bien monté |
| « Check database configuration » signale des réglages manquants | `local.ini` non monté ou modifié | Vérifier le bind mount `./local.ini:/opt/couchdb/etc/local.d/local.ini:ro` puis redéployer |
| Erreurs sur gros fichiers / timeouts de sync | Limites de taille trop basses | `max_document_size` / `max_http_request_size` dans `local.ini` |
| Disque qui gonfle avec le temps | Révisions CouchDB accumulées | Lancer une compaction (`POST /<db>/_compact`) ou utiliser *Rebuild everything* du plugin |
| Conteneur en crash-loop au 1ᵉʳ boot | `/data/obsidian-livesync` absent ou mauvais propriétaire | `mkdir -p` + `chown -R 5984:5984` puis redéployer |
| Crash-loop `exit 1` **sans aucun log** | `user: "5984:5984"` retiré du compose : l'entrypoint (root) fait un `find … chown` sur `/opt/couchdb` qui échoue (`set -e`) à cause de `local.ini` monté en `:ro` | Remettre `user: "5984:5984"` (le bloc chown/gosu de l'entrypoint est alors sauté) |

---

**Sources :** `hosts/vps-prod/stacks/obsidian-livesync/` (`compose.yaml`, `local.ini`),
`secrets/vps/obsidian-livesync.env`, `komodo/stacks.toml` du dépôt ·
[Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) ·
[Setup CouchDB (doc du plugin)](https://github.com/vrtmrz/obsidian-livesync/blob/main/docs/setup_own_server.md) ·
[CouchDB — config reference](https://docs.couchdb.org/en/stable/config/index.html).
