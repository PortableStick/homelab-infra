# Filestash (gestionnaire de fichiers)

Explorateur de fichiers web donnant accès au disque de la [seedbox](seedbox.md) : parcourir,
téléverser, télécharger, prévisualiser. Déployé par Komodo sur l'hôte **`tyron`** (serveur
`docker-tyron`), exposé en public sur `filestash.vindiesel.vip`, **derrière Authelia (2FA)**.

Sources : `hosts/tyron/stacks/filestash/compose.yaml`,
`hosts/vps-prod/stacks/traefik/dynamic/home-tyron.yaml`, `komodo/stacks.toml`.

## Composant

| Service | Image | Rôle | Exposition |
| --- | --- | --- | --- |
| `filestash` | `machines/filestash:latest@sha256:1494ecd7…` | Gestionnaire de fichiers web | `filestash.vindiesel.vip` (public, **derrière Authelia**), port interne `8334` |

| Chemin hôte | Monté dans | Rôle |
| --- | --- | --- |
| `/data/filestash` | `/app/data/state` | Configuration Filestash : mot de passe admin, backends déclarés, sessions |
| `/srv/seedbox/downloads` | `/srv/seedbox/downloads` | `temp/` (en cours) et `complete/` (terminés), en **lecture-écriture** |
| `/srv/seedbox/config/rtorrent/watch` | `/srv/seedbox/watch` | Dépôt de `.torrent` — rTorrent les charge automatiquement |

!!! tip "Le disque n'est PAS monté en entier — c'est délibéré"
    Le backend local pointe sur `/srv/seedbox`, qui ne contient **dans le conteneur** que
    `downloads/` et `watch/`. La session rTorrent et la configuration ruTorrent
    (`/srv/seedbox/config/`) restent invisibles : une suppression accidentelle depuis l'interface
    y casserait tous les torrents en cours. Le dossier de surveillance, lui, est remonté à la
    racine pour rester à portée de main alors qu'il vit sous `config/rtorrent/watch/`.

À créer avant le premier déploiement — **avec le bon propriétaire** :

```bash
mkdir -p /data/filestash
chown -R 1000:1000 /data/filestash
```

!!! danger "Le `chown` n'est pas optionnel"
    L'image tourne en **uid 1000** et `/app/data/state` y est **vide** : c'est Filestash qui
    crée son arborescence (`log/`, `config/`, `db/`, `search/`, `certs/`, `plugins/`) au premier
    démarrage. Si le dossier hôte appartient à `root`, il n'y parvient pas et le conteneur
    boucle sur `FATAL ERROR - stat /app/data/state/log: no such file or directory` — message
    trompeur, le problème est un droit d'écriture, pas un fichier manquant. Rencontré le
    2026-09-11 ; `scripts/bootstrap-tyron.sh` pose désormais ce `chown`.

!!! warning "Image épinglée sur `latest` + digest"
    Filestash ne publie pas de tags de version sémantique utilisables (les seuls tags datés sont des
    hachages de commit de 2023). L'image est donc épinglée sur `latest@sha256:…` : le **digest** fige
    la version réellement déployée, et une mise à jour est un changement explicite du digest dans
    `compose.yaml`. Ne jamais retirer le digest, sinon la stack devient non reproductible.

## Accès en écriture au disque seedbox

Contrairement à [Jellyfin](jellyfin.md) qui monte la médiathèque en lecture seule, Filestash a
`/srv/seedbox` **en lecture-écriture** — c'est le but même de l'outil (ranger, renommer, supprimer).

!!! danger "Supprimer un fichier casse le torrent qui le seede"
    Si un fichier de `downloads/complete/` est supprimé ou renommé depuis Filestash, rTorrent
    continue de l'annoncer aux trackers puis échoue (`hash check failed`). Réflexe : **d'abord**
    retirer le torrent dans ruTorrent, **ensuite** toucher aux fichiers. Les sous-dossiers
    `incomplete/` et les fichiers de session dans `config/` ne doivent jamais être modifiés pendant
    qu'un téléchargement tourne.

## Exposition, authentification et DNS

Deux couches d'authentification se superposent ici, volontairement :

