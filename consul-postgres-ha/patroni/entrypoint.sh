#!/bin/sh
# Render patroni.yml from /run/instance/info.json + env, then exec patroni.
#
# Postgres binds canonical 127.0.0.1:5432 on every worker (no per-ordinal
# arithmetic). Cross-peer access goes through the postgres Connect
# sidecar at 127.50.0.<peer>:21001 — Patroni doesn't see any of that;
# its primary_conninfo points at the local service VIP `postgres-master`,
# which the local Envoy proxies to whoever is the current leader.
#
# WORKAROUND: superuser + replication passwords come from
# Terraform-generated env (PATRONI_SUPERUSER_PW, PATRONI_REPLICATION_PW)
# broadcast identically to every worker. Attestation-rooted admission
# will replace this with TEE-rooted material; see
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
SERVICES_JSON="${SERVICES_JSON:?SERVICES_JSON required}"

# Service-VIP /etc/hosts entries (each container has its own /etc/hosts;
# loopback aliases on lo are shared via network_mode: host but name
# resolution is per-container). After this, `postgres-master:5432`
# resolves to the local Envoy upstream listener.
echo "$SERVICES_JSON" | jq -r '.[] | "127.10.0.\(.vip)  \(.name)"' >> /etc/hosts

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

# Role watcher: mirror Patroni's current role into the postgres-sidecar
# registration's Tags. Lives here (not in the platform sidecar) because
# the role <-> tag mapping is Patroni-specific knowledge — the platform
# sidecar registers the proxy with no tags, and only Patroni knows when
# it has flipped master/replica.
#
# Service-resolver subset filters (`Service.Tags contains "master"`)
# apply to the SIDECAR registration, not Patroni's parent service. We
# re-PUT the sidecar via the local consul agent's HTTP API; the PUT is
# idempotent on (Name, ID), so it acts as an in-place tag update.
PEERS_JSON_FOR_ROLE="${PEERS_JSON:?PEERS_JSON required (for role-watcher to compute self vip)}"
SELF_VIP=$(echo "$PEERS_JSON_FOR_ROLE" | jq -r --arg id "$PEER_ID" '.[] | select(.id == $id) | .vip')
[ -n "$SELF_VIP" ] || { echo "FATAL: $PEER_ID not in PEERS_JSON" >&2; exit 1; }

# Same registration shape the platform sidecar emits in pattern B
# (standalone connect-proxy, parent=CLUSTER auto-registered by Patroni).
# We rebuild it here rather than relying on a shared file because the
# platform sidecar lives in a different container with its own /tmp;
# reconstructing from SERVICES_JSON + PEERS_JSON keeps this loop
# self-contained.
ROLE_BACKEND=$(
  echo "$SERVICES_JSON" \
    | jq -c --arg parent "$CLUSTER" '
        map(select(.parent == $parent)) | {
          sidecar_port: .[0].sidecar_port,
          port:         .[0].port,
          upstreams: [.[] | {
            DestinationName:  .name,
            LocalBindAddress: ("127.10.0." + (.vip|tostring)),
            LocalBindPort:    .port
          }]
        }
      '
)

if [ "$(echo "$ROLE_BACKEND" | jq -r '.sidecar_port // "null"')" = "null" ]; then
  echo "[role-watcher] no SERVICES_JSON entry with parent=$CLUSTER — skipping watcher"
else
  # Background subshell — tini reaps it when this script's process tree
  # tears down on container stop. We don't trap or `wait`: the original
  # design had this loop as a sibling background process in the platform
  # sidecar, and we preserve that lifecycle here.
  (
    PREV=""
    while true; do
      sleep 5
      PATRONI_ROLE=$(curl -fsS --max-time 2 http://127.0.0.1:${REST_PORT}/ 2>/dev/null \
                      | jq -r '.role // empty' 2>/dev/null)
      case "$PATRONI_ROLE" in
        master|primary)                       TAG="master"  ;;
        replica|standby_leader|sync_standby)  TAG="replica" ;;
        *)                                    continue ;;
      esac
      [ "$TAG" = "$PREV" ] && continue
      SPEC=$(jq -n \
        --arg id "${CLUSTER}-sidecar-${PEER_ID}" \
        --arg name "${CLUSTER}-sidecar-proxy" \
        --arg parent "$CLUSTER" \
        --arg vip "$SELF_VIP" \
        --arg tag "$TAG" \
        --argjson backend "$ROLE_BACKEND" '{
          Kind: "connect-proxy",
          ID: $id,
          Name: $name,
          Address: ("127.50.0." + $vip),
          Port: $backend.sidecar_port,
          Tags: [$tag],
          Proxy: {
            DestinationServiceName: $parent,
            LocalServiceAddress:    "127.0.0.1",
            LocalServicePort:       $backend.port,
            Upstreams:              $backend.upstreams
          }
        }')
      if printf '%s' "$SPEC" | curl -fsS -X PUT --data-binary @- \
                                http://${CONSUL_HTTP}/v1/agent/service/register; then
        echo "[role-watcher] ${CLUSTER}-sidecar tag: $PREV -> $TAG (patroni role=$PATRONI_ROLE)"
        PREV="$TAG"
      fi
    done
  ) &
fi

echo "patroni: peer=${PEER_ID} listen=127.0.0.1:${PG_PORT} connect_address=${PG_CONNECT_ADDR} consul=${CONSUL_HTTP}"
exec su-exec postgres patroni /etc/patroni.yml
