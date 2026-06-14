# Phase 5 — Observabilité

> Statut : **5a fait ✅** (métriques + alerting + Grafana). 5b (logs Loki/Promtail) à suivre.

## Objectifs

- **Métriques** centralisées dans **Prometheus**, exposées dans **Grafana**.
- **Alerting** sur les conditions HA critiques via **Alertmanager**.
- (5b) **Logs** centralisés via **Loki + Promtail**.

## Architecture (5a)

```
Prometheus  ── scrape ──> Patroni /metrics (pg1,pg2,pg3 :8008)   # rôle, réplication, santé
            ── scrape ──> HAProxy /metrics (:8404)                # backends up/down, sessions
            ── scrape ──> postgres-exporter (-> HAProxy :5000)    # internals PG du leader
            ── scrape ──> node-exporter, cAdvisor                 # hôte, conteneurs
            ── rules ──>  Alertmanager (:9093)
Grafana (:3000) ── datasource ──> Prometheus
```

> Astuce clé : **Patroni expose un `/metrics` natif** (`patroni_primary`,
> `patroni_replica`, `patroni_postgres_running`, positions xlog…) et **HAProxy
> a un exporter Prometheus intégré** (`http-request use-service
> prometheus-exporter`). On évite ainsi des exporters dédiés pour l'état HA.

## Fichiers

| Élément | Fichier |
|---|---|
| Scrape config Prometheus | `config/prometheus/prometheus.yml` |
| Règles d'alerte | `config/prometheus/alerts.yml` |
| Config Alertmanager | `config/alertmanager/alertmanager.yml` |
| Datasources Grafana | `config/grafana/provisioning/datasources/datasources.yml` |
| Provider + dashboard Grafana | `config/grafana/.../dashboards/`, `config/grafana/dashboards/pgquorum-overview.json` |
| Stack monitoring | `swarm-stacks/monitoring.yml` |
| Déploiement | `scripts/05-deploy-monitoring.sh` |
| Validation | `scripts/05-verify-monitoring.sh` |

## Secrets / accès

- Mot de passe admin Grafana : **`docker secret`** `grafana_admin_password`
  (lu via `GF_SECURITY_ADMIN_PASSWORD__FILE`).
- Rôle PostgreSQL `monitoring` (`pg_monitor`) pour postgres-exporter ; le DSN
  (avec mot de passe) est **interpolé depuis l'environnement au déploiement**
  (`MONITORING_PW`), jamais commité. En prod : exporter compatible secret-file
  ou Vault.

## Alertes (HA)

| Alerte | Condition | Sévérité |
|---|---|---|
| `PatroniNoLeader` | `count(patroni_primary==1)==0` 30s | critical |
| `PostgresDown` | `patroni_postgres_running==0` 1m | warning |
| `NotEnoughReplicas` | `count(patroni_replica==1)<2` 2m | warning |
| `ReplicationLagHigh` | lag replica > 64 Mo 1m | warning |
| `HAProxyWriteBackendDown` | `haproxy_backend_active_servers{proxy="pg_write"}<1` | critical |
| `TargetDown` | `up==0` 1m | warning |

## Ports publiés (dev)

| Port | Service |
|---|---|
| 9090 | Prometheus |
| 3000 | Grafana (admin / secret) |
| 9093 | Alertmanager |

## Commandes

```bash
bash scripts/05-deploy-monitoring.sh   # secrets + rôle monitoring + déploiement
bash scripts/05-verify-monitoring.sh   # tous les targets UP + endpoints healthy
```

## Test de validation

`05-verify-monitoring.sh` → tous les jobs **UP** (patroni 3/3, haproxy, postgres,
node, cadvisor, prometheus) + Prometheus/Alertmanager/Grafana healthy.

Alerting de bout en bout : couper un replica (`docker service scale
pgquorum_pg1=0`) déclenche `PostgresDown`/`TargetDown` (~après le `for`), visible
dans Prometheus `/alerts` **et** dans Alertmanager.

## Problèmes rencontrés

- **`docker config` immuable** : ajouter `/metrics` à HAProxy imposait de
  recréer le config → renommé `haproxy_cfg` → `haproxy_cfg_v2` pour que
  `docker stack deploy` le mette à jour.

## Limites / 5b

- **Logs** (Loki + Promtail) : phase 5b.
- Dashboard minimal (overview) ; enrichissable (import de dashboards
  communautaires Patroni/HAProxy/PgBouncer).
