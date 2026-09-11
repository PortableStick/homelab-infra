# Seedbox (rTorrent / ruTorrent derrière ProtonVPN)

Client BitTorrent **rTorrent** piloté par l'interface web **ruTorrent**, dont **tout** le trafic
réseau transite par un tunnel **ProtonVPN (WireGuard)** monté par **gluetun**. Déployé par Komodo sur
l'hôte **`tyron`** (serveur `docker-tyron`), avec un disque de 700 Go dédié. L'interface est exposée
en public sur `seedbox.vindiesel.vip`, **derrière Authelia (2FA)**.

Sources : `hosts/tyron/stacks/seedbox/`, `secrets/tyron/seedbox.env`,
`hosts/vps-prod/stacks/traefik/dynamic/home-tyron.yaml`, `komodo/stacks.toml`.

## Composants

| Service | Image | Rôle | Exposition |
| --- | --- | --- | --- |
| `gluetun` | `qmcgaw/gluetun:v3.41.3@sha256:fa19cc76…` | Tunnel WireGuard ProtonVPN + kill-switch + port forwarding NAT-PMP | Porte les labels Traefik (`seedbox.vindiesel.vip`), port interne `8080` |
| `rtorrent` | `crazymax/rtorrent-rutorrent:5.3.12-0.16.21@sha256:2ea0aada…` | rTorrent + ruTorrent (nginx + php-fpm) | **Aucune** : `network_mode: service:gluetun` |

