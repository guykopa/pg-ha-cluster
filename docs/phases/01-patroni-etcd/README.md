# Phase 1 — Cluster PostgreSQL HA (Patroni + etcd)

> Statut : **en cours** (cluster fonctionnel, failover automatique validé).

## Objectifs

Monter un cluster PostgreSQL 16 hautement disponible :

- **etcd** : cluster 3 membres (DCS), quorum Raft → source de vérité de
  l'élection de leader.
- **Patroni** : un agent par nœud PostgreSQL (`pg1`, `pg2`, `pg3`) qui
  démarre/promeut/rétrograde PostgreSQL selon l'état dans etcd et expose une
  API REST (`/cluster`, `/health`, `/switchover`…).
- **Réplication streaming asynchrone** (1 leader + 2 replicas), avec
  **replication slots** (`use_slots: true`) pour éviter la perte de WAL.
- **Failover automatique** : à la perte du leader, un replica est promu sans
  intervention humaine.

## Composants & fichiers

| Élément | Fichier |
|---|---|
| Image Patroni (postgres:16 + Patroni) | `docker/patroni/Dockerfile` |
| Config Patroni (template envsubst) | `docker/patroni/patroni.yml.tmpl` |
| Entrypoint (secrets → env → rendu config) | `docker/patroni/entrypoint.sh` |
| Stack (etcd ×3 + Patroni ×3) | `swarm-stacks/pg-cluster.yml` |
| Déploiement (génère les secrets) | `scripts/01-deploy-pg-cluster.sh` |
| Validation (etcd + rôles Patroni) | `scripts/01-verify-pg-cluster.sh` |
| Test de failover | `scripts/01-failover-test.sh` |

## Secrets

Les mots de passe PostgreSQL (`postgres`, `replicator`) ne sont **jamais en
clair** : ils sont stockés en **`docker secret`** (`pg_superuser_password`,
`pg_replication_password`), montés dans les conteneurs sous `/run/secrets/`,
lus par `entrypoint.sh` et injectés dans la config rendue. En dev, le script
de déploiement génère des valeurs aléatoires et les enregistre dans
`secrets/dev-credentials.env` (git-ignoré) pour pouvoir s'y connecter.

## Commandes

```bash
# Pré-requis : Phase 0 (swarm + réseaux) + image Patroni
DOCKER_BUILDKIT=0 docker build -t pgquorum/patroni:16 docker/patroni

# Déployer
bash scripts/01-deploy-pg-cluster.sh

# Valider (etcd quorum + 1 leader / 2 replicas)
bash scripts/01-verify-pg-cluster.sh

# État du cluster Patroni
pc=$(docker ps -q -f name=pgquorum_pg1)
docker exec "$pc" patronictl -c /tmp/patroni/patroni.yml list

# Membres etcd
ec=$(docker ps -q -f name=pgquorum_etcd1)
docker exec "$ec" etcdctl member list
```

## Test de validation (failover)

```bash
bash scripts/01-failover-test.sh
```

Résultats détaillés et mesures : voir [`failover-test.md`](./failover-test.md).

## Paramètres DCS clés (`patroni.yml.tmpl`)

| Paramètre | Valeur | Rôle |
|---|---|---|
| `ttl` | 30 s | Durée du lease leader ; son expiration déclenche l'élection. **C'est l'ordre de grandeur du RTO** lors d'une panne brutale. |
| `loop_wait` | 10 s | Période de la boucle Patroni. |
| `retry_timeout` | 10 s | Budget de retry sur opérations DCS/PostgreSQL. |
| `maximum_lag_on_failover` | 1 Mo | Lag max toléré pour qu'un replica soit éligible. |
| `use_pg_rewind` | true | Re-synchronise à moindre coût un ancien leader rétrogradé. |

> **RPO / RTO.** Réplication **asynchrone** → un failover peut perdre les
> dernières transactions non répliquées (**RPO > 0**). Le **RTO** dépend du
> type de perte : ~immédiat (switchover contrôlé), **~5 s** (arrêt propre
> SIGTERM, mesuré), **~TTL ≈ 30 s** (crash brutal où le nœud reste mort, car
> les replicas attendent l'expiration du lease). Détail et mesures :
> [`failover-test.md`](./failover-test.md).

## Problèmes rencontrés

- **Build de l'image Patroni** : `FROM postgres:16` échoue sous BuildKit
  (`error getting credentials` via `desktop.exe` + `vsock accept4 failed 110`
  sous WSL). Contournement : `docker pull postgres:16` puis build avec
  `DOCKER_BUILDKIT=0`.
- **Python Debian « externally managed »** (PEP 668) : Patroni installé dans
  un virtualenv (`/opt/patroni`) plutôt qu'en global.

## Limites (dev mono-nœud)

- Failover démontré au niveau **conteneur** (`docker kill`), pas **hôte**
  . Le mécanisme Patroni/etcd est identique.
- `watchdog: off` (pas de `/dev/watchdog` en conteneur). Sur hôte réel, le
  watchdog renforce la protection anti split-brain.
