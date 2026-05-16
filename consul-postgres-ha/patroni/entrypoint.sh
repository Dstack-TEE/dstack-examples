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
CONSUL_TOKEN=""
CONSUL_TOKEN_YAML=""
if [ "${ADMISSION_BROKER_ENABLE:-}" = "1" ]; then
  CONSUL_TOKEN_FILE="/run/instance/consul-token-${CLUSTER}"
  echo "patroni: waiting for attestation-issued Consul token at ${CONSUL_TOKEN_FILE}"
  until [ -s "$CONSUL_TOKEN_FILE" ]; do
    sleep 1
  done
  CONSUL_TOKEN=$(tr -d '\r\n' < "$CONSUL_TOKEN_FILE")
  [ -n "$CONSUL_TOKEN" ] || { echo "FATAL: empty Consul token in ${CONSUL_TOKEN_FILE}" >&2; exit 1; }
  CONSUL_TOKEN_YAML="  token: ${CONSUL_TOKEN}"
fi

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
${CONSUL_TOKEN_YAML}
  # Patroni's native register_service is set to false because the
  # platform sidecar owns the parent service registration (Address,
  # Port, check). The role-watcher loop below polls Patroni's REST API
  # and re-PUTs the parent registration with tags ["master"] or
  # ["replica"] so service-resolver subset filters match. We do this
  # because Patroni deregisters the service every loop iteration while
  # role=uninitialized (the entire pre-bootstrap window on a
  # replica), which wipes the registration our connect-proxy depends
  # on for proxycfg state. With register_service:false Patroni stays
  # out of the agent's service catalog and just uses Consul as DCS.
  register_service: false

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

# Role-watcher: poll Patroni's REST API and re-PUT the parent service
# registration `${CLUSTER}-${PEER_ID}` with role-aware tags. Consul's
# /v1/agent/service/register is a complete replace, so each PUT must
# carry the full spec — same shape the platform sidecar pre-registers,
# including the inline `Connect.SidecarService` that links the proxy
# to this parent. Without that field Consul doesn't return the proxy
# as a Connect endpoint for the parent and the discovery chain
# resolves to zero hosts.
#
# The subset filters in the service-resolver
# (`Service.Tags contains "master"` / "replica") match on the parent's
# tags, so flipping `$TAG` here is what makes `postgres-master:5432`
# follow the current leader live.
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

PEERS_JSON_FOR_ROLE="${PEERS_JSON:?PEERS_JSON required (role-watcher needs SELF_VIP)}"
SELF_VIP=$(echo "$PEERS_JSON_FOR_ROLE" | jq -r --arg id "$PEER_ID" '.[] | select(.id == $id) | .vip')
[ -n "$SELF_VIP" ] || { echo "FATAL: $PEER_ID not in PEERS_JSON" >&2; exit 1; }

if [ "$(echo "$ROLE_BACKEND" | jq -r '.sidecar_port // "null"')" = "null" ]; then
  echo "[role-watcher] no SERVICES_JSON entry with parent=$CLUSTER — skipping watcher"
else
  (
    echo "[role-watcher] starting (service_id=${CLUSTER}-${PEER_ID}, rest=127.0.0.1:${REST_PORT})"
    PREV=""
    while true; do
      sleep 5
      # `/` returns 503 on non-leaders (libpq's idiomatic way to advertise
      # role to load balancers); `/patroni` is 200 on every node and
      # carries the same JSON.
      PATRONI_ROLE=$(curl -fsS --max-time 2 "http://127.0.0.1:${REST_PORT}/patroni" 2>/dev/null \
                      | jq -r '.role // empty' 2>/dev/null)
      case "$PATRONI_ROLE" in
        master|primary)                       TAG="master"  ;;
        replica|standby_leader|sync_standby)  TAG="replica" ;;
        *)                                    continue ;;
      esac
      [ "$TAG" = "$PREV" ] && continue
      SPEC=$(jq -n \
        --arg name "$CLUSTER" \
        --arg id "${CLUSTER}-${PEER_ID}" \
        --arg tag "$TAG" \
        --arg vip "$SELF_VIP" \
        --argjson backend "$ROLE_BACKEND" \
        --argjson port "$PG_PORT" '{
          Name: $name,
          ID: $id,
          Address: "127.0.0.1",
          Port: $port,
          Tags: [$tag],
          Check: {
            TCP: ("127.0.0.1:" + ($port|tostring)),
            Interval: "5s",
            Timeout: "2s",
            DeregisterCriticalServiceAfter: "1m"
          },
          Connect: {
            SidecarService: {
              Address: ("127.50.0." + $vip),
              Port: $backend.sidecar_port,
              Proxy: {
                LocalServiceAddress: "127.0.0.1",
                LocalServicePort:    $backend.port,
                Upstreams:           $backend.upstreams
              }
            }
          }
        }')
      if [ -n "$CONSUL_TOKEN" ]; then
        REGISTERED=$(
          printf '%s' "$SPEC" | curl -fsS -H "X-Consul-Token: ${CONSUL_TOKEN}" -X PUT --data-binary @- \
            "http://${CONSUL_HTTP}/v1/agent/service/register" >/dev/null && echo yes || echo no
        )
      else
        REGISTERED=$(
          printf '%s' "$SPEC" | curl -fsS -X PUT --data-binary @- \
            "http://${CONSUL_HTTP}/v1/agent/service/register" >/dev/null && echo yes || echo no
        )
      fi
      if [ "$REGISTERED" = yes ]; then
        echo "[role-watcher] ${CLUSTER}-${PEER_ID} tag: ${PREV:-<none>} -> $TAG (patroni role=$PATRONI_ROLE)"
        PREV="$TAG"
      fi
    done
  ) &
fi

echo "patroni: peer=${PEER_ID} listen=127.0.0.1:${PG_PORT} connect_address=${PG_CONNECT_ADDR} consul=${CONSUL_HTTP}"
exec su-exec postgres patroni /etc/patroni.yml
