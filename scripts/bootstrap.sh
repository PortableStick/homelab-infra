#!/usr/bin/env bash
#
# bootstrap.sh — Amorçage d'un VPS nu pour homelab-infra.
#
# ⚠️ BROUILLON / NON TESTÉ DE BOUT EN BOUT.
#    Ce script encode les étapes MANUELLES connues de docs/restauration.md.
#    Les parties non encore réalisables (restauration de base depuis la Storage Box Hetzner)
#    sont des stubs marqués "TODO" : elles ne font rien tant que le backup hors-site n'existe pas.
#    À relire et tester sur une machine jetable avant tout usage réel.
#
# Hypothèses :
#   - Ubuntu Server, exécuté en root (ou via sudo).
#   - Docker + plugin compose déjà installés (voir étape 2 de docs/restauration.md), OU décommenter
#     la section d'installation Docker ci-dessous.
#   - La clé privée age maître est récupérée depuis Bitwarden et collée quand demandé.
#
# Réf : docs/restauration.md, docs/secrets-sops.md, docs/komodo.md
set -euo pipefail

### Paramètres (à adapter si besoin) #########################################
PUBLIC_IP="116.202.22.50"
REPO_URL="https://github.com/PortableStick/homelab-infra.git"
PERIPHERY_ROOT="/etc/komodo"                       # racine Periphery (défaut Komodo)
REPO_DIR="${PERIPHERY_ROOT}/homelab-infra"
AGE_KEY_FILE="${PERIPHERY_ROOT}/age/key.txt"
EXPECTED_AGE_PUBKEY="age16jmqm9c42x330uyvdf07lq2qy892c7hdj96t6dw4m9rmhy4cw96spyc5cr"
KOMODO_STACK_DIR="${REPO_DIR}/hosts/vps-prod/stacks/komodo"
SECRET_FILE="${REPO_DIR}/secrets/vps/komodo.env"
RENDERED_ENV="${KOMODO_STACK_DIR}/compose.env"
##############################################################################

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERREUR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "À lancer en root (ou via sudo)."

need() { command -v "$1" >/dev/null 2>&1 || die "Commande requise absente : $1"; }
need git
need docker
need sops
need age-keygen
need openssl

# --- (Optionnel) Installation Docker -----------------------------------------
# Décommenter si Docker n'est pas présent. Méthode dépôt officiel Docker (Ubuntu).
# Voir docs/restauration.md étape 2.
# log "Installation Docker..."
# ... (laisser volontairement à écrire/valider avant usage)

# --- Étape 2b : préserver l'IP source client (userland-proxy off) ------------
# Sans ça, l'IP source des clients tailnet est masquée en 172.20.0.1 (passerelle
# du bridge Docker) avant d'atteindre Traefik, ce qui casse l'ipAllowList des
# services VPN-only (*.int.vindiesel.vip). Voir docs/exposer-service-vpn-only.md.
# À placer avant tout démarrage de conteneur : le restart docker ci-dessous ne
# doit tuer aucune stack en cours.
log "Configuration Docker : userland-proxy=false (préservation IP source)"
mkdir -p /etc/docker
if [ ! -f /etc/docker/daemon.json ]; then
  printf '{\n  "userland-proxy": false\n}\n' > /etc/docker/daemon.json
  systemctl restart docker
elif command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp)"
  jq '. + {"userland-proxy": false}' /etc/docker/daemon.json > "$tmp" && mv "$tmp" /etc/docker/daemon.json
  systemctl restart docker
else
  echo "  /etc/docker/daemon.json existe déjà et jq est absent :"
  echo "  ajoute manuellement \"userland-proxy\": false puis 'systemctl restart docker'."
fi

# --- Étape 3 : port 53 (info) ------------------------------------------------
log "Vérification du port 53 (acme-dns écoute sur ${PUBLIC_IP}:53)"
if ss -ulpn 2>/dev/null | grep -q "${PUBLIC_IP}:53"; then
  echo "  Quelque chose écoute déjà sur ${PUBLIC_IP}:53 — vérifier systemd-resolved."
