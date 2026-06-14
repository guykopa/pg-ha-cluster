#!/usr/bin/env bash
#
# pgquorum -- Phase 5a: validate the monitoring stack.
# Checks that every Prometheus scrape job has all its targets UP, and that
# Grafana answers. Uses the published localhost ports.
set -uo pipefail

pass=0; fail=0
ok()  { printf '  \033[1;32mOK\033[0m   %s\n' "$*"; pass=$((pass+1)); }
nok() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }

echo "== Prometheus targets =="
targets="$(curl -s http://localhost:9090/api/v1/targets)"
if [ -z "${targets}" ]; then
  nok "Prometheus API unreachable on :9090"
else
  # Per job: count up vs total active targets.
  echo "${targets}" | python3 -c '
import sys, json, collections
d = json.load(sys.stdin)["data"]["activeTargets"]
agg = collections.defaultdict(lambda: [0,0])
for t in d:
    job = t["labels"]["job"]
    agg[job][1] += 1
    if t["health"] == "up": agg[job][0] += 1
for job in sorted(agg):
    up, tot = agg[job]
    print(f"{job} {up} {tot}")
' | while read -r job up tot; do
    if [ "${up}" = "${tot}" ] && [ "${tot}" -gt 0 ]; then
      printf "  \033[1;32mOK\033[0m   job %-10s %s/%s up\n" "${job}" "${up}" "${tot}"
    else
      printf "  \033[1;31mFAIL\033[0m job %-10s %s/%s up\n" "${job}" "${up}" "${tot}"
    fi
  done
fi

echo "== Endpoints =="
curl -fsS -o /dev/null http://localhost:9090/-/healthy 2>/dev/null && ok "Prometheus healthy" || nok "Prometheus unhealthy"
curl -fsS -o /dev/null http://localhost:9093/-/healthy 2>/dev/null && ok "Alertmanager healthy" || nok "Alertmanager unhealthy"
curl -fsS -o /dev/null http://localhost:3000/api/health 2>/dev/null && ok "Grafana healthy" || nok "Grafana unhealthy"

echo
echo "(targets détaillés ci-dessus ; le résumat OK/FAIL des jobs fait foi)"
