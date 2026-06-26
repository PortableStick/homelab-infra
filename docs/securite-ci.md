# Sécurité & CI

Deux garde-fous protègent le dépôt contre la fuite de secrets : un **hook local** (avant le commit)
et un **scan en CI** (sur push/PR). Plus le complément `.gitignore` décrit dans
[Secrets (SOPS/age)](secrets-sops.md).

## Hook local — `.githooks/pre-commit`

```bash
#!/usr/bin/env bash
set -euo pipefail

for f in $(git diff --cached --name-only --diff-filter=ACM | grep '^secrets/' || true); do
  if [ -s "$f" ] && ! grep -q 'ENC\[' "$f"; then
    echo "$f n'est pas chiffre."
    exit 1
  fi
done

gitleaks protect --staged --redact --no-banner
```

Ce que fait le hook :

1. liste les fichiers indexés (staged) sous `secrets/` ;
2. pour chacun non vide, **échoue** s'il ne contient pas le marqueur `ENC[` (preuve d'un chiffrement
   SOPS) — donc un secret en clair bloque le commit ;
3. lance `gitleaks protect --staged` pour détecter d'éventuels secrets dans le reste du diff indexé.

!!! warning "Le hook doit être activé explicitement"
    Git n'exécute pas automatiquement les hooks d'un dossier non standard. Après un `git clone`, il
    faut pointer Git vers `.githooks` :

    ```bash
    git config core.hooksPath .githooks
    chmod +x .githooks/pre-commit   # si nécessaire
    ```

    Cette commande est **locale au clone** : à refaire sur chaque poste / après chaque nouvelle
    récupération du dépôt. `gitleaks` doit aussi être installé localement pour que la dernière ligne
    fonctionne.

## CI — `.github/workflows/gitleaks.yml`

```yaml
name: gitleaks
on: [push, pull_request]
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

- Déclenché sur **chaque push et chaque pull request**.
- `fetch-depth: 0` récupère **tout l'historique** pour que gitleaks scanne aussi les anciens commits.
- C'est le filet côté serveur, indépendant du poste de l'auteur (utile si quelqu'un n'a pas activé le
  hook local).

## Configuration gitleaks — `.gitleaks.toml`

```toml
title = "gitleaks config homelab-infra"

[extend]
useDefault = true

[allowlist]
description = "Secrets AGE/SOPS"
regexes = [
  '''age1[0-9a-z]{58}''',
  '''ENC\[AES256_GCM,.*\]''',
]
paths = [
  '''\.sops\.yaml$''',
]
```

- `useDefault = true` : repart des règles gitleaks par défaut, puis ajoute des exceptions.
- **Allowlist** : ne signale **pas** comme fuite ce qui est attendu et non sensible :
  - les **clés publiques** age (`age1` + 58 caractères) — publiques par nature ;
  - les **valeurs chiffrées** SOPS (`ENC[AES256_GCM,...]`) — déjà chiffrées ;
  - le fichier `.sops.yaml` (ne contient que des clés publiques et des règles).

!!! info "Cohérence à garder"
    Si tu changes le format des secrets (autre algo que `AES256_GCM`, autre type de clé), pense à
    mettre à jour ces regex, sinon gitleaks lèvera des faux positifs (ou, pire, laissera passer un cas
    non couvert).

---

**Sources :** `.githooks/pre-commit`, `.github/workflows/gitleaks.yml`, `.gitleaks.toml` du dépôt ·
[gitleaks](https://github.com/gitleaks/gitleaks).