!!! danger "Le point central : `network_mode: service:gluetun`"
    Le conteneur `rtorrent` **n'a pas de pile réseau à lui** — il emprunte celle de `gluetun`. Toutes
    ses connexions sortent donc obligatoirement par le tunnel, et si le tunnel tombe, le kill-switch
    de gluetun bloque le trafic : **il n'existe aucun chemin par lequel l'IP du domicile pourrait
    fuiter vers un tracker ou un peer**. Corollaire : `rtorrent` ne peut pas porter de labels Traefik
    (il n'est sur aucun réseau Docker) — c'est `gluetun` qui les porte, et qui est branché sur le
    réseau `proxy`.

## Automatisation : Sonarr + Prowlarr

Pour les séries suivies, le téléchargement et le rangement sont automatisés. Les deux services
vivent **dans la stack `seedbox`** et non dans une stack à part : `network_mode: service:gluetun`
ne fonctionne qu'à l'intérieur d'un même projet Compose. C'est aussi ce qu'on veut — leurs requêtes
aux trackers sortent ainsi par le VPN, au même titre que le trafic BitTorrent.

| Service | Rôle | URL |
| --- | --- | --- |
| `prowlarr` | Centralise les indexeurs (trackers privés) et les expose à Sonarr | `prowlarr.vindiesel.vip` (**Authelia 2FA**) |
| `sonarr` | Suit chaque série, cherche les épisodes manquants, importe et **renomme** | `sonarr.vindiesel.vip` (**Authelia 2FA**) |

### Le point qui compte : l'import par lien dur

Sonarr n'a pas vocation à déplacer ce que rTorrent seede. Il crée un **lien dur** depuis
`data/complete/` vers `data/media/` : un seul exemplaire des octets sur le disque, deux chemins.
rTorrent continue de seeder son fichier, Jellyfin lit une arborescence propre.

```
/srv/seedbox/data/complete/series/Greys.Anatomy.S21E05.FRENCH.1080p-GRP/…mkv   ← rTorrent seede
/srv/seedbox/data/media/series/Grey's Anatomy/Season 21/…S21E05.mkv          ← même inode
```

!!! danger "Un seul montage partagé — sinon `Cross-device link`"
    C'est **la** subtilité de ce montage, et elle se paie cher parce qu'elle échoue en silence.

    Sur l'hôte, `data/complete/` et `data/media/` sont évidemment sur le même système de
    fichiers. Mais si on les monte dans le conteneur comme **deux bind mounts distincts**, le
    noyau les présente comme deux périphériques différents et `ln` échoue :

    ```
    ln: failed to create hard link '/media/…' => '/downloads/complete/…': Cross-device link
    ```

    Sonarr **recopie** alors au lieu de lier : l'espace disque double, sans la moindre erreur
    visible dans son interface. Constaté en test le 2026-09-11 avant toute donnée réelle.

    D'où la règle : rTorrent **et** Sonarr montent le **même et unique** dossier hôte
    `/srv/seedbox/data` sur `/downloads`, et la bibliothèque vit **sous** lui, en
    `/downloads/media/`. Bonus : les deux voient exactement les mêmes chemins, donc aucun
    *Remote Path Mapping* n'est nécessaire côté Sonarr.

    Vérification, à faire **depuis le conteneur Sonarr** et non depuis l'hôte :

    ```bash
    docker exec seedbox_sonarr sh -c 'touch /downloads/complete/.t && ln /downloads/complete/.t /downloads/media/.t && stat -c %h /downloads/complete/.t'
    # doit afficher 2 (deux liens sur le meme inode), puis nettoyer les .t
    ```

!!! warning "Ne pas faire pointer Jellyfin sur `downloads/complete`"
    C'était le montage initial, avant Sonarr. Il faut désormais `media/` : c'est là que vivent les
    fichiers **renommés**, seuls exploitables par le détecteur de Jellyfin. `complete/` garde les
    noms de release bruts.

### Connexion de Sonarr à rTorrent

Dans Sonarr → *Settings → Download Clients → rTorrent* :

| Champ | Valeur |
| --- | --- |
| Host / Port | `127.0.0.1` / `8001` |
| URL Path | `RPC2` |
| Category | `series` (= le label ruTorrent, donc le sous-dossier de `complete/`) |

`127.0.0.1` fonctionne parce que Sonarr partage la pile réseau de gluetun avec rTorrent. Et on vise
**8001**, le port de santé sans authentification, pour la même raison que le script de port
forwarding : le port 8000 impose un `auth_basic` sur un `/passwd/rpc.htpasswd` laissé vide.

## Disque dédié (`/dev/sdb` → `/srv/seedbox`)

Un disque de **700 Go** est dédié aux téléchargements, séparé du disque système (128 Go) pour qu'un
disque plein n'empêche pas la VM de tourner.

Le script versionné `scripts/bootstrap-tyron.sh` fait tout ça (formatage, fstab, arborescence,
répertoires `/data`, réseau Docker `proxy`) et refuse de formater un disque qui porte déjà une
signature. Pour le détail, ou pour le faire à la main :

```bash
# Préparation initiale (une seule fois, disque vierge)
parted -s /dev/sdb mklabel gpt
parted -s /dev/sdb mkpart primary ext4 0% 100%
mkfs.ext4 -L seedbox /dev/sdb1

# Montage persistant PAR UUID (le nom /dev/sdb n'est pas stable au reboot)
UUID=$(blkid -s UUID -o value /dev/sdb1)
mkdir -p /srv/seedbox
echo "UUID=${UUID} /srv/seedbox ext4 defaults,noatime 0 2" >> /etc/fstab
mount -a
```

Arborescence, avec l'UID/GID `1000:1000` attendu par l'image rTorrent (`PUID`/`PGID`) :

```bash
mkdir -p /srv/seedbox/config/rtorrent/watch /srv/seedbox/passwd \
         /srv/seedbox/data/temp \
         /srv/seedbox/data/complete/{films,series,musique} \
         /srv/seedbox/data/media/{films,series}
chown -R 1000:1000 /srv/seedbox
```

!!! warning "Ces noms sont imposés par l'image — ne pas en inventer d'autres"
    `/etc/rtorrent/.rtlocal.rc` fige les chemins :

    | Variable rTorrent | Chemin | Rôle |
    | --- | --- | --- |
    | `cfg.download_temp` | `/downloads/temp/` | Téléchargements **en cours** |
    | `cfg.download_complete` | `/downloads/complete/` | Déplacés ici **à la fin** (`event.download.finished`) |
    | `cfg.watch` | `/data/rtorrent/watch/` → `config/rtorrent/watch/` | Dépôt de `.torrent` |

    Côté hôte, ce `/downloads` est **`/srv/seedbox/data`**. Créer un `incomplete/` ou un
    `downloads/watch/` ne sert à rien : rTorrent ne les regarde pas. Les sous-dossiers de
    `complete/` correspondent aux **labels ruTorrent** — voir [Jellyfin](jellyfin.md).

| Chemin hôte | Monté dans | Contenu |
| --- | --- | --- |
| `/srv/seedbox/config` | `rtorrent:/data` | `.rtorrent.rc`, session rTorrent, logs, et le dossier **`rtorrent/watch/`** où déposer les `.torrent` |
| `/srv/seedbox/data` | `rtorrent:/downloads` **et** `sonarr:/downloads` | `temp/` (en cours), `complete/<label>/` (terminés, seedés) et `media/` (bibliothèque renommée). **Un seul montage pour les deux** — voir l'encadré sur le lien dur |
| `/srv/seedbox/passwd` | `rtorrent:/passwd` | htpasswd nginx — **laissé vide** : l'auth est faite par Authelia |
| `/data/seedbox/gluetun` | `gluetun:/gluetun` | État gluetun (serveurs Proton, port forwardé) — disque système |

`/srv/seedbox/data/media` est monté **en lecture seule** dans Jellyfin
(voir [Jellyfin](jellyfin.md)), et `/srv/seedbox` en entier dans [Filestash](filestash.md).

!!! warning "Toujours monter le disque AVANT de déployer la stack"
    Si `/srv/seedbox` n'est pas monté au moment du `docker compose up`, Docker crée les répertoires
    **sur le disque système** et rTorrent y écrit ses téléchargements : le disque de 128 Go se
    remplit, et les données se retrouvent masquées dès que le vrai disque est monté par-dessus.
    Vérifier `findmnt /srv/seedbox` avant tout déploiement.

## VPN ProtonVPN (gluetun)

Configuration dans `compose.yaml` (non-secrets) :

| Variable | Valeur | Rôle |
| --- | --- | --- |
| `VPN_SERVICE_PROVIDER` | `protonvpn` | Fournisseur |
| `VPN_TYPE` | `wireguard` | WireGuard (plus rapide et plus stable qu'OpenVPN ici) |
| `SERVER_COUNTRIES` | `Spain` | Pays de sortie — la config Proton a été générée sur `ES#44` |
| `PORT_FORWARD_ONLY` | `on` | gluetun ne retient que les serveurs Proton qui supportent le port forwarding |
| `VPN_PORT_FORWARDING` | `on` | Active la négociation NAT-PMP |
| *(DNS)* | valeurs par défaut de gluetun | Résolveur **DoT interne à gluetun**, qui sort par le tunnel : aucune requête DNS ne part chez le FAI |

!!! info "gluetun ne se limite pas au serveur du fichier de conf"
    La clé privée WireGuard générée par Proton fonctionne avec **n'importe quel** serveur Proton :
    gluetun en choisit un lui-même parmi ceux qui correspondent à `SERVER_COUNTRIES` +
    `PORT_FORWARD_ONLY`, et en change tout seul si celui en cours ne répond plus. Les lignes
    `[Peer]`, `Endpoint` et `DNS` du fichier téléchargé chez Proton ne sont donc **pas** reprises
    dans la configuration — et surtout **il ne faut pas figer `DNS_ADDRESS` sur le `10.2.0.1`**
    du fichier : c'est le résolveur interne d'**un** serveur, pas une adresse valable partout.

## Port forwarding (NAT-PMP) — indispensable pour seeder

Sans port entrant, rTorrent peut télécharger mais quasiment personne ne peut se connecter à lui : le
ratio s'effondre. Proton attribue un port via **NAT-PMP**, mais ce port **change à chaque
reconnexion** — impossible de le figer dans la configuration.

Le mécanisme mis en place :

1. La config WireGuard doit avoir été générée chez Proton avec **« NAT-PMP (Port Forwarding) » activé**.
2. gluetun négocie un port et le renouvelle périodiquement (bail NAT-PMP de courte durée).
3. À chaque négociation, gluetun exécute `VPN_PORT_FORWARDING_UP_COMMAND`, qui appelle le script
   versionné `set-rtorrent-port.sh` avec le port en argument.
4. Le script pousse le port dans rTorrent **à chaud** via son API XMLRPC
   (`network.listen.port.set`), joignable sur `127.0.0.1` puisque les deux conteneurs
   partagent la même pile réseau, puis **vérifie** que `network.listen.port` renvoie bien
   le port attendu.

```yaml
VPN_PORT_FORWARDING_UP_COMMAND: "/bin/sh /gluetun/set-rtorrent-port.sh {{PORTS}}"
```

Le script retente 20 fois toutes les 6 s : au démarrage, gluetun obtient son port bien avant que
rTorrent ait fini de démarrer, et sans cette boucle le premier réglage serait perdu.

!!! danger "Trois pièges vérifiés en conditions réelles"
    Ces trois points ont été corrigés après un déploiement de validation le 2026-09-11.
    Chacun cassait le seed **en silence** : les téléchargements marchaient, aucune erreur
    visible dans ruTorrent, seuls les logs de gluetun trahissaient le problème.

    1. **Port 8000 occupé par gluetun.** Le serveur de contrôle HTTP de gluetun écoute sur
       `:8000` par défaut. Comme rTorrent partage sa pile réseau, son nginx XMLRPC (8000 lui
       aussi) bouclait en `bind() failed (98: Address in use)` et le conteneur restait
       *unhealthy*. D'où `HTTP_CONTROL_SERVER_ADDRESS: ":8010"` dans le compose.
    2. **Méthodes XML-RPC renommées.** rTorrent 0.16 ne connaît plus `network.port_range.set`
       (`faultCode -506`). Et régler la *plage* ne refait pas le bind de la socket : seul
       **`network.listen.port.set`** change le port réellement écouté, à chaud.
    3. **Un fault XML-RPC arrive en HTTP 200.** Se fier au code retour de `wget` faisait
       conclure au succès alors que rTorrent refusait l'appel. Le script cherche désormais
       `<fault>` dans la réponse, puis **revérifie** le port via `network.listen.port`.

!!! warning "Viser le port 8001, pas le 8000"
    Dans l'image `crazymax/rtorrent-rutorrent`, le serveur nginx du port XMLRPC (`8000`) impose
    **toujours** un `auth_basic` sur `/passwd/rpc.htpasswd` — fichier qu'on laisse volontairement
    vide puisque l'authentification est faite par Authelia. Une requête XMLRPC sur `8000`
    échouerait donc en erreur d'authentification. L'image expose en parallèle un second serveur
    sur `XMLRPC_PORT + 1` (donc **`8001`**), **sans auth** et limité à `127.0.0.1`, qui sert à son
    propre healthcheck et donne accès au même socket SCGI. C'est celui-là que le script utilise.

!!! note "`RT_INC_PORT: 50000` n'est qu'un repli"
    C'est le port d'écoute tant que NAT-PMP n'a rien attribué. Il n'est **pas** routé par Proton :
    si les logs du script montrent un échec, rTorrent reste sur ce port et ne reçoit aucune connexion
    entrante.

## Exposition, authentification et DNS

Chaîne complète :

```
Navigateur ──443──▶ Traefik VPS (TLS *.vindiesel.vip + forward-auth Authelia)
                      └──HTTP, tunnel Tailscale──▶ Traefik tyron ──▶ gluetun:8080 ──▶ ruTorrent
```

Côté VPS, `hosts/vps-prod/stacks/traefik/dynamic/home-tyron.yaml` déclare le routeur et applique le
middleware **`authelia@docker`**. Le suffixe `@docker` est obligatoire : le middleware est défini par
des labels sur le conteneur Authelia, et on le référence ici depuis le provider **fichier**.

```yaml
seedbox:
  rule: "Host(`seedbox.vindiesel.vip`)"
  entryPoints: [websecure]
  service: home-tyron
  middlewares:
    - authelia@docker
  tls: {}
```

La règle `access_control` correspondante est dans `hosts/vps-prod/stacks/authelia/configuration.yaml` :

```yaml
- domain: 'seedbox.vindiesel.vip'
  policy: 'two_factor'
```

**DNS** : `seedbox.vindiesel.vip` → IP publique du VPS `116.202.22.50`, en **DNS-only** (nuage gris),
comme tous les noms servis par le Traefik du VPS.

!!! note "Pas de htpasswd sur ruTorrent"
    `/srv/seedbox/passwd` est volontairement vide : l'image n'active son authentification basic que
    si `rutorrent.htpasswd` existe. Une double authentification (Authelia **puis** basic auth)
    n'apporterait rien et casserait les clients qui ajoutent des torrents par URL. La protection
    repose entièrement sur Authelia — donc **ne jamais retirer le middleware du routeur**.

## Secrets (SOPS/age)

`secrets/tyron/seedbox.env`, chiffré pour la clé age du dépôt (règle `secrets/tyron/*.env` ajoutée
dans `.sops.yaml`). Rendu en `.env` par le `pre_deploy` de Komodo.

| Variable | Rôle |
| --- | --- |
| `WIREGUARD_PRIVATE_KEY` | Ligne `PrivateKey` de la section `[Interface]` du fichier Proton |
| `WIREGUARD_ADDRESSES` | Ligne `Address`, **IPv4 uniquement** (`10.2.0.2/32`) |

!!! danger "Régénérer la clé si elle a circulé"
    Cette clé privée **est** l'identité VPN du compte. Si elle a transité par un canal non chiffré
    (mail, chat, capture d'écran), la révoquer sur <https://account.protonvpn.com/downloads> en
    générant une nouvelle configuration, puis rechiffrer le secret.

## Déploiement (Komodo)

Entrée `[[stack]] seedbox` dans `komodo/stacks.toml` : `server = "docker-tyron"`,
`after = ["traefik-tyron"]`, tags `["app", "tyron"]`, `pre_deploy` SOPS.

**Ordre de mise en route :**

1. Disque `/dev/sdb` formaté et monté sur `/srv/seedbox`, arborescence créée, `chown 1000:1000`
   (cf. § Disque dédié).
2. Enregistrement DNS `seedbox.vindiesel.vip` créé chez Cloudflare, en DNS-only.
3. Sync Komodo → déploie `traefik-tyron` puis `seedbox` (le `pre_deploy` rend le `.env`).
4. Redéployer la stack `traefik` du VPS (elle relit `dynamic/home-tyron.yaml`) et la stack `authelia`
   (nouvelle règle `access_control`).

## Vérifications

```bash
# 1. L'IP publique vue par rTorrent est bien celle du VPN, PAS celle du domicile
docker exec seedbox_gluetun wget -qO- https://ipinfo.io/ip   # doit etre une IP Proton (ES)
curl -s https://ipinfo.io/ip                                 # depuis la VM : IP du domicile

# 2. Le port forwarde et sa prise en compte par rTorrent
docker logs seedbox_gluetun 2>&1 | grep -i "port forward"
docker logs seedbox_gluetun 2>&1 | grep set-rtorrent-port    # doit finir par "regle sur <port>"

# 3. Le kill-switch : sans gluetun, rTorrent n'a plus aucun reseau
docker stop seedbox_gluetun
docker exec seedbox_rtorrent wget -qO- --timeout=5 https://ipinfo.io/ip   # doit echouer
docker start seedbox_gluetun
```

Dans ruTorrent, l'onglet **Settings → Connection** doit afficher le port négocié par Proton, et un
torrent de test (une ISO Linux) doit trouver des peers en quelques secondes.

## Dépannage

| Symptôme | Cause probable | Correctif |
| --- | --- | --- |
| `gluetun` en boucle de redémarrage | Clé WireGuard invalide ou `.env` vide | `docker logs seedbox_gluetun` ; vérifier que `sops -d secrets/tyron/seedbox.env` sort bien 2 lignes non vides |
| `rtorrent` ne démarre pas : `service "gluetun" is unhealthy` | Le tunnel ne monte pas | Corriger gluetun d'abord — `rtorrent` en dépend par `condition: service_healthy` |
| ruTorrent affiche « rTorrent is not running » | Permissions sur `/srv/seedbox/config` | `chown -R 1000:1000 /srv/seedbox` puis redéployer |
| Téléchargements OK mais **aucun upload / 0 peer entrant** | Le port forwardé n'a pas été poussé | Chercher `set-rtorrent-port` dans `docker logs seedbox_gluetun` ; vérifier que la config Proton a bien NAT-PMP activé |
| `PORT_FORWARD_ONLY` : aucun serveur trouvé | Le pays choisi n'a pas de serveur P2P avec port forwarding | Élargir `SERVER_COUNTRIES` (ex. `Spain,Switzerland,Netherlands`) |
| **502 après un redémarrage de la VM** | Traefik n'a pas pu binder son port : Docker démarre avant que `tailscale0` porte l'IP 100.x, et abandonne (`cannot assign requested address`, exit 128). `restart: unless-stopped` ne rattrape pas ce cas | `sysctl net.ipv4.ip_nonlocal_bind` doit valoir `1` (posé par `scripts/bootstrap-tyron.sh` dans `/etc/sysctl.d/99-nonlocal-bind.conf`). Remettre le service : `docker rm -f traefik && docker compose up -d` — un simple `docker start` laisse le conteneur sans réseau ni mapping de port |
| 502 sur `seedbox.vindiesel.vip` | Traefik VPS ne joint pas la VM | Vérifier le tailnet (`tailscale status`), le bind `<ip tailnet>:80:80` du Traefik local, et que `gluetun` est `healthy` |
| Boucle de redirection vers le portail Authelia | Cookie de session posé sur un autre domaine | Le nom doit rester sous `vindiesel.vip` (cf. `session.cookies` d'Authelia) |
| Le disque système se remplit | `/srv/seedbox` non monté au moment du déploiement | `findmnt /srv/seedbox` ; arrêter la stack, déplacer les données, monter, redéployer |
| Vitesse de téléchargement en dents de scie | MTU WireGuard trop élevé | Ajouter `WIREGUARD_MTU: "1380"` dans l'environnement de gluetun |

---

**Sources :** `hosts/tyron/stacks/seedbox/` (`compose.yaml`, `set-rtorrent-port.sh`),
`secrets/tyron/seedbox.env`, `hosts/vps-prod/stacks/traefik/dynamic/home-tyron.yaml`,
`hosts/vps-prod/stacks/authelia/configuration.yaml`, `komodo/stacks.toml` du dépôt ·
[gluetun — ProtonVPN](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/protonvpn.md) ·
[gluetun — port forwarding](https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md) ·
[crazy-max/docker-rtorrent-rutorrent](https://github.com/crazy-max/docker-rtorrent-rutorrent) ·
[rTorrent — RPC Setup](https://github.com/rakshasa/rtorrent/wiki/RPC-Setup-XMLRPC).
