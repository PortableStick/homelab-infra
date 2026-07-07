# Secrets (SOPS/age)

Pour la mise en place côté poste de travail (installation, clés), voir
[Poste de travail (SOPS/age)](poste-travail-sops-age.md). Cette page documente l'organisation des
secrets **dans le dépôt** et leur cycle de vie sur l'hôte.

## Ce qui est chiffré, et avec quelle clé

`.sops.yaml` :

```yaml
creation_rules:
  - path_regex: secrets[\\/]vps[\\/].*\.env$
    age: age16jmqm9c42x330uyvdf07lq2qy892c7hdj96t6dw4m9rmhy4cw96spyc5cr
  - path_regex: secrets[\\/]vindiesel[\\/].*\.env$
    age: age16jmqm9c42x330uyvdf07lq2qy892c7hdj96t6dw4m9rmhy4cw96spyc5cr
```

- **Règle :** tout fichier `secrets/vps/*.env` **ou** `secrets/vindiesel/*.env` est chiffré pour la
  clé publique age ci-dessus (même clé pour les deux hôtes — pas de séparation par périmètre, cf.
  encadré en fin de page).
- **Clé déclarée :** clé **publique** (sert à chiffrer). La clé **privée** correspondante (qui
  déchiffre) est la clé maître.
- **Secrets existants :** `secrets/vps/{komodo,authelia,lldap,smtp-relay}.env` et
  `secrets/vindiesel/immich.env`, chiffrés (chaque valeur est un blob `ENC[AES256_GCM,...]`). Les
  **noms** des variables restent en clair, seules les **valeurs** sont chiffrées — c'est le
  comportement attendu de SOPS pour un `.env`.

## Où vit la clé privée maître

Selon l'opérateur, la clé privée est conservée à **deux** endroits :

| Emplacement | Rôle |
| --- | --- |
| **Bitwarden** | Sauvegarde « break-glass » (récupération en cas de perte du VPS) |
| `/etc/komodo/age/key.txt` sur le VPS | Clé utilisée sur l'hôte pour déchiffrer (accès root uniquement) |

!!! danger "Sans cette clé, rien n'est récupérable"
    Si la clé privée maître est perdue **aux deux** endroits, les secrets chiffrés du dépôt deviennent
    illisibles définitivement. La copie Bitwarden est donc le maillon critique de la reprise après
    sinistre. Vérifier régulièrement qu'elle est à jour et accessible.

## Du secret chiffré au conteneur

Le compose de Komodo charge `env_file: ./compose.env`, un fichier **non versionné**. Il faut donc le
**produire** à partir du secret chiffré, sur l'hôte, avant `docker compose up` :

```bash
# Sur le VPS, avec la clé privée disponible (SOPS_AGE_KEY_FILE=/etc/komodo/age/key.txt)
sops -d secrets/vps/komodo.env > hosts/vps-prod/stacks/komodo/compose.env
```

!!! note "Komodo : rendu manuel (poule et œuf) ; les autres stacks : rendu automatique via `pre_deploy`"
    Komodo lui-même n'existe pas encore au moment de son propre premier déploiement : son `.env` est
    donc forcément rendu **à la main** (`scripts/bootstrap.sh`), une seule fois.

    Une fois Komodo démarré, les autres stacks (`authelia`, `lldap`, `smtp-relay`, `immich-1`,
    `immich-2`) utilisent le **`pre_deploy`** de `komodo/stacks.toml` : à chaque déploiement, la
    Periphery lance `sops -d ../../../../secrets/<host>/<stack>.env > .env` avant `docker compose up`.
    Ça suppose que `sops` et `SOPS_AGE_KEY_FILE` sont disponibles **côté Periphery**, pas seulement sur
    l'hôte :

    - **Periphery conteneurisée** (serveur `Local`, VPS) : l'image ne fournit pas `sops` — le binaire de
      l'hôte est monté (`/usr/local/bin/sops:/usr/local/bin/sops:ro`) et `SOPS_AGE_KEY_FILE` est passé en
      variable d'environnement du service `periphery` (`hosts/vps-prod/stacks/komodo/compose.yaml`).
    - **Periphery native** (serveur `docker-vindiesel`) : `scripts/bootstrap-periphery.sh` installe `sops`
      et expose `SOPS_AGE_KEY_FILE` via un drop-in systemd (`periphery.service.d/sops.conf`).

    Le timer systemd `render-secrets` évoqué par l'étape intermédiaire (dépôt `infra`) n'est donc plus
    nécessaire : le rendu est intégré au cycle de déploiement Komodo.

## Filets de sécurité anti-fuite

Trois protections empêchent un secret en clair d'arriver dans Git (détaillées dans
[Sécurité & CI](securite-ci.md)) :

1. **`.gitignore`** — exclut `*.key`, `*.pem`, `key.txt`, `age/`, les `*.env`/`compose.env` non
   chiffrés, tout en gardant les `*.example`.
2. **Hook `.githooks/pre-commit`** — refuse tout fichier de `secrets/` qui ne contient pas `ENC[`
   (donc non chiffré), puis lance `gitleaks protect`.
3. **CI `gitleaks`** — scan sur chaque push / pull request.

!!! info "À compléter — rotation / périmètre par hôte"
    Les commentaires de l'étape intermédiaire évoquaient l'ajout d'une **clé publique par hôte** pour
    borner le rayon de souffle (un secret d'un hôte n'est déchiffrable que par cet hôte). Aujourd'hui,
    une seule clé couvre à la fois `secrets/vps/` et `secrets/vindiesel/`. Documenter ici toute
    évolution (nouvelle clé, rotation, `sops updatekeys`).

---

**Sources :** `.sops.yaml`, `secrets/{vps,vindiesel}/*.env`, `komodo/stacks.toml`,
`hosts/vps-prod/stacks/komodo/compose.yaml`, `scripts/{bootstrap,bootstrap-periphery}.sh`,
`.gitignore`, `.githooks/pre-commit` du dépôt ·
[SOPS (getsops/sops)](https://github.com/getsops/sops) · [age (FiloSottile/age)](https://github.com/FiloSottile/age).
