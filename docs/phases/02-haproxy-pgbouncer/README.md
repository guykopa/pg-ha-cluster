# Phase 2 — HAProxy + PgBouncer

> Statut : **fait ✅** (routage write/read validé, suivi de failover validé).

## Objectifs

Exposer le cluster aux applications avec **routage** et **pooling** :

- **HAProxy** : deux frontends TCP, routage piloté par l'**API REST Patroni**.
  - `write` (**:5000**) → l'unique nœud dont `/master` répond `200` (le leader).
  - `read` (**:5001**) → round-robin sur les nœuds dont `/replica` répond `200`.
- **PgBouncer** (**:6432**) : pooling de connexions en **transaction pooling**,
  devant HAProxy, avec deux bases logiques :
  - `appdb` → HAProxy write (leader) ;
  - `appdb_ro` → HAProxy read (replicas).

## Flux

```
app → PgBouncer :6432
        ├── appdb     → HAProxy :5000 → leader   (httpchk /master = 200)
        └── appdb_ro  → HAProxy :5001 → replicas  (httpchk /replica = 200, round-robin)
```

## Composants & fichiers

| Élément | Fichier |
|---|---|
| Config HAProxy (injectée via `docker config`) | `config/haproxy/haproxy.cfg` |
| Image + config PgBouncer | `docker/pgbouncer/` |
| Stack (haproxy + pgbouncer) | `swarm-stacks/proxy.yml` |
| Déploiement (secrets + rôles DB) | `scripts/02-deploy-proxy.sh` |
| Validation routage | `scripts/02-verify-proxy.sh` |
| Test suivi de failover | `scripts/02-failover-routing-test.sh` |

## Authentification PgBouncer (sans mot de passe en clair)

PgBouncer utilise **`auth_query`** (`auth_type = scram-sha-256`) : il se
connecte comme `auth_user = pgbouncer` et interroge une fonction
**`SECURITY DEFINER`** (`public.user_lookup`) qui lit les *verifiers* SCRAM
dans `pg_shadow`. Aucun mot de passe applicatif n'est stocké dans
`pgbouncer.ini` ; seul le credential de `pgbouncer` vit dans `userlist.txt`,
**rendu au démarrage depuis le `docker secret`** `pg_pgbouncer_password`.

Rôles/objets créés sur le leader par le script de déploiement (idempotent) :
`app` (LOGIN), `pgbouncer` (auth_user), base `appdb`, fonction `user_lookup`.

## Ports publiés (dev)

| Port | Service |
|---|---|
| 6432 | PgBouncer (point d'entrée applicatif) |
| 5000 / 5001 | HAProxy write / read (accès direct, pratique pour tester) |
| 8404 | UI de stats HAProxy (`http://localhost:8404`) |

## Commandes

```bash
# Pré-requis : Phase 1 déployée et saine, image pgbouncer construite
DOCKER_BUILDKIT=0 docker build -t pgquorum/pgbouncer:1 docker/pgbouncer

bash scripts/02-deploy-proxy.sh          # secrets + rôles + déploiement
bash scripts/02-verify-proxy.sh          # routage write/read (5 checks)
bash scripts/02-failover-routing-test.sh # HAProxy suit le nouveau leader
```

## Test de validation

`02-verify-proxy.sh` → **5/5** : write→primary, read→replica (direct HAProxy
et via PgBouncer), + écriture relue via le pool.

`02-failover-routing-test.sh` : après perte du leader, le endpoint write
(`:5000`) ressert un **nouveau** primary **sans reconfiguration** — HAProxy
re-route uniquement à partir des health-checks Patroni. Mesures :
[`failover-routing.md`](./failover-routing.md).

## Problèmes rencontrés

- **PgBouncer refuse de tourner en root** (Alpine) → image avec
  `USER pgbouncer` + `chown` de `/etc/pgbouncer`.
- **Détection du leader** : `curl` sans `-f` renvoie `0` même sur un HTTP `503`
  → un replica était pris pour le leader (`CREATE ROLE in a read-only
  transaction`). Corrigé avec `curl -fsS` (échec sur `503`).

## Limites / pistes

- Topologie **PgBouncer → HAProxy** : variante possible HAProxy → PgBouncer
  par nœud. Documenté comme choix.
- Pas de TLS entre app/PgBouncer/HAProxy/PostgreSQL — amélioration sécurité
  ultérieure.
