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
```

- **Règle :** tout fichier `secrets/vps/*.env` est chiffré pour la clé publique age ci-dessus.
- **Clé déclarée :** clé **publique** (sert à chiffrer). La clé **privée** correspondante (qui
  déchiffre) est la clé maître.
- **Secret existant :** `secrets/vps/komodo.env`, chiffré (chaque valeur est un blob
  `ENC[AES256_GCM,...]`). Les **noms** des variables restent en clair, seules les **valeurs** sont
  chiffrées — c'est le comportement attendu de SOPS pour un `.env`.

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

!!! warning "État actuel : déchiffrement manuel ; automatisation non testée"
    Aujourd'hui, ce rendu se fait **à la main** pour bootstrapper Komodo. L'idée de faire **déchiffrer
    automatiquement les secrets des autres stacks par Komodo** (au moment du déploiement) est
    **envisagée mais pas testée**. Tant que ce n'est pas validé, partir du principe que **chaque secret
    doit être rendu manuellement** sur l'hôte avant le déploiement de sa stack.

    L'étape intermédiaire (dépôt `infra`) prévoyait un rendu automatique via un timer systemd
    `render-secrets` ; ce mécanisme **n'est pas présent** dans `homelab-infra`. À implémenter et
    documenter ici si tu pars sur cette voie.

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
    une seule clé couvre `secrets/vps/`. Documenter ici toute évolution (nouvelle clé, rotation,
    `sops updatekeys`).

---

**Sources :** `.sops.yaml`, `secrets/vps/komodo.env`, `.gitignore`, `.githooks/pre-commit` du dépôt ·
[SOPS (getsops/sops)](https://github.com/getsops/sops) · [age (FiloSottile/age)](https://github.com/FiloSottile/age).
