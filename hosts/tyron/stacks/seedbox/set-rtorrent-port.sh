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
# Deux pièges vérifiés en conditions réelles (2026-09-11), voir docs/seedbox.md :
#
#  - On vise le port 8001 et non 8000. Dans l'image crazymax/rtorrent-rutorrent, le
#    serveur nginx du port XMLRPC impose toujours un auth_basic sur
#    /passwd/rpc.htpasswd (laissé vide, l'auth étant faite par Authelia). Le serveur
#    de santé, sur XMLRPC_PORT + 1, expose le même socket SCGI sans auth, en loopback.
#
#  - rTorrent 0.16 a renommé les méthodes : `network.port_range.set` n'existe plus
#    (faultCode -506). Et régler la *plage* ne refait pas le bind de la socket : seul
#    `network.listen.port.set` change le port réellement écouté, à chaud.
set -eu

PORT="${1:?usage: set-rtorrent-port.sh <port>}"
PORT="${PORT%%,*}"                 # gluetun peut passer "1234,5678" : on garde le 1er
RPC_URL="http://127.0.0.1:8001"    # XMLRPC_PORT (8000) + 1 = port de santé, sans auth
RETRIES=20
DELAY=6

log() { echo "[set-rtorrent-port] $*"; }

# $1 = méthode, $2 = valeur XML déjà typée (ou vide pour un appel sans argument).
# Renvoie non-zéro si la requête échoue OU si rTorrent répond un fault XML-RPC :
# un fault arrive en HTTP 200, donc le code retour de wget ne suffit pas à conclure.
rpc() {
  body='<?xml version="1.0"?><methodCall><methodName>'"$1"'</methodName><params><param><value><string></string></value></param>'"$2"'</params></methodCall>'
  # --timeout/--tries : sans eux wget attend son délai par défaut (plusieurs minutes)
  # quand le port écoute mais que rTorrent n'est pas encore prêt à répondre.
  out=$(wget -q -O- --timeout=5 --tries=1 \
          --header='Content-Type: text/xml' --post-data "$body" "$RPC_URL" 2>/dev/null) || return 1
  case "$out" in
    *"<fault>"*) log "fault XML-RPC sur $1 : $(echo "$out" | tr -d '\n' | sed 's/.*faultString.*<string>\([^<]*\)<.*/\1/')"; return 1 ;;
  esac
  echo "$out"
}

apply() {
  # Pas de port aléatoire au redémarrage, et plage alignée sur le port forwardé...
  rpc network.listen.port.random.set '<param><value><string>no</string></value></param>' >/dev/null || return 1
  rpc network.listen.port.range.set "<param><value><string>${PORT}-${PORT}</string></value></param>" >/dev/null || return 1
  # ...mais c'est CE dernier appel qui refait réellement le bind de la socket.
  rpc network.listen.port.set "<param><value><i8>${PORT}</i8></value></param>" >/dev/null || return 1

  # Vérifie le résultat plutôt que de faire confiance aux codes retour.
  got=$(rpc network.listen.port '' | tr -d '\n' | sed 's/.*<i8>\([0-9]*\)<\/i8>.*/\1/') || return 1
  [ "$got" = "$PORT" ] || { log "port encore a ${got}, attendu ${PORT}"; return 1; }
}

i=0
while [ "$i" -lt "$RETRIES" ]; do
  if apply; then
    log "port d'ecoute rTorrent regle sur ${PORT} (verifie)"
    exit 0
  fi
  i=$((i + 1))
  log "rTorrent pas encore pret sur ${RPC_URL} (tentative ${i}/${RETRIES})"
  sleep "$DELAY"
done

log "ECHEC : impossible de regler le port ${PORT} apres ${RETRIES} tentatives"
exit 1
