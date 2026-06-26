# Poste de travail : installer et configurer SOPS + age

Cette page explique comment préparer **ton PC** pour lire, éditer et chiffrer les secrets du dépôt.
Les secrets sont chiffrés avec **age** (l'outil de chiffrement) piloté par **SOPS** (qui gère le
format de fichier et les règles `.sops.yaml`).

!!! danger "Point crucial : déchiffrer ≠ générer une clé"
    Les secrets déjà présents dans le dépôt (`secrets/vps/komodo.env`) sont chiffrés **pour une clé
    publique précise**, déclarée dans `.sops.yaml` :

    ```
    age16jmqm9c42x330uyvdf07lq2qy892c7hdj96t6dw4m9rmhy4cw96spyc5cr
    ```

    Pour les **lire**, il faut posséder la **clé privée correspondante** (la clé maître). Générer une
    nouvelle clé avec `age-keygen` ne sert **pas** à lire ces secrets : ça crée une autre identité, qui
    ne pourra rien déchiffrer tant qu'on n'a pas re-chiffré les secrets pour elle.

    La clé privée maître est stockée à **deux** endroits (selon l'opérateur) :

    - dans **Bitwarden** (sauvegarde « break-glass ») ;
    - sur le VPS dans `/etc/komodo/age/key.txt` (accessible root uniquement).

## 1. Installer age et sops

=== "Ubuntu / Debian"

    ```bash
    # age : paquet officiel disponible dans les dépôts récents
    sudo apt update
    sudo apt install -y age

    # sops : récupérer le binaire depuis les releases GitHub officielles
    # (remplacer la version par la dernière release publiée)
    SOPS_VERSION="v3.9.4"
    curl -LO "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64"
    sudo install -m 0755 "sops-${SOPS_VERSION}.linux.amd64" /usr/local/bin/sops
    sops --version
    ```

=== "macOS (Homebrew)"

    ```bash
    brew install age sops
    ```

=== "Windows"

    ```powershell
    winget install FiloSottile.age
    winget install Mozilla.SOPS
    ```

!!! info "À compléter — versions"
    Vérifier la dernière release de sops sur <https://github.com/getsops/sops/releases> et celle d'age
    sur <https://github.com/FiloSottile/age/releases>, puis épingler les versions réellement utilisées.
    `v3.9.4` ci-dessus est un exemple à confirmer, pas une valeur tirée du dépôt.

## 2. Placer la clé privée maître

SOPS cherche la clé age, dans l'ordre :

1. la variable d'environnement `SOPS_AGE_KEY` (contenu de la clé) ;
2. la variable d'environnement `SOPS_AGE_KEY_FILE` (chemin vers le fichier) ;
3. à défaut, le fichier par défaut `~/.config/sops/age/keys.txt`
   (sous Windows : `%AppData%\sops\age\keys.txt`).

Récupère la clé privée depuis Bitwarden et place-la dans le fichier par défaut :

```bash
mkdir -p ~/.config/sops/age
# Colle le contenu de la clé (lignes "# created: ..." + "# public key: ..." + "AGE-SECRET-KEY-...")
$EDITOR ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

Ou, ponctuellement, via une variable d'environnement pointant vers un autre fichier :

```bash
export SOPS_AGE_KEY_FILE=/chemin/vers/key.txt
```

Vérifie que la clé publique de ta clé privée correspond bien à celle de `.sops.yaml` :

```bash
# Affiche la clé publique dérivée de la clé privée
age-keygen -y ~/.config/sops/age/keys.txt
# Doit afficher : age16jmqm9c42x330uyvdf07lq2qy892c7hdj96t6dw4m9rmhy4cw96spyc5cr
```

Si la sortie diffère, tu n'as pas la bonne clé privée — tu ne pourras pas déchiffrer.

## 3. Lire et éditer un secret

```bash
# Afficher en clair (déchiffre vers la sortie standard, n'écrit rien sur disque)
sops -d secrets/vps/komodo.env

# Éditer en place : sops déchiffre dans un éditeur temporaire,
# puis re-chiffre automatiquement à la fermeture
sops secrets/vps/komodo.env
```

`sops` applique automatiquement les règles de `.sops.yaml` (quel chemin → quelle clé). Il n'y a donc
rien à préciser en ligne de commande tant que le chemin correspond à une règle.

## 4. Créer un nouveau secret

Crée le fichier au bon emplacement (pour qu'une règle `.sops.yaml` s'applique), puis édite-le avec
`sops` — il sera chiffré dès la première sauvegarde :

```bash
sops secrets/vps/nouveau-service.env
```

La règle actuelle de `.sops.yaml` couvre `secrets/vps/*.env` :

```yaml
creation_rules:
  - path_regex: secrets[\\/]vps[\\/].*\.env$
    age: age16jmqm9c42x330uyvdf07lq2qy892c7hdj96t6dw4m9rmhy4cw96spyc5cr
```

## 5. (Optionnel) Générer une nouvelle clé / changer de destinataire

Utile pour ajouter un second poste, faire tourner la clé maître, ou borner le rayon de souffle par
hôte (comme évoqué dans les commentaires de `.sops.yaml` de l'étape intermédiaire).

```bash
# Générer une nouvelle paire ; la clé publique est imprimée et stockée dans le fichier
age-keygen -o ~/.config/sops/age/keys.txt
# -> "Public key: age1......"
```

Ajoute ensuite cette clé publique comme destinataire dans `.sops.yaml`, puis **re-chiffre** les
secrets existants pour qu'ils soient lisibles par la nouvelle clé :

```bash
sops updatekeys secrets/vps/komodo.env
```

!!! warning "Ne jamais committer la clé privée"
    Le `.gitignore` du dépôt exclut déjà `key.txt`, `*.key`, `*.pem` et le dossier `age/`. Le hook
    `pre-commit` et la CI gitleaks ajoutent un filet de sécurité, mais la première ligne de défense,
    c'est de ne jamais sortir la clé privée de Bitwarden / du fichier protégé. Voir
    [Secrets (SOPS/age)](secrets-sops.md) et [Sécurité & CI](securite-ci.md).

---

**Sources :** [SOPS (getsops/sops)](https://github.com/getsops/sops) ·
[age (FiloSottile/age)](https://github.com/FiloSottile/age) · clés et chemins : `.sops.yaml`,
`.gitignore` du dépôt.
