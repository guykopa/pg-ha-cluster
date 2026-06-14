#!/usr/bin/env bash
#
# pgquorum -- Phase 1: validate the PostgreSQL HA cluster.
# Read-only checks: etcd quorum healthy, and exactly one Patroni leader with
# two replicas. Exits non-zero on any failure (CI-friendly).
set -uo pipefail

STACK="pgquorum"
pass=0; fail=0
ok()  { printf '  \033[1;32mOK\033[0m   %s\n' "$*"; pass=$((pass+1)); }
nok() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }

echo "== etcd =="
ec="$(docker ps -q -f "name=${STACK}_etcd1" | head -1)"
if [ -n "${ec}" ] && docker exec "${ec}" etcdctl \
     --endpoints=http://etcd1:2379,http://etcd2:2379,http://etcd3:2379 \
     endpoint health >/dev/null 2>&1; then
  ok "3-member etcd cluster healthy (quorum)"
else
  nok "etcd cluster not healthy"
fi

echo "== Patroni roles =="
pc="$(docker ps -q -f "name=${STACK}_pg1" | head -1)"
roles="$(docker exec "${pc}" sh -c 'curl -s http://localhost:8008/cluster | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(m[\"role\"]==\"leader\" for m in d[\"members\"]), sum(m[\"role\"]==\"replica\" for m in d[\"members\"]))"' 2>/dev/null)"
leaders="${roles% *}"; replicas="${roles#* }"
[ "${leaders:-0}" = "1" ] && ok "exactly 1 leader" || nok "expected 1 leader, got ${leaders:-0}"
[ "${replicas:-0}" = "2" ] && ok "exactly 2 replicas" || nok "expected 2 replicas, got ${replicas:-0}"

echo
printf 'Result: %d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
