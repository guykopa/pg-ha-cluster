#!/usr/bin/env bash
#
# pgquorum -- Phase 2: validate HAProxy routing and PgBouncer pooling.
#
# Uses a throwaway psql client attached to net_proxy. Checks that the write
# path lands on the primary (pg_is_in_recovery = false) and the read path on a
# replica (true), both directly via HAProxy and through PgBouncer.
set -uo pipefail

CRED_FILE="secrets/dev-credentials.env"
APP_PW="$(grep -E '^PG_APP_PASSWORD=' "${CRED_FILE}" 2>/dev/null | head -1 | cut -d= -f2-)"
[ -z "${APP_PW}" ] && { echo "ERROR: PG_APP_PASSWORD not found in ${CRED_FILE}"; exit 1; }

pass=0; fail=0
ok()  { printf '  \033[1;32mOK\033[0m   %s\n' "$*"; pass=$((pass+1)); }
nok() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }

# Run a query as `app` through host:port/db using a one-off psql container.
q() {  # host port db sql
  docker run --rm --network net_proxy -e PGPASSWORD="${APP_PW}" postgres:16 \
    psql -h "$1" -p "$2" -U app -d "$3" -tAc "$4" 2>/dev/null | tr -d '[:space:]'
}

echo "== HAProxy (direct) =="
r="$(q haproxy 5000 appdb 'SELECT pg_is_in_recovery()')"
[ "${r}" = "f" ] && ok "write :5000 -> primary (pg_is_in_recovery=f)" || nok "write :5000 routing, got '${r}'"
r="$(q haproxy 5001 appdb 'SELECT pg_is_in_recovery()')"
[ "${r}" = "t" ] && ok "read :5001 -> replica (pg_is_in_recovery=t)" || nok "read :5001 routing, got '${r}'"

echo "== PgBouncer (pooled) =="
r="$(q pgbouncer 6432 appdb 'SELECT pg_is_in_recovery()')"
[ "${r}" = "f" ] && ok "appdb -> primary" || nok "appdb routing, got '${r}'"
r="$(q pgbouncer 6432 appdb_ro 'SELECT pg_is_in_recovery()')"
[ "${r}" = "t" ] && ok "appdb_ro -> replica" || nok "appdb_ro routing, got '${r}'"

echo "== Write works through the pool =="
q pgbouncer 6432 appdb 'CREATE TABLE IF NOT EXISTS smoke(id int)' >/dev/null
q pgbouncer 6432 appdb 'TRUNCATE smoke'                          >/dev/null
q pgbouncer 6432 appdb 'INSERT INTO smoke VALUES (42)'           >/dev/null
w="$(q pgbouncer 6432 appdb 'SELECT id FROM smoke')"
[ "${w}" = "42" ] && ok "INSERT via appdb readable back (id=42)" || nok "write via pool, got '${w}'"
q pgbouncer 6432 appdb 'DROP TABLE IF EXISTS smoke' >/dev/null

echo
printf 'Result: %d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
