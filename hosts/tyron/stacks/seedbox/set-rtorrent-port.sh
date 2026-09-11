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
set -eu

PORT="${1:?usage: set-rtorrent-port.sh <port>}"
PORT="${PORT%%,*}"                     # gluetun peut passer "1234,5678" : on garde le 1er
RPC_URL="http://127.0.0.1:8000/RPC2"   # nginx du conteneur rtorrent (XMLRPC_PORT)
RETRIES=20                             # gluetun peut tourner avant que rTorrent soit prêt
DELAY=6

log() { echo "[set-rtorrent-port] $*"; }

# $1 = nom de méthode, $2 = valeur (chaîne). Premier param vide = "target" rTorrent.
rpc() {
  body='<?xml version="1.0"?><methodCall><methodName>'"$1"'</methodName><params><param><value><string></string></value></param><param><value><string>'"$2"'</string></value></param></params></methodCall>'
  wget -q -O- --header='Content-Type: text/xml' --post-data "$body" "$RPC_URL"
}

i=0
while [ "$i" -lt "$RETRIES" ]; do
  if rpc network.port_random.set no >/dev/null 2>&1 \
     && rpc network.port_range.set "${PORT}-${PORT}" >/dev/null 2>&1; then
    log "port d'écoute rTorrent réglé sur ${PORT}"
    exit 0
  fi
  i=$((i + 1))
  log "rTorrent pas encore joignable sur ${RPC_URL} (tentative ${i}/${RETRIES})"
  sleep "$DELAY"
done

log "ECHEC : impossible de régler le port ${PORT} après ${RETRIES} tentatives"
exit 1
