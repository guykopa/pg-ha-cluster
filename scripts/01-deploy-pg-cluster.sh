#!/usr/bin/env bash
#
# pgquorum -- Phase 1: deploy the PostgreSQL HA cluster (etcd + Patroni).
#
# Ensures the required Swarm secrets exist (generating random values on first
# run), then deploys the stack. Generated dev credentials are written to a
# git-ignored file so they can be retrieved locally -- they are never
# committed and never appear in the stack file.
set -euo pipefail

STACK="pgquorum"
STACK_FILE="swarm-stacks/pg-cluster.yml"
CRED_FILE="secrets/dev-credentials.env"

# secret name -> env var recorded in the dev credentials file
declare -A SECRETS=(
  [pg_superuser_password]=PG_SUPERUSER_PASSWORD
  [pg_replication_password]=PG_REPLICATION_PASSWORD
)

log() { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }

mkdir -p "$(dirname "${CRED_FILE}")"

for secret in "${!SECRETS[@]}"; do
  if docker secret inspect "${secret}" >/dev/null 2>&1; then
    log "Secret '${secret}' already exists, skipping."
  else
    value="$(openssl rand -hex 16)"
    printf '%s' "${value}" | docker secret create "${secret}" - >/dev/null
    printf '%s=%s\n' "${SECRETS[$secret]}" "${value}" >> "${CRED_FILE}"
    log "Created secret '${secret}' (value saved to ${CRED_FILE})."
  fi
done

# Pre-pull etcd to avoid a slow first converge (image pull also sidesteps the
# BuildKit credential-helper issue seen under WSL/Docker Desktop).
log "Ensuring etcd image is present..."
docker pull quay.io/coreos/etcd:v3.5.16 >/dev/null

log "Deploying stack '${STACK}'..."
docker stack deploy -c "${STACK_FILE}" "${STACK}"

log "Done. Watch convergence with: docker stack services ${STACK}"
log "Validate with: bash scripts/01-verify-pg-cluster.sh"
