# Portfolio

Site **Astro** (portfolio scolaire BUT) compilé en statique et servi par **nginx**, exposé en public
sur **`but.lucasmasse.net`**.

Source : `hosts/vps-prod/stacks/portfolio/compose.yaml`. Déployé par Komodo (stack `portfolio`, tag
`app`, `after = ["traefik"]`).

## Fonctionnement

| Élément | Valeur | Source |
| --- | --- | --- |
| Code source | `git.lucasmasse.net/PortableStick/portfolioscolaire` (branche `main`) | `compose.yaml` (`build:`) |
| Build | multi-stage : `node` build Astro → image `nginx` servant `/dist` | Dockerfile du repo |
| Port interne | `80` (nginx) | Dockerfile (`EXPOSE 80`) |
| Domaine | `but.lucasmasse.net` | `compose.yaml` + `astro.config.mjs` (`site:`) |
| Exposition | **publique** (porte 3 — sans authentification) | labels Traefik |
| Réseau | `frontend` | `compose.yaml` |

Le service se **construit directement depuis le dépôt Forgejo** (contexte git BuildKit) :

```yaml
build: https://git.lucasmasse.net/PortableStick/portfolioscolaire.git#main
```

!!! warning "Dépendance à Forgejo pour le build"
    Le build clone `git.lucasmasse.net` en HTTPS. Il faut donc que **Forgejo soit en ligne avec un
    certificat valide** au moment du build, et que le repo existe bien à
    `PortableStick/portfolioscolaire` (la **casse** compte dans l'URL). Voir [Forgejo](forgejo.md).

## Labels Traefik

```yaml
- "traefik.enable=true"
- "traefik.docker.network=frontend"
- "traefik.http.routers.portfolio.rule=Host(`but.lucasmasse.net`)"
- "traefik.http.routers.portfolio.entrypoints=websecure"
- "traefik.http.routers.portfolio.tls=true"
- "traefik.http.services.portfolio.loadbalancer.server.port=80"
```

Pas de `tls.certresolver` : le service utilise le résolveur `letsencrypt` + le wildcard
`*.lucasmasse.net` **par défaut de l'entrypoint** (voir la « règle d'or » dans
[Reverse proxy & TLS](reverse-proxy-tls.md)). Le wildcard couvre `but.lucasmasse.net`, donc **aucun
CNAME supplémentaire** n'est nécessaire pour ce service.

## Déploiement

1. S'assurer que le repo `PortableStick/portfolioscolaire` est présent dans Forgejo (voir
   [Forgejo](forgejo.md)) et que `but.lucasmasse.net` a un enregistrement **A → `116.202.22.50`** chez
   Cloudflare.
2. Déployer la stack via Komodo (ou `docker compose up -d --build` dans le dossier de la stack — le
   `--build` force le clone + build depuis Forgejo).

**Vérification :**

```bash
dig +short but.lucasmasse.net          # -> 116.202.22.50
curl -I https://but.lucasmasse.net     # 200, certificat *.lucasmasse.net valide
```

!!! note "Changer de domaine"
    Le domaine vit à deux endroits : le label `Host(...)` **et** `astro.config.mjs` (`site:`, utilisé
    pour le sitemap et les URLs canoniques). Pour passer `but.lucasmasse.net` à autre chose, il faut
    modifier **les deux** puis re-builder, sinon le sitemap pointe vers l'ancien domaine.

---

**Sources :** `hosts/vps-prod/stacks/portfolio/compose.yaml`, dépôt `portfolioscolaire` (Dockerfile,
`astro.config.mjs`) · [Astro](https://docs.astro.build/) · [nginx](https://hub.docker.com/_/nginx).
