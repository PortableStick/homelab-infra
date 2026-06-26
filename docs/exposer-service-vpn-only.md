# Exposer un service en VPN-only

Pattern pour rendre un service joignable **uniquement via le VPN Tailscale**, avec un vrai nom de
domaine en HTTPS valide. Documenté ici sur l'exemple de **Komodo** (`komodo.vindiesel.vip`).

## Principe

Trois éléments combinés :

1. **Traefik** route le nom (`komodo.vindiesel.vip`) vers le conteneur, via le réseau Docker
   `frontend` — le port du service n'est plus publié sur l'hôte.
2. Un **enregistrement DNS** fait pointer le nom vers l'**IP Tailscale** du VPS (`100.x`), joignable
   seulement sur le tailnet.
3. Un **middleware `ipAllowList`** Traefik n'accepte que les connexions venant de la plage Tailscale
   (`100.64.0.0/10`). Double verrou : même si quelqu'un vise l'IP publique avec le bon `Host`, il est
   rejeté.

!!! info "Pourquoi ce n'est pas exposé publiquement"
    L'IP `100.x` (CGNAT, RFC 6598) n'est **pas routable** depuis Internet : un client hors VPN ne peut
    pas l'atteindre. Et l'`ipAllowList` bloque toute requête dont l'IP source n'est pas dans
    `100.64.0.0/10`. Voir [Comment ça marche](architecture.md) pour le modèle des « portes ».

## Modifications appliquées au compose Komodo

Dans `hosts/vps-prod/stacks/komodo/compose.yaml`, service `core` :

- **Suppression** de la publication publique du port :

    ```yaml
    # ports:
    #   - 9120:9120
    ```

- **Ajout** au réseau `frontend` (en gardant `default` pour la base) :

    ```yaml
    networks:
      - default     # comms internes avec ferretdb / periphery
      - frontend    # joignable par Traefik
    ```

- **Ajout** des labels Traefik :

    ```yaml
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=frontend"
      - "traefik.http.routers.komodo.rule=Host(`komodo.vindiesel.vip`)"
      - "traefik.http.routers.komodo.entrypoints=websecure"
      - "traefik.http.routers.komodo.tls=true"
      - "traefik.http.routers.komodo.tls.certresolver=letsencrypt"
      - "traefik.http.routers.komodo.middlewares=komodo-vpn"
      - "traefik.http.middlewares.komodo-vpn.ipallowlist.sourcerange=100.64.0.0/10"
      - "traefik.http.services.komodo.loadbalancer.server.port=9120"
    ```

- **Déclaration** du réseau externe en bas du fichier :

    ```yaml
    networks:
      frontend:
        name: frontend
        external: true
    ```

!!! note "Traefik n'est pas modifié"
    On réutilise l'entrypoint `websecure` (443) existant. L'isolation vient du couple « nom → IP
    Tailscale » + `ipAllowList`, pas d'un entrypoint dédié. Aucun changement dans le compose Traefik.

## Étapes manuelles à faire (dans l'ordre)

### 1. Récupérer l'IP Tailscale du VPS

```bash
# sur le VPS
tailscale ip -4
```

!!! info "À compléter — IP Tailscale"
    Reporter ici l'IP `100.x.y.z` obtenue. Elle est nécessaire pour l'enregistrement DNS ci-dessous.

### 2. Créer l'enregistrement DNS chez Cloudflare

| Type | Nom | Valeur | Proxy |
| --- | --- | --- | --- |
| `A` | `komodo.vindiesel.vip` | `<IP Tailscale 100.x>` | **DNS-only** (gris, jamais proxifié) |

!!! warning "Le proxy Cloudflare doit être désactivé"
    Une IP `100.x` ne peut pas être proxifiée par Cloudflare. L'enregistrement doit rester **DNS-only**.
    Si Cloudflare refuse l'IP CGNAT, l'alternative est le split DNS Tailscale (résolution privée) — à
    documenter ici le cas échéant.

### 3. Mettre à jour `KOMODO_HOST`

Komodo doit connaître son URL externe (liens, webhooks). Dans le secret :

```bash
sops secrets/vps/komodo.env
# KOMODO_HOST=https://komodo.vindiesel.vip
```

Puis re-rendre `compose.env` (voir [Secrets](secrets-sops.md)) :

```bash
sops -d secrets/vps/komodo.env > hosts/vps-prod/stacks/komodo/compose.env
```

### 4. Redéployer Komodo

Komodo est amorcé manuellement (il ne se déploie pas lui-même, voir [Komodo](komodo.md)) :

```bash
cd hosts/vps-prod/stacks/komodo
docker compose up -d
```

## Vérifications

```bash
# Le port 9120 ne doit PLUS écouter sur l'IP publique
sudo ss -tlpn 'sport = :9120'        # ne doit rien montrer côté 0.0.0.0 / IP publique

# Résolution du nom -> IP Tailscale
dig +short komodo.vindiesel.vip       # -> 100.x.y.z

# Connecté au VPN : accès OK en HTTPS valide
curl -I https://komodo.vindiesel.vip  # 200/302 attendu, cert *.vindiesel.vip

# Hors VPN (ou IP publique) : doit échouer / 403
```

- Sur le VPN → l'UI Komodo répond avec un certificat valide `*.vindiesel.vip`.
- Hors VPN → le nom ne mène à rien (IP non routable) ; et toute requête arrivant par l'IP publique
  est rejetée (403) par l'`ipAllowList`.

## Certificat

Aucun cert supplémentaire : le wildcard `*.vindiesel.vip` est déjà demandé par Traefik via le
challenge DNS acme-dns (voir [Reverse proxy & TLS](reverse-proxy-tls.md)). Le challenge DNS ne dépend
pas de l'accessibilité du service, donc un service VPN-only obtient quand même un cert valide.

!!! success "Certificats en production"
    Traefik est en Let's Encrypt **production** : le certificat de `komodo.vindiesel.vip` est valide.

## Variante plus stricte (pour plus tard)

L'`ipAllowList` filtre par IP source, mais Traefik écoute toujours techniquement sur l'IP publique
(il rejette, mais reçoit). Version plus stricte : un **entrypoint Traefik dédié, lié à l'interface
Tailscale** (publication Docker `100.x:443:<port>`), pour que le port ne soit pas ouvert du tout côté
public. Plus propre, mais nécessite de réorganiser les ports de Traefik et a un point d'attention
d'ordre de démarrage (Docker avant Tailscale au reboot). À envisager dans un second temps.

---

**Sources :** `hosts/vps-prod/stacks/komodo/compose.yaml` (modifié) ·
[Traefik v3 — IPAllowList](https://doc.traefik.io/traefik/reference/routing-configuration/http/middlewares/ipallowlist/) ·
[Tailscale — adresses 100.x (CGNAT)](https://tailscale.com/docs/concepts/tailscale-ip-addresses) ·
[Komodo](https://komo.do/docs).
