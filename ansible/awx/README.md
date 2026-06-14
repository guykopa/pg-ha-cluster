# AWX — conception (non déployé en dev)

> **AWX n'est pas déployé** dans l'environnement de dev : il tourne lui-même
> sur Kubernetes avec sa propre base PostgreSQL et demande plusieurs Gio — non
> tenable sur ce WSL2 (~3,4 Gio libres, déjà 16 conteneurs). C'est une **limite
> assumée**. Les rôles et le playbook sont néanmoins
> **AWX-ready** : il suffit de pointer un AWX existant sur ce repo + l'inventaire.

## Ce qu'AWX apporterait par-dessus Ansible

Interface web + API + RBAC + planification au-dessus des mêmes playbooks.

### Project
- Source : ce dépôt Git (`ansible/`), branche `main`.
- Mise à jour automatique à chaque révision (SCM update on launch).

### Credentials
- **Vault** : le mot de passe `ansible-vault` stocké dans le *credential store*
  d'AWX (jamais en clair), remplace `--vault-password-file` / `.vault_pass`.
- **Machine** : clé SSH vers les nœuds (inventaire `prod`).

### Job Templates (un par étape)
| Template | Playbook / tags | Rôle(s) |
|---|---|---|
| `pgquorum-provision-swarm` | `site.yml --tags swarm,secrets,images` | docker_swarm, secrets, images |
| `pgquorum-deploy-db-cluster` | `site.yml --tags pg_cluster` | pg_cluster |
| `pgquorum-deploy-proxy` | `site.yml --tags proxy` | proxy |
| `pgquorum-deploy-monitoring` | `site.yml --tags monitoring` | monitoring |
| `pgquorum-site` | `site.yml` (tout) | tous |

> (Ajouter des `tags:` aux rôles dans `site.yml` pour activer ce découpage.)

### Workflow Template
```
pgquorum-provision-swarm
        │ (succès)
        ▼
pgquorum-deploy-db-cluster
        │ (succès)
        ▼
pgquorum-deploy-proxy ───► pgquorum-deploy-monitoring
```
Branche d'échec : notification (email/Slack) + arrêt.

### Survey (formulaire de lancement)
Paramètres exposés sans toucher au code :
- `replicas` (nombre de nœuds PostgreSQL),
- `pg_version` (ex. 16),
- `shared_buffers`, tailles de volumes,
- environnement cible (`dev` / `prod`).
Ces variables surchargent les `group_vars` au lancement.

### Jobs planifiés
- **Health-check** périodique (`site.yml --tags pg_cluster --check`).
- **Backup** quotidien (quand pgBackRest sera ajouté).

## Bascule vers AWX (résumé)
1. Déployer AWX (operator K8s) sur un cluster dédié.
2. Créer le Project (ce repo), les Credentials (vault + SSH).
3. Importer Job Templates + Workflow + Survey ci-dessus.
4. Pointer l'inventaire `prod` (3 nœuds réels).
