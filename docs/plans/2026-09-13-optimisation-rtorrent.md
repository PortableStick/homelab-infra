# Optimisation de `.rtorrent.rc` (tyron) — Plan d'implémentation

> **Pour les agents :** SOUS-SKILL REQUISE — utiliser `superpowers:subagent-driven-development` (recommandé) ou `superpowers:executing-plans` pour exécuter ce plan tâche par tâche. Les étapes utilisent la syntaxe checkbox (`- [ ]`).

**Goal :** Faire passer la configuration rTorrent de la seedbox `tyron` sous contrôle Git, et la calibrer pour une VM i5-6500T / 8 Go dont les données vivent sur un HDD mécanique unique et dont la session d'état part sur le NVMe système.

**Architecture :** Aujourd'hui `.rtorrent.rc` est généré par l'image `crazymax/rtorrent-rutorrent` dans le bind mount `/srv/seedbox/config` — il n'existe nulle part dans le dépôt. On introduit donc d'abord un **point d'injection versionné** (fichier du dépôt monté en lecture seule dans le conteneur), on le valide à vide, puis on y empile les réglages par thème : pairs/réseau, fichiers/mémoire, disque, session. Chaque tâche se vérifie en interrogeant le rTorrent **qui tourne** via XMLRPC : on n'affirme pas qu'un réglage est pris, on le lit.

**Tech Stack :** Docker Compose, Komodo (déploiement GitOps), rTorrent 0.16.21 + ruTorrent 5.3.12 (`crazymax/rtorrent-rutorrent`), gluetun/ProtonVPN (netns partagé), XMLRPC via nginx sur `127.0.0.1:8001`.

## Global Constraints

- **Aucun commentaire** dans les fichiers de configuration du dépôt (`.rc`, `compose.yaml`, `.env`…). Les explications vont dans `docs/seedbox.md` et dans les messages de commit.
- **Aucun `Co-Authored-By:`** dans les messages de commit.
- Documentation dans l'arbo `docs/` servie par MkDocs, ajoutée au `nav` de `mkdocs.yml` si c'est une nouvelle page.
- L'image est **épinglée par digest** dans `compose.yaml` — ne pas la modifier dans ce chantier.
- Ne **jamais** retirer le middleware `authelia@docker` du routeur `seedbox` (VPS).
- Ne **jamais** donner à `rtorrent` de réseau propre : `network_mode: "service:gluetun"` est la garantie anti-fuite d'IP.
- **rTorrent 0.16 a renommé des méthodes.** Aucun nom de directive n'est réputé valide tant que `system.listMethods` ne l'a pas confirmé (cf. Tâche 1). Preuve dans le dépôt : `network.port_range.set` n'existe plus (`faultCode -506`), c'est `network.listen.port.range.set` — voir [`set-rtorrent-port.sh:19-21`](../../hosts/tyron/stacks/seedbox/set-rtorrent-port.sh).
- **Un fault XML-RPC arrive en HTTP 200.** Un test qui se fie au code retour de `wget` conclut au succès alors que rTorrent a refusé l'appel. Toujours chercher `<fault>` dans la réponse.
- Toute tâche qui touche au conteneur `rtorrent` impose de **vérifier `findmnt /srv/seedbox`** avant de redéployer (sinon Docker écrit sur le disque système).

---

## Écarts assumés par rapport à la demande initiale

Ces trois points de la spec sont modifiés dans ce plan. Chacun est signalé à l'endroit où il s'applique ; ils sont regroupés ici pour décision avant exécution.

| Spec initiale | Ce que fait le plan | Pourquoi |
| --- | --- | --- |
| `network.port_range.set = 50000-50000`, `network.port_random.set = no` | `network.listen.port.range.set` / `network.listen.port.random.set`, et **on ne fige pas 50000** | Les noms de la spec n'existent plus en 0.16. Surtout : le port d'écoute réel est imposé à chaud par ProtonVPN (NAT-PMP) via `set-rtorrent-port.sh`. `50000` n'est qu'un repli déjà porté par `RT_INC_PORT` dans le compose, et Proton **ne route pas** ce port. |
| `throttle.max_downloads.global.set = 3` « limite les torrents actifs » | `throttle.max_downloads.global.set = 300` + limitation du nombre de torrents côté Sonarr/ruTorrent | ⚠️ **Cette directive compte des *slots de pairs*, pas des torrents.** À 3, rTorrent ne télécharge que depuis 3 pairs au total, toutes tâches confondues : le débit descendant s'effondre. rTorrent n'a pas de directive native « N torrents actifs max ». |
| *(absent de la spec)* | Ajout de `pieces.hash.on_completion.set = no` | C'est **le** vrai gain I/O sur HDD unique : par défaut rTorrent relit intégralement chaque fichier terminé pour le re-vérifier, soit un second passage complet en lecture aléatoire concurrent des téléchargements en cours. Les pièces sont déjà vérifiées à la volée. |

---

## Structure des fichiers

| Fichier | Responsabilité |
| --- | --- |
| `hosts/tyron/stacks/seedbox/rt-rpc.sh` | **Créé.** Harnais de test : un appel XMLRPC, une valeur en sortie, code retour non-nul sur `<fault>`. Utilisé par toutes les vérifications du plan. |
| `hosts/tyron/stacks/seedbox/rtorrent-tuning.rc` | **Créé.** Le seul fichier de réglages versionné. Monté en lecture seule dans le conteneur. Aucun commentaire. |
| `hosts/tyron/stacks/seedbox/compose.yaml` | **Modifié.** Monte le fichier ci-dessus, ajoute `ulimits`, ajoute le volume de session NVMe. |
| `scripts/bootstrap-tyron.sh` | **Modifié.** Crée `/data/seedbox/rtorrent-session` avec le bon propriétaire. |
| `docs/seedbox.md` | **Modifié.** Section « Réglages rTorrent » : le pourquoi de chaque valeur, la procédure de migration de session, le rappel sur `max_downloads.global`. |
| `docs/faits-tyron-rtorrent.md` | **Créé en Tâche 1, supprimé en Tâche 8.** Fichier de travail portant les mesures relevées sur l'hôte. Ne pas l'ajouter au `nav`. |

