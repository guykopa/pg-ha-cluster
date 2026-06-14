#!/usr/bin/env bash
#
# pgquorum -- demo: measure the write-availability gap during a failover.
#
# A probe writes to the cluster through the HAProxy write endpoint (:5000)
# several times per second, logging OK/FAIL with timestamps. Mid-run the
# leader is taken down (scale=0); the outage window is computed from the
# timestamps (first FAIL -> first OK after), i.e. the time writes are
# unavailable while a replica is promoted and HAProxy re-routes.
set -uo pipefail

STACK_PG="pgquorum"
CRED_FILE="secrets/dev-credentials.env"
APP_PW="$(grep -E '^PG_APP_PASSWORD=' "${CRED_FILE}" 2>/dev/null | head -1 | cut -d= -f2-)"
PROBE_LOG="$(mktemp)"
DURATION=45     # total probe seconds
KILL_AT=10      # trigger failover this many seconds into the probe

# Probe table (written via the write path -> leader).
docker run --rm --network net_proxy -e PGPASSWORD="${APP_PW}" postgres:16 \
  psql -h haproxy -p 5000 -U app -d appdb -tAc \
  'CREATE TABLE IF NOT EXISTS failover_probe(id bigserial primary key, ts timestamptz default clock_timestamp())' >/dev/null

echo "[demo] starting probe (${DURATION}s, ~3 writes/s via HAProxy :5000)..."
docker run --rm --network net_proxy -e PGPASSWORD="${APP_PW}" -e PGCONNECT_TIMEOUT=3 postgres:16 \
  bash -c '
    end=$(( $(date +%s) + '"${DURATION}"' ))
    while [ "$(date +%s)" -lt "$end" ]; do
      t="$(date +%s.%N)"
      if psql -h haproxy -p 5000 -U app -d appdb -tAc "INSERT INTO failover_probe DEFAULT VALUES" >/dev/null 2>&1; then
        echo "$t OK"
      else
        echo "$t FAIL"
      fi
      sleep 0.3
    done
  ' > "${PROBE_LOG}" 2>&1 &
PROBE_PID=$!

sleep "${KILL_AT}"
leader="$(for n in pg1 pg2 pg3; do c="$(docker ps -q -f name=${STACK_PG}_$n | head -1)"; docker exec "$c" sh -c 'curl -fsS -m3 localhost:8008/master >/dev/null 2>&1' && { echo "$n"; break; }; done)"
echo "[demo] t+${KILL_AT}s: killing leader '${leader}' (scale=0)"
docker service scale -d "${STACK_PG}_${leader}=0" >/dev/null

wait "${PROBE_PID}"
echo "[demo] probe finished; restoring '${leader}'"
docker service scale -d "${STACK_PG}_${leader}=1" >/dev/null

echo
echo "=== Timeline (state transitions) ==="
awk '
  NR==1 { start=$1 }
  $2!=prev { printf "  t+%5.1fs  -> %s\n", $1-start, $2; prev=$2 }
  $2=="FAIL" && !ff { ff=$1 }
  $2=="OK" && ff && !rec { rec=$1 }
  { tot[$2]++ }
  END {
    printf "\nTotals: %d OK, %d FAIL\n", tot["OK"], tot["FAIL"]
    if (ff && rec) printf "Write outage window: %.1fs (first FAIL -> first OK after)\n", rec-ff
    else if (ff) printf "Still failing at end of probe.\n"
    else print "No failures observed."
  }
' "${PROBE_LOG}"
rm -f "${PROBE_LOG}"
