# Phase 3 — Administration & optimisation perf

> Statut : **fait ✅** (tuning appliqué via config dynamique Patroni,
> `pg_stat_statements` activé, benchmarks documentés).

## Objectifs

- **Tuner PostgreSQL** proprement (sans éditer un fichier à la main) via la
  **config dynamique Patroni** (stockée dans etcd, identique sur tous les
  nœuds), avec **rolling restart** pour les paramètres à redémarrage.
- **Activer `pg_stat_statements`** pour l'observabilité des requêtes.
- **Mesurer** avec `pgbench` (write/read) et **identifier les bottlenecks**.

## Fichiers

| Élément | Fichier |
|---|---|
| Application du tuning + rolling restart | `scripts/03-apply-tuning.sh` |
| Rapport de perf (pgbench + pg_stat_statements) | `scripts/03-perf-report.sh` |
| Démo failover sous charge (mesure RTO write) | `scripts/demo-failover-under-load.sh` |

## Paramètres appliqués

| Paramètre | Valeur | Type | Pourquoi |
|---|---|---|---|
| `shared_buffers` | 256MB | 🔴 restart | Cache de pages PostgreSQL |
| `effective_cache_size` | 768MB | 🟢 reload | Indice au planner sur le cache OS dispo |
| `work_mem` | 8MB | 🟢 reload | Mémoire par opération de tri/hash |
| `maintenance_work_mem` | 128MB | 🟢 reload | VACUUM / CREATE INDEX plus rapides |
| `random_page_cost` | 1.1 | 🟢 reload | Stockage SSD (accès aléatoire ~ séquentiel) |
| `checkpoint_completion_target` | 0.9 | 🟢 reload | Étale les écritures de checkpoint |
| `max_wal_size` / `min_wal_size` | 2GB / 128MB | 🟢 reload | Moins de checkpoints forcés sous charge |
| `shared_preload_libraries` | pg_stat_statements | 🔴 restart | Charge l'extension d'observabilité |

> Application : `PATCH /config` sur l'API REST Patroni → les params reloadable
> prennent effet immédiatement ; les params 🔴 deviennent `pending_restart`.

## Rolling restart (sans coupure write notable)

`scripts/03-apply-tuning.sh` redémarre **les replicas d'abord** (aucun impact
write), puis **le leader en place**. Le redémarrage en place conserve le
leadership (Patroni ne déclenche **pas** de failover) → la coupure write se
limite à la durée du redémarrage de PostgreSQL (quelques secondes), bien plus
courte qu'un failover. Vérifié : `pending_restart = 0` après coup, timeline
**inchangée** (pas de promotion).

## Résultats pgbench (scale 10, `-c 8 -j 4`)

| Charge | Avant tuning | Après tuning |
|---|---:|---:|
| Write (TPC-B), tps | ~369 | **~390** |
| Read-only (`-S`), tps | ~4324 | **~4918** |
| Read, latence moy. | 1,8 ms | **1,6 ms** |

> Gains modestes : sur un dev mono-hôte, le facteur limitant est l'I/O/WAL du
> leader et la **contention applicative** (voir ci-dessous), pas les buffers.
> L'intérêt de la phase est surtout la **méthode** (tuning versionné dans le
> DCS, rolling restart) et l'**observabilité**.

## Top requêtes (`pg_stat_statements`) — lecture

```
 calls | total_ms | mean_ms | pct  | query
-------+----------+---------+------+--------------------------------------
  7811 |  22235.0 |   2.847 | 80.1 | UPDATE pgbench_branches SET bbalance...
  7811 |   3359.7 |   0.430 | 12.1 | UPDATE pgbench_tellers  SET tbalance...
  7811 |   1556.6 |   0.199 |  5.6 | UPDATE pgbench_accounts SET abalance...
```

**Diagnostic** : 80 % du temps est consommé par l'`UPDATE pgbench_branches`.
À `scale 10` il n'existe que **10 lignes branches** ; 8 clients concurrents
mettent à jour les **mêmes lignes** → **contention de verrou ligne**. Les
`accounts` (1M lignes, contention quasi nulle) ne pèsent que 5,6 %.

C'est l'enseignement clé : `pg_stat_statements` pointe immédiatement le vrai
goulot (contention, pas volume). Remèdes possibles : augmenter le `scale`,
réduire la concurrence sur les lignes chaudes, ou repenser le modèle.

## Démo : RTO write mesuré sous charge

`scripts/demo-failover-under-load.sh` écrit en continu via HAProxy `:5000`,
coupe le leader en plein milieu et mesure la fenêtre d'indispo write à partir
des timestamps. Résultat type : **~10 s** (panne gracieuse), 0 donnée
committée perdue, reprise automatique.

## Reproduire

```bash
bash scripts/03-apply-tuning.sh     # tuning + rolling restart (idempotent)
bash scripts/03-perf-report.sh      # benchmarks + top requêtes
```
