# Jellyfin (médiathèque)

Serveur multimédia lisant les téléchargements terminés de la [seedbox](seedbox.md). Déployé par
Komodo sur l'hôte **`tyron`** (serveur `docker-tyron`), exposé en **public** sur
`jellyfin.vindiesel.vip`, **sans forward-auth Authelia** — c'est délibéré, voir plus bas.

Sources : `hosts/tyron/stacks/jellyfin/compose.yaml`,
`hosts/vps-prod/stacks/traefik/dynamic/home-tyron.yaml`, `komodo/stacks.toml`.

## Composant

| Service | Image | Rôle | Exposition |
| --- | --- | --- | --- |
| `jellyfin` | `jellyfin/jellyfin:12.0@sha256:baba6304…` | Serveur multimédia | `jellyfin.vindiesel.vip` (**public**), port interne `8096` |

- **Réseau** : `proxy` (externe), routé par le Traefik local de tyron puis par celui du VPS.
- **Utilisateur** : `user: "1000:1000"` — le même UID que rTorrent, sinon les fichiers téléchargés
  sont illisibles.

| Chemin hôte | Monté dans | Rôle |
| --- | --- | --- |
| `/data/jellyfin/config` | `/config` | Base Jellyfin, utilisateurs, métadonnées |
| `/data/jellyfin/cache` | `/cache` | Cache et fichiers de transcodage — **sur le disque système**, pas sur le disque seedbox |
| `/srv/seedbox/downloads/complete` | `/media` (**`:ro`**) | La médiathèque |

!!! danger "La médiathèque est montée en lecture seule — ne pas changer"
    rTorrent **seede** les fichiers de `complete/` : ils doivent rester bit-à-bit identiques. Si
    Jellyfin pouvait écrire dedans, une suppression depuis l'UI ou l'écriture de métadonnées à côté
    du média casserait les torrents en cours de seed (`hash check failed`). Laisser les métadonnées
    et images dans `/config`, jamais à côté des fichiers.

À créer avant le premier déploiement :

```bash
mkdir -p /data/jellyfin/config /data/jellyfin/cache
chown -R 1000:1000 /data/jellyfin
```

## Pourquoi Jellyfin n'est PAS derrière Authelia

Contrairement à [ruTorrent](seedbox.md) et [Filestash](filestash.md), le routeur Traefik de Jellyfin
ne porte **aucun** middleware `authelia@docker`, et aucune règle `access_control` ne le mentionne.

Un forward-auth exige que le client sache suivre une redirection vers un portail web, s'y
authentifier et conserver un cookie. Les applications Jellyfin (Android, iOS, Android TV, Fire TV,
Kodi, Chromecast, clients DLNA) **parlent directement à l'API** : elles n'ont pas de navigateur,
ne suivent pas le portail, et se prendraient un `302` incompréhensible à chaque requête. Mettre
Authelia devant revient à n'autoriser que l'accès par navigateur.

La sécurité repose donc sur :

- **l'authentification native de Jellyfin** (comptes + mots de passe forts, à créer à la première
  connexion) ;
- le TLS wildcard `*.vindiesel.vip` terminé par le Traefik du VPS ;
- **la désactivation de l'accès anonyme** : dans *Tableau de bord → Réseau*, ne **pas** activer
  « Autoriser les connexions distantes sans authentification », et laisser la découverte automatique
  (DLNA / UDP) désactivée puisqu'elle ne traverse de toute façon pas le tunnel.

!!! tip "Durcissement recommandé à la première connexion"
    Dans *Tableau de bord → Utilisateurs*, désactiver la création de compte publique ; dans
    *Tableau de bord → Réseau*, renseigner `https://jellyfin.vindiesel.vip` comme URL publique et
    laisser vide la liste des réseaux locaux de confiance (tout le trafic arrive par le proxy).

## Exposition Traefik & DNS

Labels dans `compose.yaml` — entrypoint `web` (HTTP pur), le TLS étant terminé au VPS :

```yaml
- "traefik.http.routers.jellyfin.rule=Host(`jellyfin.vindiesel.vip`)"
- "traefik.http.routers.jellyfin.entrypoints=web"
- "traefik.http.services.jellyfin.loadbalancer.server.port=8096"
```

`JELLYFIN_PublishedServerUrl: "https://jellyfin.vindiesel.vip"` indique aux clients l'URL à annoncer
(liens de partage, autodiscovery) — sans ça, Jellyfin annonce l'IP interne du conteneur et les apps
se retrouvent à pointer vers une adresse injoignable.

**DNS** : `jellyfin.vindiesel.vip` → `116.202.22.50` (IP publique du VPS), en **DNS-only**
(nuage gris).

## Transcodage : limites actuelles

La VM ne dispose **d'aucun nœud de rendu DRI** : seul `/dev/dri/card0` (le GPU virtuel de QEMU) est
présent, `renderD128` est absent. **Aucun transcodage matériel n'est donc possible en l'état**,
quelle que soit la puissance CPU allouée.

La VM a été portée à **4 vCPU / 8 Go** pour cette stack : un transcodage **logiciel** 1080p passe,
mais reste coûteux et ne tient pas à deux flux simultanés.

