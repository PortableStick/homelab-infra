#!/usr/bin/env bash
#
# bootstrap-tyron.sh — prépare l'hôte tyron (VM Docker) pour les stacks seedbox /
# Jellyfin / Filestash. Idempotent : relançable sans risque.
#
# Ce que fait le script :
#   1. formate le disque dédié (GPT + ext4) — UNIQUEMENT s'il est vierge
#   2. le monte par UUID sur /srv/seedbox (entrée /etc/fstab persistante)
#   3. crée l'arborescence seedbox + les répertoires /data/<stack>
#   4. crée le réseau Docker externe `proxy`
#
# Ce qu'il ne fait PAS (voir docs/rattacher-hote-periphery.md) :
#   - poser la clé privée age, ni installer la Komodo Periphery
#     → scripts/bootstrap-periphery.sh, avec CONNECT_AS=docker-tyron
#
# Réf : docs/seedbox.md, docs/jellyfin.md, docs/filestash.md
set -euo pipefail

### Paramètres ###############################################################
DISK="${DISK:-/dev/sdb}"          # disque dédié à la seedbox
PART="${DISK}1"
MOUNT="${MOUNT:-/srv/seedbox}"
FSLABEL="seedbox"
PUID="${PUID:-1000}"              # doit correspondre au PUID/PGID du compose seedbox
PGID="${PGID:-1000}"
##############################################################################

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERREUR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "À lancer en root (ou via sudo)."
command -v docker >/dev/null 2>&1 || die "Docker absent."

# --- 1. disque -------------------------------------------------------------
if findmnt -n "${MOUNT}" >/dev/null 2>&1; then
  log "${MOUNT} est déjà monté — on ne touche pas au disque"
else
  [ -b "${DISK}" ] || die "${DISK} n'est pas un périphérique bloc."

  if blkid "${PART}" >/dev/null 2>&1; then
    log "${PART} porte déjà un système de fichiers — on saute le formatage"
  else
    # Garde-fou : refuse de formater un disque qui contient quoi que ce soit.
    if blkid "${DISK}" >/dev/null 2>&1; then
      die "${DISK} porte déjà une signature (table de partition ou FS). Formatage refusé.
     Vérifier avec : lsblk -f ${DISK}
     Si le disque est bien à jeter, l'effacer manuellement puis relancer."
    fi

    command -v parted >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq parted; }

    log "Formatage de ${DISK} (GPT + ext4) — le disque est vierge"
    parted -s "${DISK}" mklabel gpt
    parted -s "${DISK}" mkpart primary ext4 0% 100%
    sleep 2; partprobe "${DISK}"; sleep 3
    mkfs.ext4 -q -L "${FSLABEL}" "${PART}"
  fi

  UUID="$(blkid -s UUID -o value "${PART}")"
  [ -n "${UUID}" ] || die "UUID introuvable pour ${PART}."

  mkdir -p "${MOUNT}"
  if ! grep -q "${UUID}" /etc/fstab; then
    log "Ajout dans /etc/fstab (montage par UUID, pas par ${DISK} qui n'est pas stable)"
    printf 'UUID=%s %s ext4 defaults,noatime 0 2\n' "${UUID}" "${MOUNT}" >> /etc/fstab
  fi
  mount -a
  findmnt "${MOUNT}" >/dev/null || die "${MOUNT} n'est toujours pas monté."
fi

# --- 2. arborescence seedbox ------------------------------------------------
log "Arborescence de ${MOUNT}"
mkdir -p "${MOUNT}/config" \
         "${MOUNT}/passwd" \
         "${MOUNT}/downloads/complete" \
         "${MOUNT}/downloads/incomplete" \
         "${MOUNT}/downloads/watch"
chown -R "${PUID}:${PGID}" "${MOUNT}"

# --- 3. données des stacks (disque système) --------------------------------
log "Répertoires /data des stacks"
mkdir -p /data/seedbox/gluetun /data/jellyfin/config /data/jellyfin/cache /data/filestash
# Jellyfin ET Filestash tournent en uid 1000. Filestash crée lui-même son
# arborescence d'état (log/, config/, db/…) au premier démarrage : si le dossier
# hôte appartient à root, il n'y arrive pas et boucle en
# « FATAL ERROR - stat /app/data/state/log: no such file or directory ».
chown -R "${PUID}:${PGID}" /data/jellyfin /data/filestash

# --- 4. réseau Docker externe ----------------------------------------------
if docker network inspect proxy >/dev/null 2>&1; then
  log "Réseau Docker 'proxy' déjà présent"
else
  log "Création du réseau Docker 'proxy'"
  docker network create proxy >/dev/null
fi

log "Terminé."
cat <<EOF

État :
$(findmnt "${MOUNT}")
$(df -h "${MOUNT}" | tail -1)

Suite :
  1. Poser la clé age et installer la Periphery :
       CONNECT_AS=docker-tyron \\
       CORE_PUBLIC_KEY="<UI Komodo > Settings, commence par MCow...>" \\
       ./scripts/bootstrap-periphery.sh
  2. Accepter la clé publique tentée côté Core (UI Komodo > Servers > docker-tyron).
  3. Créer les enregistrements DNS (seedbox / jellyfin / filestash .vindiesel.vip
     -> 116.202.22.50, DNS-only) puis lancer le resource sync 'homelab-infra'.
EOF
