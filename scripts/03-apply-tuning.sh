#!/usr/bin/env bash
#
# pgquorum -- Phase 3: apply PostgreSQL tuning + enable pg_stat_statements.
#
# Parameters are set in Patroni's DYNAMIC configuration (stored in etcd) via
# the REST API, so they are versioned in the DCS and identical on every node.
# Reloadable params apply immediately; restart-required params (shared_buffers,
# shared_preload_libraries) are applied with a ROLLING restart: replicas first
# (no write impact), then the leader in place (brief write blip, no failover).
set -euo pipefail

STACK_PG="pgquorum"
SCOPE="pgquorum"
PT="patronictl -c /tmp/patroni/patroni.yml"

cid() { docker ps -q -f "name=${STACK_PG}_$1" | head -1; }

leader=""; replicas=()
for n in pg1 pg2 pg3; do
  c="$(cid "$n")"; [ -z "$c" ] && continue
  if docker exec "$c" sh -c 'curl -fsS -m3 localhost:8008/master >/dev/null 2>&1'; then
    leader="$n"
  else
    replicas+=("$n")
  fi
done
[ -z "${leader}" ] && { echo "ERROR: no leader"; exit 1; }
lc="$(cid "${leader}")"
echo "Leader=${leader}  Replicas=${replicas[*]}"

echo "== 1. PATCH dynamic config =="
docker exec -i "${lc}" sh -c \
  'curl -s -XPATCH -H "Content-Type: application/json" --data-binary @- http://localhost:8008/config' <<'JSON' | head -c 600
{"postgresql":{"parameters":{
  "shared_buffers":"256MB",
  "effective_cache_size":"768MB",
  "work_mem":"8MB",
  "maintenance_work_mem":"128MB",
  "random_page_cost":1.1,
  "checkpoint_completion_target":0.9,
  "max_wal_size":"2GB",
  "min_wal_size":"128MB",
  "shared_preload_libraries":"pg_stat_statements",
  "pg_stat_statements.track":"top",
  "pg_stat_statements.max":10000
}}}
JSON
echo; echo

echo "== 2. Rolling restart: replicas first =="
for r in "${replicas[@]}"; do
  echo "-- restart replica ${r}"
  docker exec "$(cid "${r}")" ${PT} restart "${SCOPE}" "${r}" --force
done

echo "== 3. Restart leader '${leader}' in place (keeps leadership, brief write blip) =="
docker exec "${lc}" ${PT} restart "${SCOPE}" "${leader}" --force

echo "== 4. State =="
docker exec "${lc}" ${PT} list
