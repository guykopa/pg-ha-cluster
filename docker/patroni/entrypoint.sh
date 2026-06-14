#!/usr/bin/env bash
#
# pgquorum -- Patroni container entrypoint.
# Loads secrets from Swarm secret files into the environment, renders the
# Patroni config from its template, then hands off to Patroni.
set -euo pipefail

# Export a value from a Swarm secret file (mounted at /run/secrets/<name>)
# into the given environment variable, if the file exists.
load_secret() {
  local var="$1" file="$2"
  if [ -f "${file}" ]; then
    export "${var}"="$(cat "${file}")"
  fi
}

load_secret PATRONI_SUPERUSER_PASSWORD   /run/secrets/pg_superuser_password
load_secret PATRONI_REPLICATION_PASSWORD /run/secrets/pg_replication_password

: "${PATRONI_SCOPE:?PATRONI_SCOPE must be set}"
: "${PATRONI_NAME:?PATRONI_NAME must be set}"
: "${PATRONI_SUPERUSER_PASSWORD:?superuser password secret missing}"
: "${PATRONI_REPLICATION_PASSWORD:?replication password secret missing}"

# Render the config; envsubst substitutes only the ${VAR} placeholders.
mkdir -p /tmp/patroni
envsubst < /etc/patroni/patroni.yml.tmpl > /tmp/patroni/patroni.yml

exec patroni /tmp/patroni/patroni.yml
