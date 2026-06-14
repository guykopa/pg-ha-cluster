#!/usr/bin/env bash
#
# pgquorum -- Phase 0: bootstrap the local single-node Docker Swarm.
#
# Idempotent: safe to run several times. It initialises the swarm (if not
# already active), creates the three overlay networks used to segment
# traffic, and provisions a throwaway secret to validate the secret
# mechanism end to end.
#
# Dev note: this runs on a SINGLE-node swarm under WSL2 (no VMs). The same
# overlay networks and `docker secret` primitives behave identically on a
# real multi-node swarm, so nothing here is dev-only throwaway except the
# node count. See docs/phases/00-swarm-foundation/README.md.

set -euo pipefail

# --- Overlay networks --------------------------------------------------------
# net_data       : etcd <-> Patroni/PostgreSQL (replication, leader election)
# net_proxy      : HAProxy <-> PgBouncer <-> PostgreSQL, app-facing entrypoint
# net_monitoring : exporters <-> Prometheus, Promtail <-> Loki, ... <-> Grafana
NETWORKS=(net_data net_proxy net_monitoring)

DEMO_SECRET_NAME="pgquorum_bootstrap_check"

log() { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }

# --- 1. Initialise the swarm if needed --------------------------------------
state="$(docker info --format '{{.Swarm.LocalNodeState}}')"
if [ "$state" = "active" ]; then
  log "Swarm already active, skipping init."
else
  # First try a plain init: on Docker Desktop the daemon runs in its own VM
  # and picks its internal IP automatically (the host's eth0 IP is unknown to
  # it). On a real multi-interface host this fails with an "ambiguous address"
  # error, so we retry advertising the source IP of the default route.
  log "Initialising single-node swarm..."
  if ! docker swarm init >/dev/null 2>&1; then
    advertise_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')"
    log "Plain init failed; retrying with advertise-addr=${advertise_ip}..."
    docker swarm init --advertise-addr "${advertise_ip}"
  fi
fi

# --- 2. Create the overlay networks (attachable for ad-hoc dev testing) -----
for net in "${NETWORKS[@]}"; do
  if docker network inspect "${net}" >/dev/null 2>&1; then
    log "Network '${net}' already exists, skipping."
  else
    log "Creating overlay network '${net}'..."
    docker network create --driver overlay --attachable "${net}"
  fi
done

# --- 3. Provision a throwaway secret to validate the mechanism --------------
# Real secrets are injected later from ansible-vault-decrypted values; this
# one only proves `docker secret` works on this host.
if docker secret inspect "${DEMO_SECRET_NAME}" >/dev/null 2>&1; then
  log "Secret '${DEMO_SECRET_NAME}' already exists, skipping."
else
  log "Creating demo secret '${DEMO_SECRET_NAME}'..."
  printf 'phase0-secret-mechanism-ok' | docker secret create "${DEMO_SECRET_NAME}" - >/dev/null
fi

log "Done. Run scripts/00-verify-swarm.sh to validate the foundation."