fi

# --- Étape 4 : réseau Docker externe -----------------------------------------
log "Création du réseau Docker 'frontend' (si absent)"
docker network inspect frontend >/dev/null 2>&1 || docker network create frontend

# --- Étape 5 : répertoires de données ----------------------------------------
log "Création des répertoires de données"
mkdir -p /data/acme-dns /data/traefik/acme /data/traefik/acme-dns \
         /data/authelia /data/lldap "${PERIPHERY_ROOT}/age"
if [ ! -f /data/traefik/acme/acme.json ]; then
  touch /data/traefik/acme/acme.json
  chmod 600 /data/traefik/acme/acme.json
fi

# Clé privée de signature OIDC d'Authelia (hors git, comme la clé age).
# Sa perte n'invalide que les sessions OIDC en cours. Voir docs/authelia.md.
if [ ! -f /data/authelia/oidc-issuer.pem ]; then
  log "Génération de la clé de signature OIDC Authelia"
  openssl genrsa -out /data/authelia/oidc-issuer.pem 4096
  chmod 600 /data/authelia/oidc-issuer.pem
fi

# --- Étape 6 : clé privée age ------------------------------------------------
if [ ! -f "${AGE_KEY_FILE}" ]; then
  log "Clé age absente — colle la clé privée maître (depuis Bitwarden), puis Ctrl-D :"
  umask 077
  cat > "${AGE_KEY_FILE}"
  chmod 600 "${AGE_KEY_FILE}"
fi
log "Vérification de la clé age"
GOT_PUB="$(age-keygen -y "${AGE_KEY_FILE}")"
[ "${GOT_PUB}" = "${EXPECTED_AGE_PUBKEY}" ] \
  || die "Clé privée incorrecte : obtenu ${GOT_PUB}, attendu ${EXPECTED_AGE_PUBKEY}"
export SOPS_AGE_KEY_FILE="${AGE_KEY_FILE}"

# --- Étape 7 : clone du dépôt ------------------------------------------------
if [ ! -d "${REPO_DIR}/.git" ]; then
  log "Clone du dépôt dans ${REPO_DIR}"
  git clone "${REPO_URL}" "${REPO_DIR}"
else
  log "Dépôt déjà présent — git pull"
  git -C "${REPO_DIR}" pull --ff-only
fi

# --- Étape 8 : rendu du compose.env (déchiffrement manuel) -------------------
log "Déchiffrement SOPS -> ${RENDERED_ENV}"
[ -f "${SECRET_FILE}" ] || die "Secret introuvable : ${SECRET_FILE}"
sops -d "${SECRET_FILE}" > "${RENDERED_ENV}"
chmod 600 "${RENDERED_ENV}"
grep -q 'ENC\[' "${RENDERED_ENV}" && die "Le rendu contient encore des blobs chiffrés — clé invalide ?"

# --- Étape 9 : démarrage de Komodo -------------------------------------------
log "Démarrage de la stack Komodo"
( cd "${KOMODO_STACK_DIR}" && docker compose up -d )

# --- Étape 10 : restauration de la base (TODO — pas de backup hors-site) -----
# TODO: tant que la Storage Box Hetzner n'est pas alimentée, rien à restaurer.
#       Quand un backup existera :
#         1) récupérer le dossier daté depuis la Storage Box -> /data/komodo/backups
#         2) lancer ghcr.io/moghtech/komodo-cli "km database restore -y" (base cible VIDE)
#       Voir docs/restauration.md étape 10 et https://komo.do/docs/setup/backup
log "Restauration de base : SAUTÉE (pas de backup hors-site). Komodo démarre vierge."

log "Bootstrap terminé. Suite manuelle : resource sync + DNS/certs (docs/restauration.md étapes 11-13)."
