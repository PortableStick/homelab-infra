#!/usr/bin/env bash
#
# bootstrap-periphery.sh — Rattache une VM Docker comme Periphery au Core Komodo du VPS.
#
# ⚠️ BROUILLON / NON TESTÉ DE BOUT EN BOUT. À relire sur une machine jetable avant usage réel.
#
# Modèle : connexion INBOUND (le Core VPS se connecte à cette Periphery sur https://<ip>:8120).
#
# Ce que fait le script (idempotent) :
#   1. vérifie Docker ; installe sops + age si absents
#   2. pose la clé privée age (collée au clavier si absente) et vérifie sa clé publique
#   3. installe la Komodo Periphery (binaire + systemd) via le script officiel
#   4. autorise le Core VPS (core_public_keys) et restreint l'accès aux IP tailnet (allowed_ips)
#   5. expose SOPS_AGE_KEY_FILE au service (indispensable au pre_deploy `sops -d` des stacks)
#   6. démarre la Periphery ; la suite (accepter la clé côté Core, resource sync) est affichée
#
# Réf : docs/komodo.md, docs/secrets-sops.md, scripts/bootstrap.sh,
#       https://komo.do/docs/setup/connect-servers
set -euo pipefail

### Paramètres (à adapter) ###################################################
CONNECT_AS="${CONNECT_AS:-docker-vindiesel}"  # nom de ce serveur tel que déclaré côté Core
CORE_PUBLIC_KEY="${CORE_PUBLIC_KEY:-}"        # clé publique du Core VPS (UI Komodo > Settings, "MCow...")
ALLOWED_IPS='["100.64.0.0/10"]'               # plages autorisées à joindre la Periphery (tailnet CGNAT)
PERIPHERY_ROOT="/etc/komodo"                  # racine Periphery (défaut Komodo)
AGE_KEY_FILE="${PERIPHERY_ROOT}/age/key.txt"
EXPECTED_AGE_PUBKEY="age16jmqm9c42x330uyvdf07lq2qy892c7hdj96t6dw4m9rmhy4cw96spyc5cr"
PERIPHERY_CONFIG="${PERIPHERY_ROOT}/periphery.config.toml"
SETUP_URL="https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py"
SOPS_VERSION="v3.9.4"                         # aligner sur la version qui a chiffré les secrets si besoin
##############################################################################

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERREUR: %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Commande requise absente : $1"; }

[ "$(id -u)" -eq 0 ] || die "À lancer en root (ou via sudo)."
need docker
need curl
need python3

case "$(uname -m)" in
  x86_64)  SOPS_ARCH="amd64" ;;
  aarch64) SOPS_ARCH="arm64" ;;
  *)       die "Architecture non gérée : $(uname -m)" ;;
esac

# --- 1. sops + age ----------------------------------------------------------
if ! command -v sops >/dev/null 2>&1; then
  log "Installation de sops ${SOPS_VERSION}"
  curl -fsSL -o /usr/local/bin/sops \
    "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.${SOPS_ARCH}"
  chmod +x /usr/local/bin/sops
fi
need sops
if ! command -v age-keygen >/dev/null 2>&1; then
  log "Installation de age"
  apt-get update -qq && apt-get install -y -qq age
fi

# --- 2. clé privée age ------------------------------------------------------
mkdir -p "${PERIPHERY_ROOT}/age"
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

# --- 3. Komodo Periphery (binaire + systemd, mode inbound) ------------------
if [ ! -x /usr/local/bin/periphery ]; then
  log "Installation de la Komodo Periphery"
  curl -sSL "${SETUP_URL}" | python3 -
fi
[ -f "${PERIPHERY_CONFIG}" ] || die "Config Periphery introuvable après install : ${PERIPHERY_CONFIG}"

# --- 4. autoriser le Core VPS + restreindre les IP --------------------------
[ -n "${CORE_PUBLIC_KEY}" ] || die "CORE_PUBLIC_KEY vide — renseigne la clé publique du Core (UI > Settings)."
if ! grep -q '^core_public_keys' "${PERIPHERY_CONFIG}"; then
  log "Autorisation du Core (core_public_keys)"
  printf '\ncore_public_keys = "%s"\n' "${CORE_PUBLIC_KEY}" >> "${PERIPHERY_CONFIG}"
fi
if ! grep -q '^allowed_ips' "${PERIPHERY_CONFIG}"; then
  log "Restriction d'accès (allowed_ips)"
  printf 'allowed_ips = %s\n' "${ALLOWED_IPS}" >> "${PERIPHERY_CONFIG}"
fi

# --- 5. SOPS_AGE_KEY_FILE pour le service (pre_deploy des stacks) ------------
log "Drop-in systemd : SOPS_AGE_KEY_FILE"
mkdir -p /etc/systemd/system/periphery.service.d
cat > /etc/systemd/system/periphery.service.d/sops.conf <<EOF
[Service]
Environment=SOPS_AGE_KEY_FILE=${AGE_KEY_FILE}
EOF

# --- 6. démarrage -----------------------------------------------------------
log "Démarrage de la Periphery"
systemctl daemon-reload
systemctl enable periphery >/dev/null 2>&1 || true
systemctl restart periphery
sleep 2
systemctl is-active --quiet periphery \
  || die "Periphery inactive — voir: journalctl -u periphery -n 50 --no-pager"

log "Bootstrap terminé."
cat <<EOF

Suite côté Core VPS :
  1. UI Komodo > serveur '${CONNECT_AS}' : accepter la clé publique tentée par cette Periphery.
  2. Vérifier l'état 'Ok / connecté'.
  3. Resource sync 'homelab-infra' -> déploie traefik-vindiesel, immich-1, immich-2.

Vérifs locales :
  systemctl status periphery --no-pager
  systemctl show periphery -p Environment   # doit contenir SOPS_AGE_KEY_FILE
  curl -k https://127.0.0.1:8120
EOF
