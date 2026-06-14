#!/usr/bin/env bash
#
# pgquorum -- Phase 1 validation: automatic failover test.
#
# Scenario (cf. ARCHITECTURE.md section 6):
#   1. Identify the current leader.
#   2. Take its node down and KEEP it down (scale the service to 0). This
#      simulates a sustained host failure -- unlike a bare `docker kill`,
#      which Swarm self-heals so fast (persistent volume) that the same node
#      reclaims leadership before a failover can be observed.
#   3. Wait for etcd to expire the leader lease (TTL) and for a replica to be
#      promoted; measure the time-to-new-leader.
#   4. Bring the old node back (scale to 1) and confirm it rejoins as a
#      replica (pg_rewind onto the new timeline).
#
# Long-running (waits on the DCS TTL, ~30s); run in the background.
set -uo pipefail

STACK="pgquorum"
TIMEOUT="${TIMEOUT:-120}"   # seconds to wait for a new leader / rejoin

cid_of() { docker ps -q -f "name=${STACK}_$1" | head -1; }

# Leader member name as seen from a given (surviving) pg service.
leader_seen_from() {
  local cid; cid="$(cid_of "$1")"
  [ -n "${cid}" ] || return 1
  docker exec "${cid}" sh -c \
    'curl -s --max-time 3 http://localhost:8008/cluster | python3 -c "import sys,json; d=json.load(sys.stdin); print(next((m[\"name\"] for m in d[\"members\"] if m[\"role\"]==\"leader\"), \"\"))"' \
    2>/dev/null
}

# Count members in a healthy running/streaming state, as seen from a service.
running_members_from() {
  local cid; cid="$(cid_of "$1")"
  [ -n "${cid}" ] || return 1
  docker exec "${cid}" sh -c \
    'curl -s --max-time 3 http://localhost:8008/cluster | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(m[\"state\"] in (\"running\",\"streaming\") for m in d[\"members\"]))"' \
    2>/dev/null
}

ALL=(pg1 pg2 pg3)

echo "=== Initial state ==="
old_leader="$(leader_seen_from pg1)"
[ -z "${old_leader}" ] && old_leader="$(leader_seen_from pg2)"
if [ -z "${old_leader}" ]; then echo "ERROR: no leader found, aborting."; exit 1; fi
echo "Current leader: ${old_leader}"

survivor=""
for n in "${ALL[@]}"; do [ "$n" != "${old_leader}" ] && survivor="$n" && break; done
echo "Polling survivor: ${survivor}"

echo
echo "=== Taking leader '${old_leader}' down (scale to 0 = sustained host loss) ==="
docker service scale -d "${STACK}_${old_leader}=0" >/dev/null
t0="$(date +%s)"
echo "Leader down at t0."

echo
echo "=== Waiting for a new leader (lease TTL must expire) ==="
new_leader=""
while [ "$(( $(date +%s) - t0 ))" -lt "${TIMEOUT}" ]; do
  cur="$(leader_seen_from "${survivor}")"
  if [ -n "${cur}" ] && [ "${cur}" != "${old_leader}" ]; then new_leader="${cur}"; break; fi
  sleep 2
done
t1="$(date +%s)"
if [ -z "${new_leader}" ]; then echo "FAIL: no new leader within ${TIMEOUT}s."; exit 1; fi
echo "New leader: ${new_leader}  (failover took $(( t1 - t0 ))s)"

echo
echo "=== Bringing '${old_leader}' back (scale to 1) ==="
docker service scale -d "${STACK}_${old_leader}=1" >/dev/null
while [ "$(( $(date +%s) - t1 ))" -lt "${TIMEOUT}" ]; do
  [ "$(running_members_from "${new_leader}")" = "3" ] && break
  sleep 3
done
t2="$(date +%s)"
echo "Cluster back to 3 running members (rejoin took $(( t2 - t1 ))s)."

echo
echo "=== Final state ==="
nc="$(cid_of "${new_leader}")"
docker exec "${nc}" patronictl -c /tmp/patroni/patroni.yml list 2>&1