---

## Tâche 1 : Harnais XMLRPC et relevé de l'hôte

Rien n'est configurable tant qu'on ne sait pas (a) quels noms de méthode existent réellement, (b) quel fichier rTorrent lit, (c) combien de RAM est disponible. Cette tâche ne change aucun comportement : elle produit des faits.

**Files:**
- Create: `hosts/tyron/stacks/seedbox/rt-rpc.sh`
- Create: `docs/faits-tyron-rtorrent.md`

**Interfaces:**
- Consumes: rien.
- Produces: `rt-rpc.sh <methode> [xml-params]` → imprime la valeur brute sur stdout, sort en 1 sur fault ou erreur réseau. Toutes les tâches suivantes l'utilisent comme assertion. Et `docs/faits-tyron-rtorrent.md`, consommé par les tâches 2, 4, 6 et 7.

- [ ] **Étape 1 : écrire le harnais de test**

`hosts/tyron/stacks/seedbox/rt-rpc.sh` :

```sh
#!/bin/sh
set -eu

METHOD="${1:?usage: rt-rpc.sh <methode> [params-xml]}"
PARAMS="${2:-}"
RPC_URL="http://127.0.0.1:8001"

body='<?xml version="1.0"?><methodCall><methodName>'"${METHOD}"'</methodName><params><param><value><string></string></value></param>'"${PARAMS}"'</params></methodCall>'

out=$(wget -q -O- --timeout=5 --tries=1 \
        --header='Content-Type: text/xml' --post-data "${body}" "${RPC_URL}" 2>/dev/null) || {
  echo "[rt-rpc] pas de reponse de ${RPC_URL}" >&2
  exit 1
}

case "${out}" in
  *"<fault>"*)
    echo "[rt-rpc] fault sur ${METHOD} : $(echo "${out}" | tr -d '\n' | sed 's/.*faultString.*<string>\([^<]*\)<.*/\1/')" >&2
    exit 1
    ;;
esac

echo "${out}" | tr -d '\n' | sed -e 's/.*<value>//' -e 's/<\/value>.*//' -e 's/<[^>]*>//g'
```

- [ ] **Étape 2 : le déposer sur l'hôte et le rendre exécutable**

Depuis `tyron` :

```bash
findmnt /srv/seedbox
docker cp hosts/tyron/stacks/seedbox/rt-rpc.sh seedbox_rtorrent:/tmp/rt-rpc.sh
docker exec seedbox_rtorrent chmod +x /tmp/rt-rpc.sh
```

- [ ] **Étape 3 : vérifier que le harnais fonctionne, et qu'il échoue quand il doit échouer**

```bash
docker exec seedbox_rtorrent /tmp/rt-rpc.sh network.listen.port
docker exec seedbox_rtorrent /tmp/rt-rpc.sh methode.qui.nexiste.pas ; echo "rc=$?"
```

Attendu : le premier imprime le port négocié par Proton (un entier, **pas** `50000` si NAT-PMP fonctionne). Le second imprime `[rt-rpc] fault sur methode.qui.nexiste.pas : …` puis `rc=1`.

Si le second sort `rc=0`, le harnais est cassé — corriger avant d'aller plus loin : toutes les assertions du plan reposent dessus.

- [ ] **Étape 4 : confirmer l'existence de chaque directive du plan**

```bash
docker exec seedbox_rtorrent /tmp/rt-rpc.sh system.listMethods > /tmp/methods.txt
for m in network.listen.port.range.set network.listen.port.random.set \
         dht.mode.set protocol.encryption.set protocol.pex.set trackers.numwant.set \
         throttle.min_peers.normal.set throttle.max_peers.normal.set \
         throttle.min_peers.seed.set throttle.max_peers.seed.set \
         throttle.max_uploads.set throttle.max_uploads.global.set \
         throttle.max_downloads.global.set \
         throttle.global_down.max_rate.set_kb throttle.global_up.max_rate.set_kb \
         network.http.max_open.set network.max_open_files.set network.max_open_sockets.set \
         pieces.memory.max.set pieces.hash.on_completion.set \
         network.xmlrpc.size_limit.set system.file.allocate.set session.path.set; do
  grep -qw "$m" /tmp/methods.txt && echo "OK   $m" || echo "MANQUANT  $m"
done
```

Attendu : que des `OK`. Toute ligne `MANQUANT` doit être résolue **ici**, en cherchant le nom réel dans `/tmp/methods.txt` (ex. `grep -i 'file.allocate' /tmp/methods.txt`), et le nom corrigé reporté dans le relevé de l'étape 6. Ne pas écrire une directive dont l'existence n'est pas confirmée : rTorrent refuse de démarrer sur une directive inconnue dans son `.rc`.

- [ ] **Étape 5 : identifier le fichier de configuration réellement lu, et s'il est régénéré**

```bash
docker exec seedbox_rtorrent ls -la /data/rtorrent/
docker exec seedbox_rtorrent cat /data/rtorrent/.rtorrent.rc
docker exec seedbox_rtorrent cat /etc/rtorrent/.rtlocal.rc
docker exec seedbox_rtorrent ps -o args= -C rtorrent
docker exec seedbox_rtorrent grep -rn "rtorrent.rc\|rtlocal" /entrypoint.sh /usr/local/bin/ 2>/dev/null
```

