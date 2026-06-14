# Test de validation Phase 1 — Failover automatique

Script : [`scripts/01-failover-test.sh`](../../../scripts/01-failover-test.sh)

## Scénario

1. Identifier le leader courant.
2. **Mettre son nœud à terre et l'y maintenir** (`docker service scale … =0`)
   → simule la **perte durable d'un hôte**.
3. Attendre la promotion d'un replica ; mesurer le temps de bascule.
4. Relancer l'ancien nœud (`scale … =1`) et vérifier qu'il **réintègre comme
   replica** (pg_rewind sur la nouvelle timeline).

## Résultat mesuré (dev, Swarm mono-nœud)

```
Leader initial      : pg3
Nouveau leader      : pg2        (failover : 5 s)
Réintégration pg3   : Replica    (rejoin   : 7 s)
État final          : pg2 Leader, pg1 + pg3 Replicas, timeline 3, lag 0
```

```
+ Cluster: pgquorum ----+---------+-----------+----+-------------+-----+
| Member | Host | Role    | State     | TL | Receive LSN | Lag |
+--------+------+---------+-----------+----+-------------+-----+
| pg1    | pg1  | Replica | streaming |  3 |   0/5000348 |   0 |
| pg2    | pg2  | Leader  | running   |  3 |             |     |
| pg3    | pg3  | Replica | streaming |  3 |   0/5000348 |   0 |
+--------+------+---------+-----------+----+-------------+-----+
```

L'incrément de **timeline** (1 → 2 → 3 au fil des tests) est la preuve qu'une
**promotion** a bien eu lieu à chaque bascule.

## Pourquoi `scale=0` et pas seulement `docker kill` ?

Première version du test : `docker kill` du conteneur leader. Échec — **aucun
nouveau leader** observé. Diagnostic :

> Swarm a un `restart_policy: any` et le volume de données est **persistant**.
> Il a donc **redéployé le même nœud en quelques secondes**, qui a **repris le
> leadership** avant que les replicas ne se promeuvent. L'orchestrateur
> auto-répare le nœud plus vite que le TTL.

C'est un comportement **réaliste et désirable** (résilience), mais il masque la
bascule vers un autre nœud. Pour démontrer un vrai failover, l'ancien leader
doit **rester absent plus longtemps que le lease** → d'où `scale=0` (l'hôte
« disparaît » et ne revient pas tant qu'on ne le décide pas).

## RTO observé : 5 s — pourquoi pas ~30 s (TTL) ?

`docker service scale=0` arrête le conteneur via **SIGTERM**. Patroni
l'intercepte, arrête PostgreSQL proprement et **libère le verrou de leader**
dans etcd → un replica est promu **immédiatement**, sans attendre l'expiration
du lease.

Trois régimes de RTO à distinguer (bon sujet d'entretien) :

| Type de perte du leader | Signal | RTO attendu | Pourquoi |
|---|---|---|---|
| Switchover contrôlé (`patronictl switchover`) | — | ~immédiat | Handover orchestré |
| Arrêt propre (`scale=0`, SIGTERM) | SIGTERM | **~5 s** (mesuré) | Patroni libère le lease |
| Crash brutal, nœud reste mort | SIGKILL | **~TTL (≈30 s)** | Les replicas attendent l'expiration du lease |

## RPO

Réplication **asynchrone** → en cas de crash brutal du leader, les dernières
transactions non encore répliquées peuvent être perdues : **RPO > 0**. Pour
RPO = 0, activer la réplication **synchrone** (`synchronous_mode`), au prix
d'une latence d'écriture accrue et d'une dépendance à la disponibilité d'un
replica synchrone (trade-off assumé).

## Reproduire

```bash
bash scripts/01-failover-test.sh          # TTL par défaut (30 s)
TIMEOUT=180 bash scripts/01-failover-test.sh
```
