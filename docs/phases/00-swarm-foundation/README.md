# Phase 0 — Socle Docker Swarm

> Statut : **fait ✅**
> Pré-requis des phases suivantes (etcd/Patroni, proxy, monitoring).

## Objectifs

Poser le socle d'orchestration sur lequel toutes les stacks seront déployées :

1. Un **Swarm actif** (mono-nœud en dev, cf. note ci-dessous).
2. Les **trois réseaux overlay** qui segmentent les flux  :
   - `net_data` — etcd ↔ Patroni/PostgreSQL (réplication, élection) ;
   - `net_proxy` — HAProxy ↔ PgBouncer ↔ PostgreSQL (entrée applicative) ;
   - `net_monitoring` — exporters ↔ Prometheus, Promtail ↔ Loki, … ↔ Grafana.
3. La validation du mécanisme **`docker secret`** (secret jetable de test).

## Environnement de dev (rappel)

En local (WSL2, sans VM), le Swarm est **mono-nœud** et tout tourne en
conteneurs. Les primitives utilisées ici (réseaux overlay, secrets, `docker
stack deploy`) sont **identiques** à un Swarm 3 nœuds — seul le nombre de
nœuds change.

## Commandes

```bash
# Initialiser le socle (idempotent : ré-exécutable sans effet de bord)
bash scripts/00-bootstrap-swarm.sh

# Valider le socle (read-only ; sort en erreur si une attente n'est pas tenue)
bash scripts/00-verify-swarm.sh
```

Inspection manuelle utile :

```bash
docker node ls                 # le nœud manager (Leader) doit être Ready/Active
docker network ls | grep net_  # les 3 réseaux overlay
docker secret ls               # le secret de test pgquorum_bootstrap_check
```

## Test de validation

`scripts/00-verify-swarm.sh` doit afficher **`0 failed`** :

- Swarm `active` ;
- `net_data`, `net_proxy`, `net_monitoring` présents avec `driver=overlay` ;
- secret `pgquorum_bootstrap_check` présent.

## Problèmes rencontrés

- **`docker swarm init --advertise-addr <IP eth0>` échoue sous Docker Desktop.**
  Le daemon ne tourne pas dans cette distro WSL2 mais dans la VM `docker-desktop` :
  l'IP `eth0` de la distro (172.29.x.x) lui est inconnue → erreur
  *« address to advertise is not recognized as a system address »*. De plus,
  WSL2 épingle une adresse `scope global` sur `lo` (10.255.255.254), ce qui
  piégeait la détection naïve « première IP globale ».
  **Correctif** : tenter d'abord un `docker swarm init` **sans** `--advertise-addr`
  (Docker Desktop choisit son IP interne, ex. 192.168.65.3) ; ne basculer sur
  l'IP de la route par défaut qu'en cas d'échec (cible multi-nœuds sur vrai hôte).
- Conséquence visible : `docker node ls` affiche le nœud `docker-desktop`
  (et non le hostname WSL2), confirmant que le Swarm vit côté Docker Desktop.

## Nettoyage (optionnel)

```bash
docker secret rm pgquorum_bootstrap_check
docker network rm net_data net_proxy net_monitoring
docker swarm leave --force      # détruit le swarm mono-nœud
```
