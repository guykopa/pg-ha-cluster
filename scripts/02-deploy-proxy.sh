#!/usr/bin/env bash
#
# pgquorum -- Phase 2: deploy HAProxy + PgBouncer and provision DB roles.
#
# 1. Ensure the app/pgbouncer Swarm secrets exist.
# 2. On the current leader, create the `app` and `pgbouncer` roles, the
#    `appdb` database, and the SECURITY DEFINER auth lookup function used by
#    PgBouncer's auth_query (idempotent).
# 3. Deploy the proxy stack.
set -euo pipefail

STACK_PG="pgquorum"
STACK_PROXY="pgquorum-proxy"
STACK_FILE="swarm-stacks/proxy.yml"
CRED_FILE="secrets/dev-credentials.env"

declare -A SECRETS=(
  [pg_app_password]=PG_APP_PASSWORD
  [pg_pgbouncer_password]=PG_PGBOUNCER_PASSWORD
)

log() { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
mkdir -p "$(dirname "${CRED_FILE}")"

# --- 1. Secrets -------------------------------------------------------------
declare -A VAL
for s in "${!SECRETS[@]}"; do
  if docker secret inspect "${s}" >/dev/null 2>&1; then
    VAL[$s]="$(grep -E "^${SECRETS[$s]}=" "${CRED_FILE}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    log "Secret '${s}' already exists."
    [ -z "${VAL[$s]}" ] && log "  WARN: value not found in ${CRED_FILE}; DB role password may be out of sync."
  else
    VAL[$s]="$(openssl rand -hex 16)"
    printf '%s' "${VAL[$s]}" | docker secret create "${s}" - >/dev/null
    printf '%s=%s\n' "${SECRETS[$s]}" "${VAL[$s]}" >> "${CRED_FILE}"
    log "Created secret '${s}' (value saved to ${CRED_FILE})."
  fi
done

# --- 2. Provision DB roles / database / auth function -----------------------
find_leader() {
  for n in pg1 pg2 pg3; do
    local cid; cid="$(docker ps -q -f "name=${STACK_PG}_${n}" | head -1)"
    [ -z "${cid}" ] && continue
    # -f makes curl fail on HTTP 503 (Patroni answers 200 only on the leader).
    if docker exec "${cid}" sh -c 'curl -fsS --max-time 3 http://localhost:8008/master >/dev/null 2>&1'; then
      echo "${n}"; return 0
    fi
  done
  return 1
}

leader="$(find_leader)" || { echo "ERROR: no leader found"; exit 1; }
lc="$(docker ps -q -f "name=${STACK_PG}_${leader}" | head -1)"
log "Provisioning roles/db on leader '${leader}'..."

docker exec -i "${lc}" psql -U postgres -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='app') THEN
    CREATE ROLE app LOGIN PASSWORD '${VAL[pg_app_password]}';
  ELSE
    ALTER ROLE app LOGIN PASSWORD '${VAL[pg_app_password]}';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='pgbouncer') THEN
    CREATE ROLE pgbouncer LOGIN PASSWORD '${VAL[pg_pgbouncer_password]}';
  ELSE
    ALTER ROLE pgbouncer LOGIN PASSWORD '${VAL[pg_pgbouncer_password]}';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE appdb OWNER app'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='appdb')\gexec

\c appdb
-- Auth lookup for PgBouncer auth_query. SECURITY DEFINER so the unprivileged
-- pgbouncer role can read password verifiers without direct pg_shadow access.
CREATE OR REPLACE FUNCTION public.user_lookup(in i_username text, out uname text, out phash text)
RETURNS record AS \$\$
  SELECT usename, passwd FROM pg_catalog.pg_shadow WHERE usename = i_username;
\$\$ LANGUAGE sql SECURITY DEFINER;
REVOKE ALL ON FUNCTION public.user_lookup(text) FROM public;
GRANT EXECUTE ON FUNCTION public.user_lookup(text) TO pgbouncer;
SQL

# --- 3. Deploy --------------------------------------------------------------
log "Deploying stack '${STACK_PROXY}'..."
docker stack deploy -c "${STACK_FILE}" "${STACK_PROXY}"

log "Done. Validate with: bash scripts/02-verify-proxy.sh"
