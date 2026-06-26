# Procédures planifiées

Komodo exécute trois procédures automatiques, déclarées dans `komodo/stacks.toml` (tag `system`).
Une procédure enchaîne des « executions » selon une planification (`config.schedule`).

| Procédure | Horaire | Exécution | Rôle |
| --- | --- | --- | --- |
| **Rotate Server Keys** | Tous les jours à 06:00 | `RotateAllServerKeys` | Fait tourner les clés des serveurs connectés (communication Core ↔ Periphery) |
| **Backup Core Database** | Tous les jours à 01:00 | `BackupCoreDatabase` | Sauvegarde la base Komodo vers `/backups` |
| **Global Auto Update** | Tous les jours à 03:00 | `GlobalAutoUpdate` (`skip_auto_update = false`) | Pull + mise à jour auto des stacks/déploiements marqués `poll_for_updates`/`auto_update` |

## Détail (TOML du dépôt)

```toml
[[procedure]]
name = "Rotate Server Keys"
config.schedule = "Every day at 06:00"
# stage -> executions = [{ execution.type = "RotateAllServerKeys", ... }]

[[procedure]]
name = "Backup Core Database"
config.schedule = "Every day at 01:00"
# stage -> executions = [{ execution.type = "BackupCoreDatabase", ... }]

[[procedure]]
name = "Global Auto Update"
config.schedule = "Every day at 03:00"
# stage -> executions = [{ execution.type = "GlobalAutoUpdate", execution.params.skip_auto_update = false, ... }]
```

La procédure **Backup Core Database** correspond exactement au modèle par défaut documenté par Komodo
(créé automatiquement sur les installs v1.19.0+).

## Points d'attention

!!! warning "La sauvegarde est locale et non chiffrée"
    `BackupCoreDatabase` écrit dans `/backups` **sur le VPS**. D'après la doc Komodo, ces sauvegardes
    **ne sont pas chiffrées** et seules les **14 dernières** sont conservées (paramétrable via
    `max_backups` / `KOMODO_CLI_MAX_BACKUPS`). Une perte du VPS = perte des sauvegardes locales. La
    copie hors-site (Storage Box Hetzner) reste **à mettre en place** — voir
    [Restauration complète](restauration.md).

!!! warning "Mise à jour automatique quotidienne"
    `GlobalAutoUpdate` avec `skip_auto_update = false` met à jour automatiquement les ressources
    concernées chaque nuit. Combiné aux images non épinglées (`acme-dns:latest`, images FerretDB), une
    mise à jour amont peut être tirée sans validation. À surveiller / restreindre si tu veux des
    déploiements plus déterministes.

!!! info "À compléter — supervision restic"
    L'étape intermédiaire (dépôt `infra`) prévoyait une procédure `restic-check` (Action côté hôte)
    pour vérifier l'intégrité d'un dépôt restic et alerter. Elle **n'existe pas** dans `homelab-infra`.
    À documenter ici si une sauvegarde restic + supervision est ajoutée.

---

**Sources :** `komodo/stacks.toml` du dépôt · [Komodo — Procedures](https://komo.do/docs/automate/procedures) ·
[Komodo — Backup and Restore](https://komo.do/docs/setup/backup).