La question à trancher : **l'entrypoint réécrit-il `/data/rtorrent/.rtorrent.rc` à chaque démarrage** (à partir des variables `RT_*`) ou seulement s'il est absent ? La réponse choisit la branche de la Tâche 2.

- [ ] **Étape 6 : relever les mesures de l'hôte**

```bash
free -m
docker exec seedbox_rtorrent sh -c 'ulimit -n'
lsblk -o NAME,ROTA,SIZE,MOUNTPOINT
findmnt -no SOURCE,FSTYPE /srv/seedbox
findmnt -no SOURCE,FSTYPE /data
df -h /srv/seedbox /data
docker exec seedbox_gluetun sh -c 'wget -qO /dev/null https://speed.cloudflare.com/__down?bytes=100000000 2>&1 | tail -1'
```

`lsblk -o ROTA` est l'arbitre : `1` = disque mécanique, `0` = SSD/NVMe. On attend `ROTA=1` pour le disque portant `/srv/seedbox` et `ROTA=0` pour celui portant `/data`. **Si `/data` sort en `ROTA=1`, la Tâche 6 n'a pas lieu d'être** — déplacer la session sur un second HDD n'apporte rien.

- [ ] **Étape 7 : consigner le relevé**

Créer `docs/faits-tyron-rtorrent.md` et y écrire les valeurs mesurées :

```markdown
# Relevé tyron — préalable au réglage rTorrent

Relevé le <date> sur `tyron`. Fichier de travail, supprimé en fin de chantier.

| Fait | Valeur mesurée |
| --- | --- |
| RAM totale / disponible (`free -m`, colonne `available`) | … |
| `ulimit -n` dans le conteneur rtorrent | … |
| Disque de `/srv/seedbox` (source, ROTA, taille, libre) | … |
| Disque de `/data` (source, ROTA, taille, libre) | … |
| Débit descendant mesuré dans le netns gluetun | … Mbit/s |
| Débit montant mesuré dans le netns gluetun | … Mbit/s |
| `/data/rtorrent/.rtorrent.rc` régénéré à chaque démarrage ? | oui / non |
| Contenu actuel de `/data/rtorrent/.rtorrent.rc` | (coller) |
| Directives `MANQUANT` et leur nom réel en 0.16 | (aucune / liste) |
```

- [ ] **Étape 8 : commit**

```bash
git add hosts/tyron/stacks/seedbox/rt-rpc.sh docs/faits-tyron-rtorrent.md
git commit -m "chore(seedbox): harnais XMLRPC et releve de l'hote avant reglage rTorrent"
```

---

## Tâche 2 : Point d'injection versionné, validé à vide

On prouve que le dépôt peut imposer une directive à rTorrent **avant** d'y mettre quoi que ce soit d'important. Le fichier ne contient qu'un réglage inoffensif et observable.

**Files:**
- Create: `hosts/tyron/stacks/seedbox/rtorrent-tuning.rc`
- Modify: `hosts/tyron/stacks/seedbox/compose.yaml` (bloc `volumes:` du service `rtorrent`, lignes 106-112)

**Interfaces:**
- Consumes: le relevé de la Tâche 1, étape 5 (régénération ou non) et étape 7.
- Produces: le fichier `rtorrent-tuning.rc`, monté et **effectivement chargé** par rTorrent. Les tâches 3 à 7 ne font qu'ajouter des lignes dedans.

- [ ] **Étape 1 : écrire l'assertion qui doit échouer**

Depuis `tyron`, avant toute modification :

```bash
docker exec seedbox_rtorrent /tmp/rt-rpc.sh network.http.max_open
```