**Le mode de fonctionnement visé reste donc le *direct play*** : les clients lisent le fichier tel
quel. En pratique cela marche si le client supporte le codec (H.264 partout, HEVC sur la plupart
des TV et mobiles récents) et si le débit du lien suffit.

Le bloc d'activation du transcodage matériel est **présent mais commenté** dans `compose.yaml` :

```yaml
# devices:
#   - /dev/dri:/dev/dri
# group_add:
#   - "video"
#   - "render"
```

Pour l'activer : passer un GPU à la VM côté Proxmox (passthrough ou VirtIO-GPU avec rendu),
vérifier que `/dev/dri/renderD128` apparaît dans la VM, décommenter le bloc, redéployer, puis
activer **VAAPI** dans *Tableau de bord → Lecture → Accélération matérielle*.

## Déploiement (Komodo)

Entrée `[[stack]] jellyfin` dans `komodo/stacks.toml` : `server = "docker-tyron"`,
`after = ["traefik-tyron"]`, tags `["app", "tyron"]`. **Pas de `pre_deploy`** : cette stack n'a aucun
secret.

**Ordre :** créer `/data/jellyfin/{config,cache}` + l'enregistrement DNS, s'assurer que
`/srv/seedbox` est monté, puis déployer via Komodo.

**Première connexion :** l'assistant Jellyfin demande de créer le compte administrateur, puis
d'ajouter les médiathèques (voir ci-dessous).

## Plusieurs médiathèques, rangées automatiquement par rTorrent

Le tri ne se fait pas dans Jellyfin mais **en amont**, par le **label ruTorrent**. L'image rTorrent
calcule son répertoire de destination ainsi (`/data/rtorrent/.rtorrent.rc`) :

```
d.get_finished_dir = cfg.download_complete + d.custom1
                   = /downloads/complete/  + <label>
```

`d.custom1` **est** le label ruTorrent. À la fin d'un téléchargement, `d.move_to_complete` fait un
`mkdir -p` puis un `mv` : un torrent labellisé `series` part donc tout seul dans
`/downloads/complete/series/`, dossier créé au besoin.

**Côté ruTorrent** — poser le label au moment de l'ajout du torrent (champ *Label* de la boîte
d'ajout), ou après coup par clic droit → *Label*. Sans label, le fichier reste à la racine de
`complete/`.

**Côté Jellyfin** — une médiathèque **par sous-dossier**, et non une seule sur `/media` :

| Médiathèque | Type de contenu | Dossier |
| --- | --- | --- |
| Films | *Films* | `/media/films` |
| Séries | *Séries TV* | `/media/series` |
| Musique | *Musique* | `/media/musique` |

!!! warning "Ne pas créer une seule médiathèque sur `/media`"
    Le type de contenu pilote tout l'enrichissement (affiches, résumés, saisons/épisodes,
    regroupement). Une médiathèque unique force un seul type pour l'ensemble : les séries seraient
    traitées comme des films et jamais découpées en saisons. Une médiathèque par type, donc.

Ajouter une catégorie plus tard ne demande rien de plus : un nouveau label côté ruTorrent, une
nouvelle médiathèque côté Jellyfin pointant sur le sous-dossier du même nom.

!!! tip "Automatiser l'attribution du label"
    L'image embarque les plugins ruTorrent **`autotools`** (règles d'auto-label / auto-déplacement
    à l'ajout) et **`tracklabels`** (label déduit du tracker). Utile si tes sources sont
    régulières ; sinon le label manuel à l'ajout suffit et reste le plus prévisible.

## Dépannage

| Symptôme | Cause probable | Correctif |
| --- | --- | --- |
| Médiathèque vide après le scan | `/srv/seedbox` non monté, ou rien dans `complete/` | `findmnt /srv/seedbox` ; `ls /srv/seedbox/downloads/complete` |
| `Access denied` sur les fichiers | UID ≠ 1000 sur les fichiers téléchargés | `chown -R 1000:1000 /srv/seedbox` |
| Lecture qui saccade / se coupe | Transcodage logiciel (pas d'accélération matérielle) | Vérifier dans *Tableau de bord → Activité* si la session est en *Transcode* ; forcer une qualité en direct play côté client, ou voir § Transcodage |
| Les apps mobiles ne se connectent pas alors que le navigateur marche | Un middleware forward-auth a été ajouté au routeur | Le retirer — voir § Pourquoi Jellyfin n'est PAS derrière Authelia |
| Les liens générés pointent vers une IP interne | `JELLYFIN_PublishedServerUrl` absent | Le renseigner et redéployer |
| `502` sur le domaine | Conteneur pas encore *healthy* (démarrage long) | `docker logs jellyfin` ; le `start_period` du healthcheck est de 120 s |
| Le disque système se remplit | Transcodages accumulés dans `/cache` | *Tableau de bord → Planificateur* → tâche de nettoyage du cache de transcodage |

---

**Sources :** `hosts/tyron/stacks/jellyfin/compose.yaml`,
`hosts/vps-prod/stacks/traefik/dynamic/home-tyron.yaml`, `komodo/stacks.toml` du dépôt ·
[Jellyfin — Docker](https://jellyfin.org/docs/general/installation/container/) ·
[Jellyfin — Hardware acceleration](https://jellyfin.org/docs/general/administration/hardware-acceleration/) ·
[Jellyfin — Reverse proxy](https://jellyfin.org/docs/general/networking/).
