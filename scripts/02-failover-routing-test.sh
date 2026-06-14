#!/usr/bin/env bash
#
# pgquorum -- Phase 2 validation: HAProxy follows the failover.
#
# Confirms that the write endpoint (HAProxy :5000) keeps reaching a primary
# after the leader is lost: kill the leader, and poll :5000 until it serves a
# (new) primary again -- HAProxy re-routes purely from Patroni health-checks,
# no manual reconfiguration.
set -uo pipefail

STACK_PG="pgquorum"
CRED_FILE="secrets/dev-credentials.env"
TIMEOUT="${TIMEOUT:-90}"
APP_PW="$(grep -E '^PG_APP_PASSWORD=' "${CRED_FILE}" 2>/dev/null | head -1 | cut -d= -f2-)"

# pg_is_in_recovery() through the HAProxy write endpoint.
write_recovery() {
  docker run --rm --network net_proxy -e PGPASSWORD="${APP_PW}" postgres:16 \
    psql -h haproxy -p 5000 -U app -d appdb -tAc 'SELECT pg_is_in_recovery()' \
    2>/dev/null | tr -d '[:space:]'
}

# server (host) currently backing the write endpoint
write_host() {
  docker run --rm --network net_proxy -e PGPASSWORD="${APP_PW}" postgres:16 \
    psql -h haproxy -p 5000 -U app -d appdb -tAc 'SELECT inet_server_addr()' \
    2>/dev/null | tr -d '[:space:]'
}

find_leader() {
  for n in pg1 pg2 pg3; do
    local cid; cid="$(docker ps -q -f "name=${STACK_PG}_${n}" | head -1)"
    [ -z "${cid}" ] && continue
    docker exec "${cid}" sh -c 'curl -fsS --max-time 3 http://localhost:8008/master >/dev/null 2>&1' \
      && { echo "${n}"; return 0; }
  done
  return 1
}

echo "=== Before ==="
old_leader="$(find_leader)" || { echo "no leader"; exit 1; }
echo "Leader: ${old_leader} | write endpoint primary? recovery=$(write_recovery) host=$(write_host)"

echo
echo "=== Killing leader '${old_leader}' (scale to 0) ==="
docker service scale -d "${STACK_PG}_${old_leader}=0" >/dev/null
t0="$(date +%s)"

echo "=== Polling HAProxy :5000 until a new primary is served ==="
served=""
while [ "$(( $(date +%s) - t0 ))" -lt "${TIMEOUT}" ]; do
  if [ "$(write_recovery)" = "f" ]; then
    nl="$(find_leader)"
    if [ -n "${nl}" ] && [ "${nl}" != "${old_leader}" ]; then served="${nl}"; break; fi
  fi
  sleep 2
done
t1="$(date +%s)"
[ -z "${served}" ] && { echo "FAIL: write endpoint never served a new primary within ${TIMEOUT}s"; exit 1; }
echo "New primary '${served}' reachable via :5000 after $(( t1 - t0 ))s (host=$(write_host))"

echo
echo "=== Restoring '${old_leader}' ==="
docker service scale -d "${STACK_PG}_${old_leader}=1" >/dev/null
echo "Done."
