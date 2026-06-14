# pgquorum -- Patroni + PostgreSQL 16 image.
# Patroni is the agent that manages the local PostgreSQL instance and drives
# leader election / failover through the etcd DCS.
FROM postgres:16

# Patroni + etcd v3 client support. Debian's system Python is externally
# managed (PEP 668), so install into a dedicated virtualenv.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 python3-venv gettext-base curl \
 && rm -rf /var/lib/apt/lists/* \
 && python3 -m venv /opt/patroni \
 && /opt/patroni/bin/pip install --no-cache-dir --upgrade pip \
 && /opt/patroni/bin/pip install --no-cache-dir "patroni[etcd3]" psycopg2-binary
ENV PATH="/opt/patroni/bin:${PATH}"

COPY patroni.yml.tmpl /etc/patroni/patroni.yml.tmpl
COPY entrypoint.sh /usr/local/bin/patroni-entrypoint.sh
RUN chmod +x /usr/local/bin/patroni-entrypoint.sh

# Patroni renders its config then runs PostgreSQL as the unprivileged
# postgres user (uid 999 in the base image).
USER postgres
ENTRYPOINT ["/usr/local/bin/patroni-entrypoint.sh"]