1. **Authelia (2FA)**, appliquée par le Traefik du VPS via le middleware `authelia@docker` — c'est
   elle qui garde la porte ;
2. **l'admin Filestash**, dont le mot de passe est défini à la première visite de `/admin`, et qui
   contrôle quels backends sont exposés.

```yaml
filestash:
  rule: "Host(`filestash.vindiesel.vip`)"
  entryPoints: [websecure]
  service: home-tyron
  middlewares:
    - authelia@docker
  tls: {}
```

Règle correspondante dans `hosts/vps-prod/stacks/authelia/configuration.yaml` :

```yaml
- domain: 'filestash.vindiesel.vip'
  policy: 'two_factor'
```

`APPLICATION_URL: "filestash.vindiesel.vip"` indique à Filestash sous quel nom il est servi (il
génère ses liens et ses redirections à partir de cette valeur). `CANARY: "false"` coupe la
vérification de version sortante.

**DNS** : `filestash.vindiesel.vip` → `116.202.22.50` (IP publique du VPS), en **DNS-only**.

## Configuration initiale (après le premier déploiement)

1. Ouvrir `https://filestash.vindiesel.vip/admin` — Authelia demande d'abord le 2FA.
2. Filestash demande de **définir le mot de passe administrateur** : le générer et le stocker dans
   Bitwarden (ce n'est pas un secret du dépôt : il vit dans `/data/filestash`, pas dans Git).
3. Onglet **Backend** : ne garder que **Local** (« Storage » / `local`), désactiver les autres
   (S3, FTP, Dropbox…) pour réduire la surface.
4. Chemin du backend local : `/srv/seedbox` — tu n'y verras que `downloads/` et `watch/`.
5. Onglet **Settings** : forcer `Force SSL` désactivé (le TLS est terminé au VPS ; l'activer
   provoquerait une boucle de redirection), et vérifier que l'URL applicative est correcte.

## Déploiement (Komodo)

Entrée `[[stack]] filestash` dans `komodo/stacks.toml` : `server = "docker-tyron"`,
`after = ["traefik-tyron"]`, tags `["app", "tyron"]`. **Pas de `pre_deploy`** : aucun secret dans le
dépôt (le mot de passe admin est saisi dans l'UI et persiste dans `/data/filestash`).

**Ordre :** créer `/data/filestash` + l'enregistrement DNS, s'assurer que `/srv/seedbox` est monté,
déployer via Komodo, puis faire la configuration initiale ci-dessus.

## Dépannage

| Symptôme | Cause probable | Correctif |
| --- | --- | --- |
| Boucle de redirection | `Force SSL` activé dans Filestash alors que le TLS est terminé au VPS | Le désactiver dans *Settings* |
| Le backend local ne liste rien | `/srv/seedbox` non monté sur l'hôte au moment du déploiement | `findmnt /srv/seedbox` puis redéployer |
| `Permission denied` à l'écriture | Droits du disque seedbox | `chown -R 1000:1000 /srv/seedbox` |
| Le mot de passe admin est perdu | Il vit dans `/data/filestash` | Supprimer `/data/filestash/config/` et redéployer : Filestash redemande la configuration initiale |
| Boucle de redémarrage, `FATAL ERROR - stat /app/data/state/log` | `/data/filestash` appartient à `root`, l'image tourne en uid 1000 | `chown -R 1000:1000 /data/filestash` puis redéployer |
| Page blanche / assets non chargés | `APPLICATION_URL` ne correspond pas au nom réellement utilisé | Aligner la variable sur `filestash.vindiesel.vip` et redéployer |
| Téléversement de gros fichiers qui échoue | Timeout du proxy | Augmenter les timeouts côté Traefik du VPS, ou passer par ruTorrent / SFTP pour les très gros volumes |

---

**Sources :** `hosts/tyron/stacks/filestash/compose.yaml`,
`hosts/vps-prod/stacks/traefik/dynamic/home-tyron.yaml`,
`hosts/vps-prod/stacks/authelia/configuration.yaml`, `komodo/stacks.toml` du dépôt ·
[Filestash](https://www.filestash.app/) ·
[mickael-kerjean/filestash](https://github.com/mickael-kerjean/filestash).
