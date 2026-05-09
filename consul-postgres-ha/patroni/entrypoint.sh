#!/bin/sh
# Render patroni.yml from /run/instance/info.json + env, then exec patroni.
#
# Postgres binds canonical 127.0.0.1:5432 on every worker (no per-ordinal
# arithmetic). Cross-peer access goes through the postgres Connect
# sidecar at 127.50.0.<peer>:21001 — Patroni doesn't see any of that;
# its primary_conninfo points at the local service VIP `postgres-master`,
# which the local Envoy proxies to whoever is the current leader.
#
# Stage-1 WORKAROUND: superuser + replication passwords come from
# Terraform-generated env (PATRONI_SUPERUSER_PW, PATRONI_REPLICATION_PW)
# broadcast identically to every worker. Stage-2 attestation will
# replace this with TEE-rooted material; see
# design/attestation-admission.md.

set -e

INFO=/run/instance/info.json

if [ ! -f "$INFO" ]; then
  echo "FATAL: $INFO not present — bootstrap-secrets did not run" >&2
  exit 1
fi

ROLE=$(jq -r '.role'    "$INFO")
ORD=$(jq  -r '.ordinal' "$INFO")
PEER_ID="${ROLE}-${ORD}"
CLUSTER="${CLUSTER_NAME:?CLUSTER_NAME required}"
SUPERUSER_PW="${PATRONI_SUPERUSER_PW:?PATRONI_SUPERUSER_PW required}"
REPL_PW="${PATRONI_REPLICATION_PW:?PATRONI_REPLICATION_PW required}"
UPSTREAMS_JSON="${UPSTREAMS_JSON:?UPSTREAMS_JSON required}"

# Service-VIP /etc/hosts entries (each container has its own /etc/hosts;
# loopback aliases on lo are shared via network_mode: host but name
# resolution is per-container). After this, `postgres-master:5432`
# resolves to the local Envoy upstream listener.
echo "$UPSTREAMS_JSON" | jq -r '.[] | "127.10.0.\(.vip)  \(.name)"' >> /etc/hosts

DATA_DIR=/var/lib/patroni/pgdata
mkdir -p "$DATA_DIR"
chown -R postgres:postgres "$DATA_DIR" /var/lib/patroni
chmod 700 "$DATA_DIR"

# Canonical ports — every worker binds the same numbers; cross-peer
# routing happens at peer-VIP / service-VIP layers above this.
PG_PORT=5432
REST_PORT=8008
CONSUL_HTTP=127.0.0.1:8500

# postgresql.connect_address: what other Patroni instances see when
# they query DCS for "where's the leader". They dial this; on the
# consumer's CVM, /etc/hosts maps postgres-master → 127.10.0.<vip>,
# and the local Envoy upstream listener proxies via mTLS to whoever
# is the current leader. So every instance can use the SAME constant
# string here — the consumer-side resolution does the right thing.
PG_CONNECT_ADDR="postgres-master:${PG_PORT}"

cat > /etc/patroni.yml <<EOF
scope: ${CLUSTER}
name: ${PEER_ID}

restapi:
  listen: 127.0.0.1:${REST_PORT}
  connect_address: 127.0.0.1:${REST_PORT}

consul:
  host: ${CONSUL_HTTP}
  register_service: true
  service_check_interval: 5s

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      parameters:
        max_connections: 100
        max_wal_senders: 10
        wal_keep_size: 256MB
        hot_standby: "on"

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - host replication replicator 127.0.0.1/32 md5
    - host all          all        127.0.0.1/32 md5
    # mesh-conn / Envoy land traffic on lo, so all replication / SQL
    # arrives from 127.0.0.1.

  users:
    admin:
      password: ${SUPERUSER_PW}
      options:
        - createrole
        - createdb

postgresql:
  listen: 127.0.0.1:${PG_PORT}
  connect_address: ${PG_CONNECT_ADDR}
  data_dir: ${DATA_DIR}
  bin_dir: /usr/local/bin
  pgpass: /var/lib/patroni/.pgpass
  authentication:
    superuser:
      username: postgres
      password: ${SUPERUSER_PW}
    replication:
      username: replicator
      password: ${REPL_PW}
  parameters:
    unix_socket_directories: /var/lib/patroni

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
EOF

echo "patroni: peer=${PEER_ID} listen=127.0.0.1:${PG_PORT} connect_address=${PG_CONNECT_ADDR} consul=${CONSUL_HTTP}"
exec su-exec postgres patroni /etc/patroni.yml
