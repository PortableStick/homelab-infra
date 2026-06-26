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

!!! warning "État réel au moment de la rédaction (à tenir à jour)"
    Deux éléments nécessaires à une restauration « perte totale du VPS » **n'existent pas encore**.
    Ils sont signalés comme tels dans toute la doc, et ne doivent pas être présentés comme acquis :

    1. **Aucune sauvegarde hors-site n'est en place.** Komodo sauvegarde la base **localement** sur le
       VPS (procédure *Backup Core Database*). Une Storage Box Hetzner vierge est réservée pour la copie
       hors-site, mais **rien n'y est encore copié**. Voir [Restauration complète](restauration.md).
    2. **Le déchiffrement automatique des secrets par Komodo n'est pas testé.** Aujourd'hui, le
       déchiffrement se fait **à la main** (`sops -d`) au moment du bootstrap de Komodo. L'automatisation
       pour les stacks suivantes est prévue mais **non validée**. Voir [Secrets (SOPS/age)](secrets-sops.md).

## Conventions du dépôt

| Chemin | Rôle |
| --- | --- |
| `hosts/<hôte>/stacks/<nom>/` | Fichiers `compose.yaml` (et configs) d'une stack, rangés par hôte. Seul hôte actuel : `vps-prod`. |
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
- **[Secrets (SOPS/age)](secrets-sops.md)** — chiffrement, clé maître, workflow.
- **[Sécurité & CI](securite-ci.md)** — gitleaks, hook pre-commit.
- **[Procédures planifiées](procedures-planifiees.md)** — tâches automatiques de Komodo.
- **[Restauration complète](restauration.md)** — remonter l'infra depuis un VPS nu.

!!! note "Sources"
    Chaque page distingue ce qui vient **du dépôt** (cité par chemin de fichier), ce qui vient de la
    **documentation officielle d'un outil** (lien en bas de page), et ce qui reste **à compléter par
    l'opérateur** (bloc « À compléter »). Aucune valeur n'est inventée.
