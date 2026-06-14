#!/usr/bin/env bash
#
# pgquorum -- Phase 3: performance report.
# Resets pg_stat_statements on the leader, runs a write and a read-only
# pgbench through PgBouncer, then prints the top statements by total time.
set -uo pipefail

CRED_FILE="secrets/dev-credentials.env"
APP_PW="$(grep -E '^PG_APP_PASSWORD=' "${CRED_FILE}" 2>/dev/null | head -1 | cut -d= -f2-)"
SCALE="${SCALE:-10}"; CLIENTS="${CLIENTS:-8}"; JOBS="${JOBS:-4}"
T_WRITE="${T_WRITE:-20}"; T_READ="${T_READ:-15}"

lc="$(for n in pg1 pg2 pg3; do c="$(docker ps -q -f name=pgquorum_$n | head -1)"; \
  docker exec "$c" sh -c 'curl -fsS -m3 localhost:8008/master >/dev/null 2>&1' && { echo "$c"; break; }; done)"

pgb() { docker run --rm --network net_proxy -e PGPASSWORD="${APP_PW}" postgres:16 \
          pgbench "$@" 2>&1 | grep -E 'tps|latency average'; }

echo "== Reset pg_stat_statements (leader) =="
docker exec "${lc}" psql -U postgres -d appdb -tAc "SELECT pg_stat_statements_reset() IS NOT NULL" >/dev/null && echo "reset done"

echo
echo "== pgbench WRITE (TPC-B, -c${CLIENTS} -j${JOBS} -T${T_WRITE}) via PgBouncer -> leader =="
pgb -c "${CLIENTS}" -j "${JOBS}" -T "${T_WRITE}" -h pgbouncer -p 6432 -U app appdb

echo
echo "== pgbench READ-ONLY (-S -c${CLIENTS} -j${JOBS} -T${T_READ}) via PgBouncer -> replicas =="
pgb -S -c "${CLIENTS}" -j "${JOBS}" -T "${T_READ}" -h pgbouncer -p 6432 -U app appdb_ro

echo
echo "== Top statements by total time (pg_stat_statements, leader) =="
docker exec "${lc}" psql -U postgres -d appdb -P pager=off -c "
SELECT calls,
       round(total_exec_time::numeric,1)               AS total_ms,
       round(mean_exec_time::numeric,3)                 AS mean_ms,
       round((100*total_exec_time/NULLIF(sum(total_exec_time) over (),0))::numeric,1) AS pct,
       left(regexp_replace(query,'\s+',' ','g'),52)     AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 8;"
