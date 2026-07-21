# homelab-infra

Documentation opérationnelle de l'infrastructure auto-hébergée décrite dans le dépôt
[`PortableStick/homelab-infra`](https://github.com/PortableStick/homelab-infra).

Objectif de cette doc : permettre de **comprendre chaque élément de la configuration** et de
**reconstruire l'infrastructure depuis zéro** après une perte du VPS.

## Principe directeur

D'après le `README.md` du dépôt :

> Self-hosted infra managed by Komodo. Versioned config, SOPS/age secrets, full recovery from repo + restore.

Concrètement :

- **Komodo** orchestre les déploiements en mode GitOps : il lit la configuration depuis ce dépôt
  Git et lance les stacks `docker compose` correspondantes.
- La **configuration est versionnée** dans Git (`hosts/`, `komodo/`).
- Les **secrets sont chiffrés** avec **SOPS + age** (`secrets/`), et seuls les fichiers chiffrés
  sont committés.
- La **reprise après sinistre** repose sur deux ingrédients : ce dépôt (configuration) **+** une
  restauration de la base Komodo depuis une sauvegarde.

!!! success "En place et fonctionnel"
    - **HTTPS valide en production** : certificats wildcard `*.lucasmasse.net`, `*.vindiesel.vip` et
      `*.int.vindiesel.vip` via Traefik (v3.6) + acme-dns, en Let's Encrypt **production**. Émission
      pilotée par un routeur générateur dédié (voir [Reverse proxy & TLS](reverse-proxy-tls.md)).
    - **Services applicatifs déployés** : [Forgejo](forgejo.md) (forge Git), [portfolio](portfolio.md)
      (site Astro public) et Immich (photos, deux instances sur l'hôte `vindiesel`).
    - **Authentification centralisée** : [Authelia](authelia.md) (SSO/2FA, portail public
      `auth.vindiesel.vip`) protège Komodo — connecté en OIDC — et sert de forward-auth pour les
      futurs services. Backend lldap (VPN-only), mails via smtp-relay (→ Brevo).
    - **Accès admin en VPN-only** : Komodo est exposé sur `komodo.int.vindiesel.vip`, joignable
      uniquement via Tailscale (`ipAllowList` + `userland-proxy: false` pour préserver l'IP source).
      Voir [Exposer un service en VPN-only](exposer-service-vpn-only.md).

!!! warning "Limites connues (à tenir à jour)"
    1. **Aucune sauvegarde hors-site n'est en place.** Komodo sauvegarde la base **localement** sur le
       VPS (procédure *Backup Core Database*). Une Storage Box Hetzner vierge est réservée pour la copie
       hors-site, mais **rien n'y est encore copié**. Voir [Restauration complète](restauration.md).
    2. **Le bootstrap initial de Komodo lui-même reste manuel.** Komodo n'existe pas encore au moment de
       son propre premier déploiement : son `.env` est rendu **à la main** (`scripts/bootstrap.sh`), une
       seule fois. Les autres stacks (`authelia`, `lldap`, `smtp-relay`, `immich-1`, `immich-2`), elles,
       déchiffrent leur secret **automatiquement** via le `pre_deploy` de `komodo/stacks.toml` à chaque
       déploiement. Voir [Secrets (SOPS/age)](secrets-sops.md).

## Conventions du dépôt

| Chemin | Rôle |
| --- | --- |
| `hosts/<hôte>/stacks/<nom>/` | Fichiers `compose.yaml` (et configs) d'une stack, rangés par hôte. Deux hôtes actuels : `vps-prod` (serveur Komodo `Local`) et `vindiesel` (serveur `docker-vindiesel`, Periphery distante — voir [Rattacher un hôte](rattacher-hote-periphery.md)). |
| `komodo/stacks.toml` | Déclaration Komodo : serveur, repo lié, resource sync, procédures planifiées, builder, et les stacks à déployer. |
| `secrets/<hôte>/*.env` | Secrets **chiffrés** SOPS/age. Jamais en clair dans Git. |
| `.sops.yaml` | Règles de chiffrement SOPS (quels chemins, quelle clé age). |
| `.gitleaks.toml` + `.github/workflows/gitleaks.yml` | Scan anti-fuite de secrets (CI + local). |
| `.githooks/pre-commit` | Refuse le commit d'un secret non chiffré et lance `gitleaks protect`. |
| `scripts/` | Scripts d'exploitation (actuellement vide hormis `.gitkeep`). |

## Carte de la documentation

- **[Architecture](architecture.md)** — l'hôte, le réseau, les domaines, les chemins de données.
- **[Poste de travail (SOPS/age)](poste-travail-sops-age.md)** — installer et configurer SOPS + age
  sur ton PC pour pouvoir lire/éditer les secrets.
- **[Komodo](komodo.md)** — Core, Periphery, base de données, GitOps et resource sync.
- **[Reverse proxy & TLS](reverse-proxy-tls.md)** — Traefik, entrypoints, certificats.
- **[acme-dns](acme-dns.md)** — serveur DNS dédié au challenge ACME.
- **[Forgejo](forgejo.md)** — forge Git auto-hébergée (`git.lucasmasse.net`).
- **[Portfolio](portfolio.md)** — site Astro public (`but.lucasmasse.net`).
- **[Authelia (SSO / 2FA)](authelia.md)** — portail d'authentification (`auth.vindiesel.vip`), lldap, relais SMTP.
- **[Secrets (SOPS/age)](secrets-sops.md)** — chiffrement, clé maître, workflow.
- **[Sécurité & CI](securite-ci.md)** — gitleaks, hook pre-commit.
- **[Procédures planifiées](procedures-planifiees.md)** — tâches automatiques de Komodo.
- **[Exposer un service en VPN-only](exposer-service-vpn-only.md)** — pattern d'accès privé via Tailscale.
- **[Obsidian LiveSync (CouchDB)](obsidian-livesync.md)** — sync des coffres Obsidian (`obsidian.lucasmasse.net`, **public**).
- **[Restauration complète](restauration.md)** — remonter l'infra depuis un VPS nu.

!!! note "Sources"
    Chaque page distingue ce qui vient **du dépôt** (cité par chemin de fichier), ce qui vient de la
    **documentation officielle d'un outil** (lien en bas de page), et ce qui reste **à compléter par
    l'opérateur** (bloc « À compléter »). Aucune valeur n'est inventée.
