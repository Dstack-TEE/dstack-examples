# Patroni + PostgreSQL 16 on Alpine. Small enough (~250MB) to pull
# fast on CVM boot; the official Spilo images are ~1GB.
#
# The entrypoint reads /run/instance/info.json (written by
# bootstrap-secrets) for ordinal + per-protocol ports, then renders
# /etc/patroni.yml and execs `patroni`.
FROM postgres:16-alpine

RUN apk add --no-cache python3 py3-pip py3-psycopg2 py3-yaml jq tini su-exec curl

# python-consul + python-etcd are optional; we only ship the consul DCS.
RUN pip install --no-cache-dir --break-system-packages \
      "patroni[consul]==4.0.4"

# Patroni needs a writeable home for sockets and pid files.
RUN mkdir -p /var/lib/patroni && chown postgres:postgres /var/lib/patroni

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
