# pgquorum

[![CI](https://github.com/guykopa/pg-ha-cluster/actions/workflows/ci.yml/badge.svg)](https://github.com/guykopa/pg-ha-cluster/actions/workflows/ci.yml)

Cluster **PostgreSQL hautement disponible** sur Docker Swarm : **Patroni + etcd**
(failover automatique), **HAProxy + PgBouncer** (routage write/read + pooling),
déploiement automatisé via **Ansible**, supervision **Prometheus / Grafana /
Loki / Alertmanager**.

> Projet DevOps/SRE.
> En local (WSL2) tout tourne en conteneurs sur un Swarm **mono-nœud** ; la
> cible est un Swarm **3 nœuds** — mêmes artefacts, seul le nombre de nœuds change.

## Stack

| Couche | Outils |
|---|---|
| Orchestration | Docker Swarm (réseaux overlay, secrets, configs, stacks) |
| Base HA | PostgreSQL 16 + Patroni + etcd (quorum Raft) |
| Routage / pooling | HAProxy (health-check API Patroni) + PgBouncer (transaction pooling) |
| Automatisation | Ansible (rôles idempotents, secrets via `ansible-vault`) ; AWX (conçu) |
| Observabilité | Prometheus, Grafana, Loki/Promtail, Alertmanager, exporters |
| CI | GitHub Actions (lint, build, intégration HA + failover) |

## Architecture

```
app → PgBouncer (pooling) → HAProxy ─┬─ :5000 write → leader   (Patroni /master)
                                     └─ :5001 read  → replicas  (Patroni /replica)
                  etcd (DCS, quorum Raft) ←→ Patroni × 3 (1 leader + 2 replicas)
observabilité : Prometheus + Grafana + Loki/Promtail + Alertmanager
```

## Résultats validés (dev)

| Mesure | Valeur |
|---|---|
| Failover automatique (arrêt propre du leader) | replica promu en **~5 s** |
| RTO écriture mesuré sous charge (`pgbench` + coupure) | **~10 s**, 0 donnée committée perdue |
| Suivi HAProxy après failover | endpoint write re-routé **sans reconfiguration** |
| Charge — write (TPC-B) / read (`-S`) | **~390** / **~4900 tps** (read/write split) |
| Goulot identifié via `pg_stat_statements` | contention de verrou (UPDATE branches, 80 % du temps) |
| Logs centralisés (Loki) | 16 conteneurs |

## Démarrage rapide (dev)

> Sous WSL/Docker Desktop, builder avec `DOCKER_BUILDKIT=0`.

```bash
# Phase 0-1 : socle + cluster HA
bash scripts/00-bootstrap-swarm.sh
DOCKER_BUILDKIT=0 docker build -t pgquorum/patroni:16 docker/patroni
bash scripts/01-deploy-pg-cluster.sh && bash scripts/01-verify-pg-cluster.sh
bash scripts/01-failover-test.sh                 # test de failover automatique

# Phase 2 : proxy
DOCKER_BUILDKIT=0 docker build -t pgquorum/pgbouncer:1 docker/pgbouncer
bash scripts/02-deploy-proxy.sh && bash scripts/02-verify-proxy.sh

# Phase 5 : observabilité (Grafana :3000 · Prometheus :9090 · Alertmanager :9093)
bash scripts/05-deploy-monitoring.sh && bash scripts/05-verify-monitoring.sh

# Phase 4 : tout reconstruire via Ansible
cd ansible && ansible-playbook playbooks/site.yml
```

## CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) — 3 jobs :
- **lint** : yamllint, shellcheck, `ansible --syntax-check`, hadolint ;
- **build** : images Patroni / PgBouncer ;
- **integration** : `swarm init` → déploiement du cluster → vérification HA
  (1 leader / 2 replicas) → **test de failover automatique**.

## Phases

| # | Contenu | Doc |
|---|---|---|
| 0 | Socle Docker Swarm | [docs](docs/phases/00-swarm-foundation/) |
| 1 | PostgreSQL HA (Patroni + etcd) | [docs](docs/phases/01-patroni-etcd/) |
| 2 | HAProxy + PgBouncer | [docs](docs/phases/02-haproxy-pgbouncer/) |
| 3 | Administration & perf | [docs](docs/phases/03-admin-perf/) |
| 4 | Ansible + AWX | [docs](docs/phases/04-ansible-awx/) |
| 5 | Observabilité | [docs](docs/phases/05-observability/) |

Bonus à venir : `pgctl`, CLI de pilotage en architecture hexagonale (TDD).

## Sécurité des secrets

Aucun secret en clair dans le dépôt : **`docker secret`** (runtime) +
**`ansible-vault`** (au repos). PgBouncer s'authentifie via `auth_query`
(SCRAM), sans mot de passe applicatif dans sa config.
