# Wings — daemon Pelican (hôte `mc-wings`)

Scaffold **phase 2**. Wings est le daemon qui exécute réellement les serveurs de jeu. Il tourne sur la
VM **séparée `mc-wings`**, **pas** sur `vindiesel`, et **n'est pas déployé par Komodo** : cette stack
est volontairement **absente de `komodo/stacks.toml`**. Elle se déploie **à la main** sur `mc-wings`
une fois le node créé dans le Panel.

> Doc complète et contexte : [Pelican (Panel jeux)](../../../../docs/pelican.md), section *Phase 2 — Wings*.

## Pourquoi hors Komodo / hors Traefik

- **Hors GitOps** : les serveurs de jeu et les nodes relèvent de Pelican, pas du dépôt. Komodo ne gère
  que le Panel.
- **Jamais derrière Traefik.** Wings expose deux flux TCP bruts que le reverse proxy HTTP casserait :
  - `8080` : API + **websocket** console du daemon (le Panel lui parle en HTTP(S) direct) ;
  - `2022` : **SFTP** (les utilisateurs déposent leurs fichiers de serveur). Passer le SFTP par Traefik
    (proxy HTTP) le **casse**.
  L'isolation vient du **VPN Tailscale**, pas d'un proxy.
- **TLS obligatoire côté Wings si le Panel est en HTTPS** (et il l'est : `https://mcwings.int.vindiesel.vip`).
  Wings a besoin d'un certificat valide pour son propre FQDN (ex. `node1.int.vindiesel.vip`).

## Prérequis sur `mc-wings`

- Docker CE (virtualisation **KVM** garantie ; OpenVZ/LXC souvent incompatibles avec Wings).
- Hôte joint au **tailnet** Tailscale.
- Dossiers de données :

  ```bash
  sudo mkdir -p /etc/pelican /var/lib/pelican /var/log/pelican /tmp/pelican
  ```

## Déploiement (dans l'ordre, APRÈS création du node dans le Panel)

1. **Créer le node** dans le Panel : *Admin → Nodes → Create*. FQDN du node (ex.
   `node1.int.vindiesel.vip`), port daemon `8080`, SSL activé.
2. **DNS** : enregistrement `A` du FQDN du node → **IP Tailscale de `mc-wings`** (DNS-only, non
   proxifié — même principe que les autres `*.int`, voir
   [Exposer un service en VPN-only](../../../../docs/exposer-service-vpn-only.md)).
3. **Certificat** du node : fournir un cert valide pour le FQDN dans le `config.yml` généré
   (chemins `api.ssl.cert` / `api.ssl.key`). Voir la doc pour les options (cert dédié Let's Encrypt sur
   `mc-wings`, ou copie du wildcard `*.int.vindiesel.vip`).
4. **Config** : *Node → onglet Configuration* → copier le YAML dans `/etc/pelican/config.yml` sur
   `mc-wings` (ou bouton *Auto Deploy Command*). Voir [`config.yml.example`](config.yml.example).
   ⚠️ Le vrai `config.yml` contient un **token** : il est ignoré par `.gitignore` de ce dossier, ne
   jamais le committer.
5. **Démarrer** :

   ```bash
   cd hosts/mc-wings/stacks/wings
   docker compose up -d
   docker compose logs -f wings   # doit afficher la connexion au Panel
   ```
6. Dans le Panel, le node doit passer **en vert** (heartbeat OK). Créer ensuite les *Allocations* (IP +
   ports de jeu) puis les serveurs.

## Vérifications

```bash
ss -tlpn | grep -E ':8080|:2022'          # les deux ports écoutent sur mc-wings
curl -kI https://node1.int.vindiesel.vip:8080   # répond (depuis le VPN)
```