Noter la valeur courante (défaut de l'image). C'est elle qu'on veut voir changer.

- [ ] **Étape 2 : écrire le fichier de réglages, avec une seule directive**

`hosts/tyron/stacks/seedbox/rtorrent-tuning.rc` :

```
network.http.max_open.set = 50
```

Pas de commentaire, pas de ligne vide en tête. Le fichier restera sans commentaire jusqu'à la fin du chantier.

- [ ] **Étape 3 : monter le fichier — brancher selon le relevé**

**Branche A — `.rtorrent.rc` n'est PAS régénéré à chaque démarrage** (cas attendu).

Ajouter le montage dans `compose.yaml`, service `rtorrent`, après la ligne `- /srv/seedbox/passwd:/passwd` :

```yaml
      - ./rtorrent-tuning.rc:/data/rtorrent/tuning.rc:ro
```

Puis ajouter **une fois** la ligne d'import en fin du `.rtorrent.rc` de l'hôte, et la rendre idempotente en la posant aussi dans le bootstrap :

```bash
RC=/srv/seedbox/config/rtorrent/.rtorrent.rc
grep -qxF 'import = /data/rtorrent/tuning.rc' "$RC" || echo 'import = /data/rtorrent/tuning.rc' >> "$RC"
tail -3 "$RC"
```

**Branche B — `.rtorrent.rc` EST régénéré à chaque démarrage.** L'import de la branche A serait effacé au prochain redéploiement. On remplace alors le fichier entier : copier le contenu relevé en Tâche 1 étape 7 en tête de `rtorrent-tuning.rc` **verbatim**, y compris ses lignes `import`, puis ajouter `network.http.max_open.set = 50` à la fin, et monter par-dessus :

```yaml
      - ./rtorrent-tuning.rc:/data/rtorrent/.rtorrent.rc:ro
```

⚠️ En branche B, le fichier versionné est figé sur **une version d'image**. Le noter dans `docs/seedbox.md` en Tâche 8 : tout changement de digest de l'image impose de recomparer avec le `.rtorrent.rc` régénéré.

- [ ] **Étape 4 : redéployer et vérifier que la directive est prise**

```bash
findmnt /srv/seedbox
docker compose -f hosts/tyron/stacks/seedbox/compose.yaml up -d
docker exec seedbox_rtorrent /tmp/rt-rpc.sh network.http.max_open
```

Attendu : `50`, et non la valeur relevée à l'étape 1.

Si rTorrent ne démarre pas : `docker logs seedbox_rtorrent` — une directive inconnue provoque un abandon au chargement avec le numéro de ligne. En branche B, vérifier aussi que l'entrypoint ne plante pas en voulant écrire sur un montage `:ro`.

- [ ] **Étape 5 : commit**

```bash
git add hosts/tyron/stacks/seedbox/rtorrent-tuning.rc hosts/tyron/stacks/seedbox/compose.yaml
git commit -m "feat(seedbox): configuration rTorrent versionnee, montee en lecture seule"
```

---

## Tâche 3 : Pairs et réseau

**Files:**
- Modify: `hosts/tyron/stacks/seedbox/rtorrent-tuning.rc`

**Interfaces:**
- Consumes: le fichier créé en Tâche 2, déjà chargé et prouvé.
- Produces: rien de nouveau pour les tâches suivantes.

- [ ] **Étape 1 : relever les valeurs avant modification**

```bash
for m in throttle.min_peers.normal throttle.max_peers.normal \
         throttle.min_peers.seed throttle.max_peers.seed \
         throttle.max_uploads throttle.max_uploads.global \
         trackers.numwant dht.mode protocol.encryption; do
  printf '%-34s %s\n' "$m" "$(docker exec seedbox_rtorrent /tmp/rt-rpc.sh $m)"
done
```

- [ ] **Étape 2 : ajouter le bloc réseau/pairs**

Ajouter à la fin de `hosts/tyron/stacks/seedbox/rtorrent-tuning.rc` :

```
network.listen.port.random.set = no
dht.mode.set = disable
protocol.pex.set = no
protocol.encryption.set = allow_incoming,try_outgoing,enable_retry
trackers.numwant.set = 80
throttle.min_peers.normal.set = 20
throttle.max_peers.normal.set = 60
throttle.min_peers.seed.set = 10
throttle.max_peers.seed.set = 40
throttle.max_uploads.set = 8
throttle.max_uploads.global.set = 100
```

Trois écarts avec la spec, tous délibérés :

- `network.port_range.set` → **absent**. La plage est posée à chaud par `set-rtorrent-port.sh` sur le port négocié par Proton (`network.listen.port.range.set`, [`set-rtorrent-port.sh:50`](../../hosts/tyron/stacks/seedbox/set-rtorrent-port.sh#L50)). Figer `50000-50000` ici entrerait en conflit avec ce mécanisme, et `50000` n'est de toute façon **pas routé** par Proton.
- `network.port_random.set` → `network.listen.port.random.set`, seul nom valide en 0.16.
- `protocol.pex.set = no` ajouté : couper DHT en laissant PEX actif ne sert à rien sur trackers privés, l'échange de pairs continue hors tracker.

⚠️ `dht.mode.set = disable` + `protocol.pex.set = no` est le bon réglage pour des **trackers privés** (certains bannissent pour DHT actif). Sur des torrents publics, ça réduit fortement le nombre de pairs trouvés. Si la seedbox sert aussi à du public, laisser `dht.mode.set = auto` et `protocol.pex.set = yes`.

- [ ] **Étape 3 : redéployer et vérifier chaque valeur**

```bash
docker compose -f hosts/tyron/stacks/seedbox/compose.yaml up -d
for m in throttle.min_peers.normal throttle.max_peers.normal \
         throttle.min_peers.seed throttle.max_peers.seed \
         throttle.max_uploads throttle.max_uploads.global trackers.numwant; do
  printf '%-34s %s\n' "$m" "$(docker exec seedbox_rtorrent /tmp/rt-rpc.sh $m)"
done
docker exec seedbox_rtorrent /tmp/rt-rpc.sh dht.statistics
```

Attendu : `20 / 60 / 10 / 40 / 8 / 100 / 80`, et `dht.statistics` rapportant un DHT arrêté (`dht: off` ou équivalent).

- [ ] **Étape 4 : vérifier que le port forwardé n'a pas été perdu**

```bash
docker exec seedbox_rtorrent /tmp/rt-rpc.sh network.listen.port
docker logs seedbox_gluetun 2>&1 | grep set-rtorrent-port | tail -3
```

Attendu : le port Proton (≠ 50000) et une ligne `port d'ecoute rTorrent regle sur <port> (verifie)`. C'est le risque propre à cette tâche : un redéploiement redémarre rTorrent, et le port n'est reposé qu'à la prochaine négociation NAT-PMP ou via la boucle de 20 tentatives du script. Si le port est resté à 50000 après plusieurs minutes, relancer le script à la main avec le port courant lu dans les logs gluetun.

- [ ] **Étape 5 : commit**

```bash
git add hosts/tyron/stacks/seedbox/rtorrent-tuning.rc
git commit -m "feat(seedbox): reglage des pairs, DHT et PEX coupes pour trackers prives"
```

---

## Tâche 4 : Descripteurs de fichiers et mémoire

`network.max_open_files` + `network.max_open_sockets` ne servent à rien si le processus n'a pas les descripteurs pour. On relève le plafond **avant** de demander à rTorrent de s'en servir : dans l'autre ordre, rTorrent échoue à ouvrir des fichiers en pleine session.

**Files:**
- Modify: `hosts/tyron/stacks/seedbox/compose.yaml` (service `rtorrent`)
- Modify: `hosts/tyron/stacks/seedbox/rtorrent-tuning.rc`

**Interfaces:**
- Consumes: RAM disponible et `ulimit -n`, relevés en Tâche 1 étape 6.
- Produces: rien de nouveau.

- [ ] **Étape 1 : relever le plafond actuel**

```bash
docker exec seedbox_rtorrent sh -c 'ulimit -n'
```

Si la valeur est ≥ 4096, l'étape 2 est sans effet mais reste utile : elle fige le plafond dans le dépôt au lieu de dépendre du `default-ulimits` du démon Docker de l'hôte.

- [ ] **Étape 2 : poser le plafond dans le compose**

Dans `hosts/tyron/stacks/seedbox/compose.yaml`, service `rtorrent`, insérer avant `restart: unless-stopped` (ligne 113) :

```yaml
    ulimits:
      nofile:
        soft: 4096
        hard: 8192
```

4096 et non 1024 : les 600 fichiers + 300 sockets demandés se cumulent avec nginx, php-fpm et les descripteurs internes de rTorrent dans le **même** conteneur. 1024 laisserait une marge trop mince.

- [ ] **Étape 3 : ajouter le bloc fichiers/mémoire**

Ajouter à la fin de `hosts/tyron/stacks/seedbox/rtorrent-tuning.rc` :

```
network.max_open_files.set = 600
network.max_open_sockets.set = 300
network.xmlrpc.size_limit.set = 4M
pieces.memory.max.set = 2048M
```

`network.http.max_open.set = 50` est déjà en tête du fichier depuis la Tâche 2 — ne pas le dupliquer.

**Choix de `pieces.memory.max` :** 2048M, borne basse de la fourchette demandée. Sur cette VM de 8 Go tournent aussi Jellyfin (transcodage), Filestash, Traefik, Sonarr et Prowlarr. `pieces.memory.max` est un budget de **mmap**, pas de la RSS allouée — le dépassement se paie en éviction de page cache plutôt qu'en OOM — mais 3072M sur 8 Go partagés avec un transcodage Jellyfin rendrait les deux lents.

Arbitrage à faire avec la colonne `available` de `free -m` relevée en Tâche 1, **stack complète démarrée** :

| `available` mesuré | Valeur à écrire |
| --- | --- |
| ≥ 5000 Mo | `3072M` |
| 3500 – 5000 Mo | `2048M` |
| < 3500 Mo | `1024M` |

- [ ] **Étape 4 : redéployer et vérifier**

```bash
docker compose -f hosts/tyron/stacks/seedbox/compose.yaml up -d
docker exec seedbox_rtorrent sh -c 'ulimit -n'
for m in network.max_open_files network.max_open_sockets network.http.max_open pieces.memory.max; do
  printf '%-30s %s\n' "$m" "$(docker exec seedbox_rtorrent /tmp/rt-rpc.sh $m)"
done
```

Attendu : `ulimit -n` = `4096` ; `600` ; `300` ; `50` ; `2147483648` (`pieces.memory.max` se lit en **octets**, pas en Mo — `2048M` = 2147483648).

- [ ] **Étape 5 : vérifier que la VM respire toujours**

```bash
free -m
docker stats --no-stream seedbox_rtorrent
```

Attendu : `available` reste > 800 Mo, pas de swap qui grimpe. Si `available` s'effondre, redescendre `pieces.memory.max.set` d'un cran dans le tableau ci-dessus et redéployer.

- [ ] **Étape 6 : commit**

```bash
git add hosts/tyron/stacks/seedbox/compose.yaml hosts/tyron/stacks/seedbox/rtorrent-tuning.rc
git commit -m "feat(seedbox): descripteurs de fichiers et cache de pieces calibres pour 8 Go"
```

---

## Tâche 5 : Disque mécanique unique

Pas de RAID, un seul axe : chaque lecture aléatoire concurrente coûte un déplacement de tête. Deux leviers réels — la préallocation, et la suppression de la relecture de vérification en fin de téléchargement.

**Files:**
- Modify: `hosts/tyron/stacks/seedbox/rtorrent-tuning.rc`

**Interfaces:**
- Consumes: rien de nouveau.
- Produces: rien de nouveau.

- [ ] **Étape 1 : relever l'espace libre et les valeurs avant**

```bash
df -h /srv/seedbox
for m in system.file.allocate pieces.hash.on_completion throttle.max_downloads.global; do
  printf '%-34s %s\n' "$m" "$(docker exec seedbox_rtorrent /tmp/rt-rpc.sh $m)"
done
docker exec seedbox_rtorrent /tmp/rt-rpc.sh session.name
```

- [ ] **Étape 2 : ajouter le bloc disque**

Ajouter à la fin de `hosts/tyron/stacks/seedbox/rtorrent-tuning.rc` :

```
system.file.allocate.set = yes
pieces.hash.on_completion.set = no
throttle.max_downloads.global.set = 300
schedule2 = monitor_diskspace, 15, 60, ((close_low_diskspace, 2000M))
```

⚠️ **`throttle.max_downloads.global.set = 300`, pas `3`.** La spec demandait `3` en pensant limiter le nombre de torrents actifs. Cette directive compte des **slots de pairs** : à `3`, rTorrent ne télécharge que depuis 3 pairs au total, tous torrents confondus, et le débit descendant s'effondre. rTorrent n'a pas de directive native « N torrents en téléchargement max » — pour obtenir cet effet, limiter en amont :

- Sonarr → *Settings → Download Clients → rTorrent* : laisser rTorrent prendre la file, mais régler *Settings → Indexers → Maximum Size* et la fréquence de recherche pour ne pas lâcher 20 épisodes d'un coup.
- ruTorrent → plugin *throttle* / labels : régler un débit descendant par label.
- Ou, plus simple et plus efficace ici : le plafond global de la Tâche 7, qui borne mécaniquement le débit d'écriture.

`pieces.hash.on_completion.set = no` : par défaut rTorrent **relit intégralement** chaque fichier terminé pour le re-vérifier. Sur un HDD unique, ce second passage complet entre en concurrence directe avec les téléchargements en cours. Les pièces ayant déjà été vérifiées à la réception, la relecture n'apporte qu'une protection contre une corruption disque silencieuse — que ce disque, sans RAID, ne peut de toute façon pas réparer.

`system.file.allocate.set = yes` : sur ext4 la préallocation passe par `posix_fallocate` et les extents, donc instantanée et sans coût d'écriture. Elle évite qu'un fichier de 30 Go se retrouve éparpillé.

`schedule2 = monitor_diskspace` : toutes les 60 s après 15 s de délai, rTorrent arrête les torrents si `/downloads` passe sous 2000 Mo libres.

- [ ] **Étape 3 : redéployer et vérifier**

```bash
docker compose -f hosts/tyron/stacks/seedbox/compose.yaml up -d
for m in system.file.allocate pieces.hash.on_completion throttle.max_downloads.global; do
  printf '%-34s %s\n' "$m" "$(docker exec seedbox_rtorrent /tmp/rt-rpc.sh $m)"
done
```

Attendu : `1`, `0`, `300`.

- [ ] **Étape 4 : vérifier que le garde d'espace disque est bien armé**

```bash
docker exec seedbox_rtorrent /tmp/rt-rpc.sh 'schedule2' || true
docker logs seedbox_rtorrent 2>&1 | grep -i diskspace | tail -5
```

Attendu : aucune erreur de chargement au démarrage sur la ligne `schedule2` (une erreur de syntaxe y est fatale et apparaît dans les logs avec le numéro de ligne). Le déclenchement réel n'est pas testable sans remplir le disque — s'en tenir à l'absence d'erreur au chargement.

- [ ] **Étape 5 : commit**

```bash
git add hosts/tyron/stacks/seedbox/rtorrent-tuning.rc
git commit -m "feat(seedbox): reglages disque HDD unique, garde d'espace a 2 Go"
```

---

## Tâche 6 : Déplacer la session sur le NVMe

**Prérequis :** la Tâche 1 étape 6 doit avoir confirmé `ROTA=0` pour le disque portant `/data`. Sinon, **sauter cette tâche**.

⚠️ **C'est la seule tâche du plan qui peut faire perdre des torrents.** Le répertoire de session porte les `.torrent` et les `.libtorrent_resume` : changer `session.path` en pointant sur un répertoire vide fait redémarrer rTorrent **avec zéro torrent**, et les reprises sont perdues (les données restent sur le disque, mais chaque torrent devra être ré-ajouté puis re-vérifié intégralement). L'ordre stop → copie → bascule n'est pas négociable.

**Files:**
- Modify: `scripts/bootstrap-tyron.sh` (lignes 99-105)
- Modify: `hosts/tyron/stacks/seedbox/compose.yaml` (volumes du service `rtorrent`)
- Modify: `hosts/tyron/stacks/seedbox/rtorrent-tuning.rc`

**Interfaces:**
- Consumes: le relevé disque de la Tâche 1.
- Produces: le chemin hôte `/data/seedbox/rtorrent-session`, monté sur `/session` dans le conteneur.

- [ ] **Étape 1 : relever la session actuelle et son volume**

```bash
docker exec seedbox_rtorrent /tmp/rt-rpc.sh session.path
docker exec seedbox_rtorrent /tmp/rt-rpc.sh download_list | head
ls -la /srv/seedbox/config/rtorrent/session/ | head -20
du -sh /srv/seedbox/config/rtorrent/session/
ls /srv/seedbox/config/rtorrent/session/*.torrent 2>/dev/null | wc -l
```

Noter le nombre de `.torrent` : c'est le chiffre à retrouver à l'identique à l'étape 7.

Le chemin retenu est `/data/seedbox/rtorrent-session`, cohérent avec `/data/seedbox/gluetun` et `/data/sonarr` déjà en place ([`bootstrap-tyron.sh:99`](../../scripts/bootstrap-tyron.sh#L99)) — c'est le disque système, donc le NVMe. L'usure est négligeable : quelques Ko par torrent écrits sur changement d'état, pas un flux continu.

- [ ] **Étape 2 : créer le répertoire dans le bootstrap**

Dans `scripts/bootstrap-tyron.sh`, remplacer les lignes 99-100 :

```sh
mkdir -p /data/seedbox/gluetun /data/jellyfin/config /data/jellyfin/cache /data/filestash \
         /data/sonarr /data/prowlarr
```

par :

```sh
mkdir -p /data/seedbox/gluetun /data/seedbox/rtorrent-session \
         /data/jellyfin/config /data/jellyfin/cache /data/filestash \
         /data/sonarr /data/prowlarr
```

et ligne 105, remplacer :

```sh
chown -R "${PUID}:${PGID}" /data/jellyfin /data/filestash /data/sonarr /data/prowlarr
```

par :

```sh
chown -R "${PUID}:${PGID}" /data/jellyfin /data/filestash /data/sonarr /data/prowlarr \
                           /data/seedbox/rtorrent-session
```

- [ ] **Étape 3 : déclarer le montage et le chemin de session**

Dans `hosts/tyron/stacks/seedbox/compose.yaml`, service `rtorrent`, ajouter après `- /srv/seedbox/passwd:/passwd` :

```yaml
      - /data/seedbox/rtorrent-session:/session
```

Ajouter à la fin de `hosts/tyron/stacks/seedbox/rtorrent-tuning.rc` :

```
session.path.set = /session/
```

La barre oblique finale est obligatoire : rTorrent concatène le nom de fichier au chemin sans l'ajouter.

**Ne pas ajouter de `schedule = session_save`.** Le compose porte déjà `RT_SESSION_SAVE_SECONDS: "1800"` ([`compose.yaml:101`](../../hosts/tyron/stacks/seedbox/compose.yaml#L101)), qui pose ce planning côté image. Y superposer une seconde entrée créerait deux sauvegardes concurrentes. 1800 s espace déjà plus les écritures que les 1200 s de la spec ; pour changer la cadence, changer cette variable — pas le `.rc`.

- [ ] **Étape 4 : arrêter proprement rTorrent**

```bash
docker compose -f hosts/tyron/stacks/seedbox/compose.yaml stop rtorrent
docker ps -a --filter name=seedbox_rtorrent --format '{{.Status}}'
```

Attendu : `Exited (0)`. Un arrêt propre écrit l'état en session ; un `kill` le laisse incomplet. Si le statut n'est pas `Exited (0)`, redémarrer et refaire le `stop` en laissant plus de temps.

- [ ] **Étape 5 : copier la session — copier, pas déplacer**

```bash
cp -a /srv/seedbox/config/rtorrent/session/. /data/seedbox/rtorrent-session/
rm -f /data/seedbox/rtorrent-session/rtorrent.lock
chown -R 1000:1000 /data/seedbox/rtorrent-session
ls /data/seedbox/rtorrent-session/*.torrent | wc -l
```

`cp -a` et non `mv` : l'ancienne session reste en place comme filet de sécurité jusqu'à la validation de l'étape 7. Le `rtorrent.lock` d'une instance arrêtée est retiré — s'il subsiste, rTorrent refuse d'ouvrir la session.

Attendu : le compte de `.torrent` est **identique** à celui relevé à l'étape 1.

- [ ] **Étape 6 : redéployer**

```bash
findmnt /srv/seedbox
docker compose -f hosts/tyron/stacks/seedbox/compose.yaml up -d
docker logs -f seedbox_rtorrent
```

- [ ] **Étape 7 : vérifier que tous les torrents sont revenus**

```bash
docker exec seedbox_rtorrent /tmp/rt-rpc.sh session.path
docker exec seedbox_rtorrent /tmp/rt-rpc.sh download_list | tr ' ' '\n' | grep -c .
findmnt -no SOURCE /data
```

Attendu : `session.path` = `/session/`, et un nombre de torrents **égal** à celui de l'étape 1. Ouvrir ruTorrent : la liste doit être complète, avec les pourcentages d'avancement intacts (pas de re-vérification en cours sur des torrents déjà terminés).

**Si des torrents manquent :** arrêter la stack, retirer le montage `/session` et la ligne `session.path.set`, redéployer — l'ancienne session est toujours dans `/srv/seedbox/config/rtorrent/session/`, intacte.

- [ ] **Étape 8 : commit, et ne retirer l'ancienne session qu'après plusieurs jours**

```bash
git add scripts/bootstrap-tyron.sh hosts/tyron/stacks/seedbox/compose.yaml hosts/tyron/stacks/seedbox/rtorrent-tuning.rc
git commit -m "feat(seedbox): session rTorrent deplacee sur le NVMe systeme"
```

L'ancien `/srv/seedbox/config/rtorrent/session/` n'est **pas** supprimé par ce plan. Le laisser au moins une semaine de fonctionnement nominal, puis le retirer à la main.

---

## Tâche 7 : Plafonds de débit global

**Files:**
- Modify: `hosts/tyron/stacks/seedbox/rtorrent-tuning.rc`

**Interfaces:**
- Consumes: les débits mesurés en Tâche 1 étape 6.
- Produces: rien de nouveau.

- [ ] **Étape 1 : mesurer le débit réellement disponible dans le tunnel**

Trois mesures espacées, pas une seule — un serveur Proton chargé fausse un relevé isolé :

```bash
for i in 1 2 3; do
  docker exec seedbox_gluetun sh -c 'wget -qO /dev/null https://speed.cloudflare.com/__down?bytes=200000000 2>&1 | tail -1'
  sleep 20
done
```

Le débit montant se mesure plus simplement en observant rTorrent en seed actif, pendant 5 minutes :

```bash
docker exec seedbox_rtorrent /tmp/rt-rpc.sh throttle.global_up.rate
```

- [ ] **Étape 2 : calculer les plafonds**

Formule : **80 % du débit mesuré**, converti en Ko/s (`set_kb` attend des kilo-octets par seconde).

`Mbit/s mesuré × 0,8 × 125 = Ko/s à écrire`

| Débit mesuré | Valeur `set_kb` |
| --- | --- |
| 100 Mbit/s | `10000` |
| 50 Mbit/s | `5000` |
| 20 Mbit/s | `2000` |
| 10 Mbit/s | `1000` |

Les 20 % de marge ne sont pas de la prudence décorative : un lien montant saturé à 100 % remplit la file d'attente du routeur et dégrade la latence de **tout** le foyer, y compris le trafic qui ne passe pas par la seedbox. C'est la raison principale de plafonner plutôt que de laisser illimité.

- [ ] **Étape 3 : écrire les plafonds**

Ajouter à la fin de `hosts/tyron/stacks/seedbox/rtorrent-tuning.rc`, avec les valeurs calculées à l'étape 2 :

```
throttle.global_down.max_rate.set_kb = 10000
throttle.global_up.max_rate.set_kb = 2000
```

- [ ] **Étape 4 : redéployer et vérifier**

```bash
docker compose -f hosts/tyron/stacks/seedbox/compose.yaml up -d
docker exec seedbox_rtorrent /tmp/rt-rpc.sh throttle.global_down.max_rate
docker exec seedbox_rtorrent /tmp/rt-rpc.sh throttle.global_up.max_rate
```

Attendu : les valeurs en **octets/s** — `10000` Ko/s se lit `10240000`.

- [ ] **Étape 5 : vérifier l'effet réel sur la latence du foyer**

Torrent actif en téléchargement, depuis une autre machine du réseau :

```bash
ping -c 20 1.1.1.1
```

Attendu : latence médiane proche de la valeur au repos. Si elle double ou pire, baisser le plafond montant d'un cran et recommencer — c'est le montant, pas le descendant, qui dégrade la latence.

- [ ] **Étape 6 : commit**

```bash
git add hosts/tyron/stacks/seedbox/rtorrent-tuning.rc
git commit -m "feat(seedbox): plafonds de debit global a 80% du lien mesure"
```

---

## Tâche 8 : Documentation et nettoyage

**Files:**
- Modify: `docs/seedbox.md`
- Delete: `docs/faits-tyron-rtorrent.md`
- Delete: `docs/plans/2026-09-13-optimisation-rtorrent.md` *(ce fichier, une fois le chantier clos)*

**Interfaces:**
- Consumes: toutes les valeurs effectivement retenues dans `rtorrent-tuning.rc`.
- Produces: la documentation opérationnelle.

- [ ] **Étape 1 : ajouter la section de réglages dans `docs/seedbox.md`**

Insérer une section `## Réglages rTorrent` **avant** la section `## Vérifications` (ligne 315). Elle doit contenir :

- Un tableau `Directive | Valeur | Pourquoi cette valeur ici` reprenant le contenu final de `rtorrent-tuning.rc`, avec les valeurs réellement appliquées (pas celles du plan).
- Un encadré `!!! danger` sur `throttle.max_downloads.global` : **slots de pairs, pas torrents**, et pourquoi `3` aurait effondré le débit. C'est exactement le genre de piège qui échoue en silence, comme les trois déjà documentés dans cette page.
- Un encadré `!!! warning` sur la migration de session : arrêt propre obligatoire, `cp -a` et non `mv`, retrait du `rtorrent.lock`, et le fait que l'ancienne session reste en filet quelques jours.
- Un encadré `!!! note` rappelant que `RT_SESSION_SAVE_SECONDS` (compose) et non un `schedule` du `.rc` pilote la cadence de sauvegarde de session.
- Si la Tâche 2 a emprunté la **branche B** : un encadré `!!! warning` indiquant que `rtorrent-tuning.rc` est une copie figée du `.rtorrent.rc` d'une version d'image, et qu'un changement de digest impose de recomparer.

- [ ] **Étape 2 : mettre à jour le tableau des montages et la ligne « Sources »**

Dans le tableau `Chemin hôte | Monté dans | Contenu` (lignes 157-162), ajouter :

```markdown
| `/data/seedbox/rtorrent-session` | `rtorrent:/session` | Session rTorrent (`.torrent`, `.libtorrent_resume`) — **disque système NVMe**, pas le HDD de données |
```

et corriger la ligne `/srv/seedbox/config` : elle ne porte plus la session.

Ajouter `rtorrent-tuning.rc` et `rt-rpc.sh` à la ligne `**Sources :**` en fin de page (ligne 352).

- [ ] **Étape 3 : ajouter une ligne de dépannage**

Dans le tableau `## Dépannage` (lignes 337-348), ajouter :

```markdown
| rTorrent ne démarre plus après une modification de config | Directive inconnue ou erreur de syntaxe dans `rtorrent-tuning.rc` | `docker logs seedbox_rtorrent` donne le numéro de ligne. Vérifier le nom auprès de `system.listMethods` : rTorrent 0.16 a renommé plusieurs méthodes |
| Tous les torrents ont disparu de ruTorrent | `session.path` pointe sur un répertoire vide, ou `rtorrent.lock` résiduel | Comparer `ls /data/seedbox/rtorrent-session/*.torrent \| wc -l` avec l'ancienne session ; supprimer le `.lock` |
```

- [ ] **Étape 4 : vérifier que la doc se construit**

```bash
pip install mkdocs-material
mkdocs build
```

Attendu : `INFO - Documentation built in …`, sans `ERROR`. Un `WARNING` sur un fichier hors `nav` est normal pour le plan et le relevé.

- [ ] **Étape 5 : supprimer les fichiers de travail**

```bash
git rm docs/faits-tyron-rtorrent.md docs/plans/2026-09-13-optimisation-rtorrent.md
```

Le relevé et le plan ont rempli leur office ; ce qui devait survivre est passé dans `docs/seedbox.md`.

- [ ] **Étape 6 : commit**

```bash
git add docs/seedbox.md
git commit -m "docs(seedbox): reglages rTorrent, migration de session et pieges associes"
```

---

## Vérification finale

À faire une fois les 8 tâches passées, stack déployée depuis au moins une heure.

- [ ] `docker exec seedbox_rtorrent /tmp/rt-rpc.sh network.listen.port` → le port Proton, pas `50000`
- [ ] `docker exec seedbox_gluetun wget -qO- https://ipinfo.io/ip` → une IP espagnole Proton
- [ ] `docker exec seedbox_rtorrent /tmp/rt-rpc.sh session.path` → `/session/`
- [ ] `findmnt -no SOURCE /data` et `findmnt -no SOURCE /srv/seedbox` → deux disques distincts
- [ ] Nombre de torrents dans ruTorrent identique à celui d'avant la Tâche 6
- [ ] `free -m` : `available` > 800 Mo, stack complète démarrée
- [ ] `docker exec seedbox_sonarr sh -c 'touch /downloads/complete/.t && ln /downloads/complete/.t /downloads/media/.t && stat -c %h /downloads/complete/.t'` → `2`, puis nettoyer les `.t` (non-régression du lien dur)
- [ ] `git status` → propre ; `git log --oneline -8` → les 8 commits, aucun avec `Co-Authored-By`
