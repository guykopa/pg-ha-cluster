# Test Phase 2 — HAProxy suit le failover

Script : [`scripts/02-failover-routing-test.sh`](../../../scripts/02-failover-routing-test.sh)

## Scénario

1. Constater quel nœud sert le endpoint **write** (HAProxy `:5000`).
2. Mettre le leader à terre (`scale=0`).
3. Sonder `:5000` jusqu'à ce qu'il ressert un **primary** (`pg_is_in_recovery
   = f`) porté par un **autre** nœud.
4. Restaurer l'ancien leader.

## Résultat mesuré

```
Avant   : leader pg2, write endpoint host = 10.0.1.3  (pg2)
Action  : scale pg2 = 0
Après   : nouveau primary pg1 servi par :5000, host = 10.0.1.14
Délai   : 31 s (bout-en-bout, mesuré par le test)
```

Le **changement d'IP backend** (10.0.1.3 → 10.0.1.14) prouve que HAProxy a
re-routé le trafic write vers le nouveau leader **sans aucune reconfiguration
manuelle** : la bascule découle uniquement des health-checks sur l'API REST
Patroni (`/master`).

## Lecture du délai (important)

Les **31 s** sont **majorées par l'instrumentation** : chaque itération de
sondage relance un conteneur `psql` jetable (~3-4 s) puis `sleep 2`. Le
re-route effectif se décompose ainsi :

| Contribution | Ordre de grandeur |
|---|---|
| Promotion d'un replica (SIGTERM via `scale=0`) | ~5 s (cf. Phase 1) |
| Détection HAProxy du nouveau `/master` (`inter 3s`, `rise 2`) | ~6 s |
| **Re-route réel** | **~10-15 s** |
| Surcoût de sondage du test (conteneurs psql + sleep) | le reste |

> Sur une **panne brutale** (nœud qui reste mort, sans SIGTERM), il faut
> ajouter l'attente d'expiration du lease (`ttl` ≈ 30 s) avant la promotion.
> Réduire le `ttl` et l'intervalle de health-check HAProxy diminue le RTO, au
> prix de plus de faux positifs / charge — trade-off à expliciter.

## Reproduire

```bash
bash scripts/02-failover-routing-test.sh
```
