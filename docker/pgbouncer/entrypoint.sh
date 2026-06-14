#!/bin/sh
#
# pgquorum -- PgBouncer entrypoint.
# Renders userlist.txt from the Swarm secret (the auth_user credential),
# then runs PgBouncer.
set -eu

PASS="$(cat /run/secrets/pg_pgbouncer_password)"
printf '"pgbouncer" "%s"\n' "${PASS}" > /etc/pgbouncer/userlist.txt
chmod 600 /etc/pgbouncer/userlist.txt

exec pgbouncer /etc/pgbouncer/pgbouncer.ini
