#!/usr/bin/env bash
#
# pgquorum -- Phase 0: validate the local Swarm foundation.
#
# Read-only checks. Exits non-zero if any expectation is not met, so it can
# double as a smoke test in CI later.

set -uo pipefail

NETWORKS=(net_data net_proxy net_monitoring)
DEMO_SECRET_NAME="pgquorum_bootstrap_check"

pass=0
fail=0
ok()   { printf '  \033[1;32mOK\033[0m   %s\n' "$*"; pass=$((pass+1)); }
nok()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }

echo "== Swarm =="
if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" = "active" ]; then
  ok "swarm is active"
else
  nok "swarm is not active (run scripts/00-bootstrap-swarm.sh)"
fi

echo "== Overlay networks =="
for net in "${NETWORKS[@]}"; do
  driver="$(docker network inspect "${net}" --format '{{.Driver}}' 2>/dev/null)"
  if [ "${driver}" = "overlay" ]; then
    ok "network '${net}' exists (driver=overlay)"
  else
    nok "network '${net}' missing or wrong driver (got '${driver:-none}')"
  fi
done

echo "== Secret =="
if docker secret inspect "${DEMO_SECRET_NAME}" >/dev/null 2>&1; then
  ok "secret '${DEMO_SECRET_NAME}' exists"
else
  nok "secret '${DEMO_SECRET_NAME}' missing"
fi

echo
printf 'Result: %d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
