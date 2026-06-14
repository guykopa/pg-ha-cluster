# Phase 4 — Automatisation Ansible + AWX

> Statut : **fait ✅** — rôles Ansible idempotents validés ; AWX **conçu et
> documenté** (non déployé en dev, limite assumée).

## Objectifs

- Reproduire l'ensemble du cluster (Phases 0-2 + 5) via des **rôles Ansible
  idempotents**, au lieu de scripts.
- Gérer les secrets via **`ansible-vault`** (conforme `CLAUDE.md` §4/§7),
  remplaçant les valeurs aléatoires de dev.
- Concevoir la couche **AWX** (Job/Workflow Templates, Survey).

## Structure

```
ansible/
├── ansible.cfg                 # inventaire, roles_path, vault_password_file
├── inventories/
│   ├── dev/hosts.yml           # localhost (connection: local) -- swarm mono-nœud
│   │   └── group_vars/all/     # main.yml + vault.yml (chiffré) + .example
│   └── prod/hosts.yml          # cible 3 nœuds (stub)
├── playbooks/site.yml          # orchestration des rôles
├── roles/
│   ├── docker_swarm/           # swarm init + réseaux overlay
│   ├── secrets/                # docker secrets depuis le vault
│   ├── images/                 # build images patroni / pgbouncer
│   ├── pg_cluster/             # stack etcd+patroni + attente cluster sain
│   ├── proxy/                  # stack haproxy+pgbouncer + rôles DB
│   └── monitoring/             # stack observabilité + rôle monitoring
├── requirements.yml            # community.docker (optionnel)
└── awx/README.md               # conception AWX
```

> Mapping vs le découpage initial de `CLAUDE.md` : les rôles sont **alignés sur
> les unités de déploiement** (stacks) plutôt que 1 rôle par binaire —
> `pg_cluster` couvre etcd+patroni, `proxy` couvre haproxy+pgbouncer. Plus DRY
> (réutilise les stack files déjà validés).

## Choix techniques

- **Rôles basés sur la CLI `docker`** (pas le SDK Python) : zéro dépendance à
  installer, robuste avec l'Ansible/collection disponibles. Idempotence via
  *check-then-create* (`docker network ls`/`secret ls`/`image ls` puis `when:`).
  Alternative documentée : modules `community.docker` (nécessitent le SDK).
- **Secrets via `ansible-vault`** : `inventories/dev/group_vars/all/vault.yml`
  (chiffré AES-256, git-ignoré), template dans `vault.yml.example`. Le mot de
  passe vault est dans `.vault_pass` (git-ignoré) → en prod, *credential store*
  AWX.
- **Réutilisation des stacks** : les rôles déploient les `swarm-stacks/*.yml`
  déjà éprouvés (DRY) ; `docker stack deploy` converge sans redémarrage si la
  spec est identique.

## Commandes

```bash
cd ansible
# secrets : créer son vault à partir du template
cp inventories/dev/group_vars/all/vault.yml.example \
   inventories/dev/group_vars/all/vault.yml
ansible-vault encrypt inventories/dev/group_vars/all/vault.yml
echo "<mon-mot-de-passe-vault>" > .vault_pass   # git-ignoré

# déployer tout le cluster
ansible-playbook playbooks/site.yml
```

## Test de validation

`ansible-playbook playbooks/site.yml` exécuté sur le cluster en cours :
**`ok=12 changed=2 failed=0`**. swarm/réseaux/secrets/images **skipped**
(idempotents), stacks **no-op** (specs identiques), cluster reste sain
(vérifié : Phases 1 = 3/3, 2 = 5/5, 5 = tous targets UP + 16 services loggés).

> Les 2 `changed` sont les tâches de provisioning SQL (`changed_when: true`) ;
> elles re-`ALTER ROLE` aux mêmes valeurs (no-op fonctionnel). Sur un hôte
> vierge, le **même** playbook construit tout depuis zéro.

## AWX

Conçu dans [`ansible/awx/README.md`](../../../ansible/awx/README.md) : Project
(ce repo), Credentials (vault + SSH), Job Templates par étape, Workflow
`provision → db → proxy/monitoring`, Survey (replicas, version PG, volumes),
jobs planifiés. **Non déployé en dev** (ressources/complexité) — limite assumée.

## Limites / pistes

- AWX non déployé (cf. ci-dessus).
- Rôles `command`-based : passage aux modules `community.docker` possible si le
  SDK Python est disponible (idempotence native, check-mode).
- Provisioning SQL marqué `changed` à chaque run : affinables avec une
  détection de changement réelle.
