#!/usr/bin/env bash
#
# pgquorum -- Phase 5a: deploy the monitoring stack (metrics + alerting + Grafana).
#
# 1. Ensure the grafana admin secret and a `monitoring` DB role (pg_monitor).
# 2. Refresh the proxy stack so HAProxy exposes /metrics.
# 3. Deploy the monitoring stack (the postgres-exporter DSN password is
#    interpolated from the shell env, never committed).
set -euo pipefail

STACK_PG="pgquorum"
STACK_PROXY="pgquorum-proxy"
STACK_MON="pgquorum-monitoring"
CRED_FILE="secrets/dev-credentials.env"
mkdir -p "$(dirname "${CRED_FILE}")"

log() { printf '\033[1;34m[mon]\033[0m %s\n' "$*"; }

# --- grafana admin secret ---------------------------------------------------
if ! docker secret inspect grafana_admin_password >/dev/null 2>&1; then
  GF_PW="$(openssl rand -hex 12)"
  printf '%s' "${GF_PW}" | docker secret create grafana_admin_password - >/dev/null
  printf 'GRAFANA_ADMIN_PASSWORD=%s\n' "${GF_PW}" >> "${CRED_FILE}"
  log "Created secret grafana_admin_password (saved to ${CRED_FILE})."
else
  log "Secret grafana_admin_password already exists."
fi

# --- monitoring DB role (for postgres-exporter) -----------------------------
MONITORING_PW="$(grep -E '^MONITORING_PW=' "${CRED_FILE}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
if [ -z "${MONITORING_PW}" ]; then
  MONITORING_PW="$(openssl rand -hex 16)"
  printf 'MONITORING_PW=%s\n' "${MONITORING_PW}" >> "${CRED_FILE}"
fi
export MONITORING_PW

leader="$(for n in pg1 pg2 pg3; do c="$(docker ps -q -f name=${STACK_PG}_$n | head -1)"; \
  docker exec "$c" sh -c 'curl -fsS -m3 localhost:8008/master >/dev/null 2>&1' && { echo "$n"; break; }; done)"
lc="$(docker ps -q -f name=${STACK_PG}_${leader} | head -1)"
log "Provisioning 'monitoring' role on leader '${leader}'..."
docker exec -i "${lc}" psql -U postgres -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='monitoring') THEN
    CREATE ROLE monitoring LOGIN PASSWORD '${MONITORING_PW}';
  ELSE
    ALTER ROLE monitoring LOGIN PASSWORD '${MONITORING_PW}';
  END IF;
END
\$\$;
GRANT pg_monitor TO monitoring;
GRANT CONNECT ON DATABASE appdb TO monitoring;
SQL

# --- refresh proxy so HAProxy exposes /metrics ------------------------------
log "Refreshing proxy stack (HAProxy /metrics)..."
docker stack deploy -c swarm-stacks/proxy.yml "${STACK_PROXY}" >/dev/null

# --- deploy monitoring ------------------------------------------------------
log "Deploying monitoring stack..."
docker stack deploy -c swarm-stacks/monitoring.yml "${STACK_MON}"

log "Done. Prometheus :9090  Grafana :3000  Alertmanager :9093"
log "Validate with: bash scripts/05-verify-monitoring.sh"
