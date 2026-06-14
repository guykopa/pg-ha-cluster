# pgquorum

[![CI](https://github.com/guykopa/pg-ha-cluster/actions/workflows/ci.yml/badge.svg)](https://github.com/guykopa/pg-ha-cluster/actions/workflows/ci.yml)

Cluster **PostgreSQL hautement disponible** sur Docker Swarm : **Patroni + etcd**
(failover automatique), **HAProxy + PgBouncer** (routage write/read + pooling),
automatisé via **Ansible**, supervisé par **Prometheus / Grafana / Loki /
Alertmanager**.

> Projet de portfolio DevOps/SRE. Détails de conception : [`ARCHITECTURE.md`](ARCHITECTURE.md).
> En dev (WSL2) tout tourne en conteneurs sur un Swarm **mono-nœud** ; la cible
> est un Swarm **3 nœuds** — mêmes artefacts (cf. ARCHITECTURE §1).

## Architecture

```
app → PgBouncer (pooling) → HAProxy ─┬─ :5000 write → leader   (Patroni /master)
                                     └─ :5001 read  → replicas  (Patroni /replica)
                              etcd (DCS, quorum Raft) ←→ Patroni × 3 (1 leader + 2 replicas)
observabilité : Prometheus + Grafana + Loki/Promtail + Alertmanager
```

## Démarrage rapide (dev)

```bash
# Phase 0-1 : socle + cluster HA
bash scripts/00-bootstrap-swarm.sh
DOCKER_BUILDKIT=0 docker build -t pgquorum/patroni:16 docker/patroni
bash scripts/01-deploy-pg-cluster.sh && bash scripts/01-verify-pg-cluster.sh

# Phase 2 : proxy
DOCKER_BUILDKIT=0 docker build -t pgquorum/pgbouncer:1 docker/pgbouncer
bash scripts/02-deploy-proxy.sh && bash scripts/02-verify-proxy.sh

# Phase 5 : observabilité
bash scripts/05-deploy-monitoring.sh && bash scripts/05-verify-monitoring.sh

# Ou tout via Ansible (Phase 4)
cd ansible && ansible-playbook playbooks/site.yml
```

Tests signature : `scripts/01-failover-test.sh` (failover auto) et
`scripts/demo-failover-under-load.sh` (RTO write mesuré sous charge).

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
