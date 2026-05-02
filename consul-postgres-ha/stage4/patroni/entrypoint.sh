#!/bin/sh
# Render patroni.yml from /run/instance/info.json + env, then exec patroni.
#
# All Patroni instances in the cluster:
#   - share the same `scope` (CLUSTER_NAME) — that's what makes them a
#     single Patroni cluster
#   - have a unique `name` (the peer ID, e.g. worker-1)
#   - register their postgres + REST addresses against 127.0.0.1 — the
#     mesh-conn UDP forwarder maps each peer's per-ordinal ports to the
#     real peer's listener, so 127.0.0.1:<peer_postgres_port> from any
#     peer reaches that peer's postgres.
#
# Replication user/password is derived deterministically from the
# cluster-wide `replication` secret written by bootstrap-secrets.
# Same trick for the superuser.

set -e

INFO=/run/instance/info.json
SECRETS=/run/secrets

if [ ! -f "$INFO" ]; then
  echo "FATAL: $INFO not present — bootstrap-secrets did not run" >&2
  exit 1
fi

ROLE=$(jq -r '.role'    "$INFO")
ORD=$(jq  -r '.ordinal' "$INFO")
PEER_ID="${ROLE}-${ORD}"
PG_PORT=$(jq      -r '.ports.postgres'     "$INFO")
REST_PORT=$(jq    -r '.ports.patroni_rest' "$INFO")
CONSUL_PORT=$(jq  -r '.ports.http_api'     "$INFO")
CLUSTER="${CLUSTER_NAME:?CLUSTER_NAME required}"

# Read or default the credentials. bootstrap-secrets writes
# /run/secrets/{patroni-superuser,patroni-replication} as raw 32-byte
# hex strings (deterministic per-cluster via getKey()).
SUPERUSER_PW=$(cat "${SECRETS}/patroni-superuser"  2>/dev/null || echo dev-pg-pass)
REPL_PW=$(cat      "${SECRETS}/patroni-replication" 2>/dev/null || echo dev-repl-pass)

DATA_DIR=/var/lib/patroni/pgdata
mkdir -p "$DATA_DIR"
chown -R postgres:postgres "$DATA_DIR" /var/lib/patroni
chmod 700 "$DATA_DIR"

cat > /etc/patroni.yml <<EOF
scope: ${CLUSTER}
name: ${PEER_ID}

restapi:
  listen: 127.0.0.1:${REST_PORT}
  connect_address: 127.0.0.1:${REST_PORT}

consul:
  host: 127.0.0.1:${CONSUL_PORT}
  register_service: true
  service_check_interval: 10s

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
    # mesh-conn lands traffic on lo, so all replication / SQL is from 127.0.0.1.

  users:
    admin:
      password: ${SUPERUSER_PW}
      options:
        - createrole
        - createdb

postgresql:
  listen: 127.0.0.1:${PG_PORT}
  connect_address: 127.0.0.1:${PG_PORT}
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

echo "patroni: peer=${PEER_ID} pg=${PG_PORT} rest=${REST_PORT} consul=127.0.0.1:${CONSUL_PORT}"
exec su-exec postgres patroni /etc/patroni.yml
