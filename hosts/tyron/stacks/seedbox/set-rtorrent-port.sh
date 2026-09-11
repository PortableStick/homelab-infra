#!/bin/sh
#
# set-rtorrent-port.sh — pousse le port forwardé par ProtonVPN (NAT-PMP) dans rTorrent.
#
# Appelé par gluetun via VPN_PORT_FORWARDING_UP_COMMAND, avec {{PORTS}} en argument, à
# chaque (re)négociation du bail NAT-PMP. rTorrent partage la pile réseau de gluetun
# (network_mode: service:gluetun) : son API XMLRPC est donc joignable sur 127.0.0.1.
#
# Sans ça, rTorrent écouterait sur RT_INC_PORT (50000) que Proton ne route pas :
# téléchargement OK mais aucune connexion entrante, donc seed quasi nul.
#
# On vise le port de SANTÉ (XMLRPC_PORT + 1) et non XMLRPC_PORT : dans l'image
# crazymax/rtorrent-rutorrent, le serveur nginx du port 8000 impose toujours un
# auth_basic sur /passwd/rpc.htpasswd (qu'on laisse volontairement vide, l'auth
# étant faite par Authelia) — il répondrait donc en erreur. Le serveur du port 8001
# expose le même socket SCGI, sans auth, et n'écoute que sur la boucle locale.
set -eu

PORT="${1:?usage: set-rtorrent-port.sh <port>}"
PORT="${PORT%%,*}"                 # gluetun peut passer "1234,5678" : on garde le 1er
RPC_URL="http://127.0.0.1:8001"    # XMLRPC_PORT (8000) + 1 = port de santé, sans auth
RETRIES=20                         # gluetun obtient son port avant que rTorrent soit prêt
DELAY=6

log() { echo "[set-rtorrent-port] $*"; }

# $1 = nom de méthode, $2 = valeur. Premier paramètre vide = "target" rTorrent.
rpc() {
  body='<?xml version="1.0"?><methodCall><methodName>'"$1"'</methodName><params><param><value><string></string></value></param><param><value><string>'"$2"'</string></value></param></params></methodCall>'
  wget -q -O- --header='Content-Type: text/xml' --post-data "$body" "$RPC_URL"
}

i=0
while [ "$i" -lt "$RETRIES" ]; do
  if rpc network.port_random.set no >/dev/null 2>&1 \
     && rpc network.port_range.set "${PORT}-${PORT}" >/dev/null 2>&1; then
    log "port d'ecoute rTorrent regle sur ${PORT}"
    exit 0
  fi
  i=$((i + 1))
  log "rTorrent pas encore joignable sur ${RPC_URL} (tentative ${i}/${RETRIES})"
  sleep "$DELAY"
done

log "ECHEC : impossible de regler le port ${PORT} apres ${RETRIES} tentatives"
exit 1
