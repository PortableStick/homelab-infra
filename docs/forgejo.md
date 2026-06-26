# Forgejo

Forge Git auto-hébergée, exposée en public sur **`git.lucasmasse.net`**. Instance **neuve** (Forgejo
15.0.3 LTS, base **SQLite**) qui a remplacé une ancienne installation Forgejo v13 + MySQL.

Source : `hosts/vps-prod/stacks/forgejo/compose.yaml`. Déployée par Komodo (stack `forgejo`, tag
`app`, `after = ["traefik"]`).

## Fonctionnement

| Élément | Valeur | Source |
| --- | --- | --- |
| Image | `codeberg.org/forgejo/forgejo:15.0.3` (LTS, support jusqu'à 07/2027) | `compose.yaml` |
| Base de données | **SQLite** (`FORGEJO__database__DB_TYPE=sqlite3`) — aucun conteneur DB | `compose.yaml` |
| Données | `/data/forgejo` → `/data` (repos, base, config) | `compose.yaml` |
| Domaine | `git.lucasmasse.net` (`ROOT_URL=https://git.lucasmasse.net/`) | `compose.yaml` |
| Web | port interne `3000`, exposé via Traefik | labels |
| SSH Git | hôte `222` → conteneur `22` (`SSH_PORT=222`, `SSH_LISTEN_PORT=22`) | `compose.yaml` |
| Inscriptions | fermées (`DISABLE_REGISTRATION=true`) | `compose.yaml` |
| Page d'install | verrouillée (`INSTALL_LOCK=true`) — admin créé en CLI | `compose.yaml` |

Clone SSH : `ssh://git@git.lucasmasse.net:222/<owner>/<repo>.git`.

## Labels Traefik

```yaml
- "traefik.enable=true"
- "traefik.docker.network=frontend"
- "traefik.http.routers.forgejo.rule=Host(`git.lucasmasse.net`)"
- "traefik.http.routers.forgejo.entrypoints=websecure"
- "traefik.http.routers.forgejo.tls=true"
- "traefik.http.services.forgejo.loadbalancer.server.port=3000"
```

Pas de `tls.certresolver` → wildcard `*.lucasmasse.net` de l'entrypoint (voir
[Reverse proxy & TLS](reverse-proxy-tls.md)).

## Premier démarrage (admin)

La page d'installation étant verrouillée, l'administrateur se crée en ligne de commande :

```bash
docker exec -u 1000 forgejo forgejo admin user create \
  --admin --username TON_USER --email ton.email@reel.net --password 'MotDePasseFort'
```

!!! danger "Ne jamais laisser les valeurs d'exemple"
    Lors de la mise en place, un compte admin a été créé par erreur avec les valeurs littérales
    `TONUSER` / `MOTDEPASSE`. Sur une instance **publique**, c'est un compte compromis. Procédure de
    correction : créer le **vrai** admin, puis supprimer le compte fautif :
    `docker exec -u 1000 forgejo forgejo admin user delete --username TONUSER --purge`.

## Migration depuis l'ancien Forgejo (récupération des repos)

L'ancienne instance (Forgejo 13 + MySQL) stockait ses données sous `/data/portainer/forgejo`. Seul le
**contenu Git** a été migré (pas les issues / PR / utilisateurs, qui vivaient dans MySQL).

Sur le disque, chaque dépôt est un **repo git bare complet** (tout l'historique) :

```
/data/portainer/forgejo/git/repositories/<owner-en-minuscules>/<repo>.git
```

**Récupérer un repo** vers la nouvelle instance :

1. Créer un repo **vide** du bon nom dans le nouveau Forgejo (UI, sans l'initialiser). La **casse** de
   `owner/repo` doit correspondre à l'URL voulue (ex. `PortableStick/portfolioscolaire`).
2. Pousser branches + tags depuis le bare :

    ```bash
    BARE=/data/portainer/forgejo/git/repositories/portablestick/<repo>.git
    URL="https://USER:TOKEN@git.lucasmasse.net/OWNER/<repo>.git"
    git -C "$BARE" -c safe.directory="$BARE" push "$URL" --all
    git -C "$BARE" -c safe.directory="$BARE" push "$URL" --tags
    ```

!!! note "Détails qui font gagner du temps"
    - **`safe.directory`** : le bare appartient à l'UID 1000 (git) ; lancé en root, `git` refuse sans
      l'exception `-c safe.directory=...`.
    - **`--all` + `--tags`** plutôt que `--mirror` : le bare contient des refs internes de PR
      (`refs/pull/*`) que Forgejo gère lui-même et qui font échouer un `--mirror`.
    - **Token** : utiliser un jeton d'accès (Settings → Applications) comme mot de passe, pas le mdp
      du compte. Et le **révoquer** après la migration s'il a circulé.
    - **Migration en masse** : pour pousser plusieurs repos d'un coup sans les créer un à un, activer
      temporairement `FORGEJO__repository__ENABLE_PUSH_CREATE_ORG=true` (+ `..._USER`), créer l'org
      cible, boucler les push, puis **remettre à `false`**.

!!! warning "Garder l'ancien dossier jusqu'à vérification"
    Ne pas supprimer `/data/portainer/forgejo` tant que les repos voulus ne sont pas confirmés présents
    (contenu + historique) dans la nouvelle instance. C'est le filet de sécurité.

## CI (runner) — non déployé

L'ancien `forgejo-runner` (Actions) n'est **pas** repris dans cette stack. S'il est réactivé un jour,
il faudra l'enregistrer contre la **nouvelle** instance (un runner enregistré sur l'ancienne renvoie
`unimplemented: 404 Not Found` en boucle).

---

**Sources :** `hosts/vps-prod/stacks/forgejo/compose.yaml` · ancienne installation observée
(`/data/portainer/forgejo`) · [Forgejo — Releases](https://forgejo.org/releases/) ·
[Forgejo — Administration](https://forgejo.org/docs/latest/admin/).
