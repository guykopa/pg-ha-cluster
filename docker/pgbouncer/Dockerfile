# pgquorum -- PgBouncer image (Phase 2).
FROM alpine:3.20

RUN apk add --no-cache pgbouncer \
 && (id pgbouncer >/dev/null 2>&1 || adduser -D -H pgbouncer)

COPY pgbouncer.ini /etc/pgbouncer/pgbouncer.ini
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
 && chown -R pgbouncer:pgbouncer /etc/pgbouncer

# PgBouncer refuses to run as root.
USER pgbouncer
EXPOSE 6432
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
