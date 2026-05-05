#!/bin/bash
# PID 1 inside the consolidated dstack-mesh sidecar container. Runs the
# four platform-plumbing processes that used to be four separate compose
# services (bootstrap-secrets, mesh-conn, consul, envoy) inside one
# container. tini wraps this script so signal-forwarding + PID 1 reaping
# behave like other tools expect.
#
# Order is fixed by real dependencies:
#   1. bootstrap-secrets runs to completion — writes /run/secrets/* and
#      /run/instance/info.json that everything else reads.
#   2. mesh-conn starts and forwards the Consul gossip + RPC ports to
#      peer CVMs over QUIC-on-ICE.
#   3. consul agent starts (server on coordinators, client on workers)
#      and joins the cluster via mesh-conn's local-loopback forwards.
#   4. envoy bootstraps from the local consul agent and starts the
#      sidecar data plane. Workers only — coordinators don't host
#      a Connect-mTLS workload.
#
# Phase-1 supervision policy: any one inner process dying takes the
# whole container down. Compose `restart: on-failure` brings it back
# in ~5s, well inside Patroni's 30s lock TTL — same effective recovery
# behavior as the old four-container layout, where any one of those
# containers crashing also resulted in a single ~5s restart.
#
# Per-process logs are prefixed with `[<process>]` so `docker logs
# dstack-sidecar-1` stays readable. Stderr is merged into stdout so a
# single `docker logs` stream sees everything.

set -euo pipefail
exec 2>&1

prefix() { sed -u "s/^/[$1] /" || cat; }
log()    { echo "[init] $*"; }

ROLE="${ROLE:?ROLE must be set (coordinator|worker)}"
log "starting consolidated sidecar, role=$ROLE"

# ---- 1. bootstrap-secrets (one-shot, must complete) ----
log "running bootstrap-secrets"
/usr/local/bin/bootstrap-secrets 2>&1 | prefix bootstrap-secrets
INFO=/run/instance/info.json
[ -s "$INFO" ] || { log "bootstrap-secrets did not write $INFO"; exit 1; }

# Identity/ports computed by bootstrap-secrets — read once, reuse.
PEER_ID=$(jq -r '.role + "-" + (.ordinal|tostring)' "$INFO")
ORDINAL=$(jq -r '.ordinal'         "$INFO")
SERF=$(jq    -r '.ports.serf_lan'   "$INFO")
RPC=$(jq     -r '.ports.server_rpc' "$INFO")
HTTP_PORT=$(jq -r '.ports.http_api' "$INFO")
GRPC_PORT=$(jq -r '.ports.grpc'     "$INFO")
log "identity: peer=$PEER_ID ordinal=$ORDINAL serf=$SERF http=$HTTP_PORT"

# ---- 2. mesh-conn (background, long-running) ----
log "starting mesh-conn"
/usr/local/bin/mesh-conn 2>&1 | prefix mesh-conn &
MESH=$!

# ---- 3. consul agent (background, long-running) ----
# Build -retry-join args from COORDINATOR_SERF_PORTS (comma-separated).
# Workers retry-join every coordinator port (mesh-conn forwards each one
# to its actual coordinator via loopback). Coordinators retry-join every
# coordinator port EXCEPT their own — that's how the server quorum
# gossips itself together.
RETRYJOIN=()
for p in $(echo "${COORDINATOR_SERF_PORTS}" | tr ',' ' '); do
  if [ "$ROLE" = "coordinator" ] && [ "$p" = "$SERF" ]; then
    continue
  fi
  RETRYJOIN+=("-retry-join=127.0.0.1:$p")
done

CONSUL_ARGS=(
  agent
  -node="$PEER_ID"
  -datacenter="${CLUSTER_NAME}"
  -bind=127.0.0.1 -advertise=127.0.0.1 -client=127.0.0.1
  -serf-lan-port="$SERF"
  -server-port="$RPC"
  -http-port="$HTTP_PORT"
  -grpc-port="$GRPC_PORT"
  -dns-port=-1
  "${RETRYJOIN[@]}"
  -data-dir=/consul/data
  -hcl='connect { enabled = true }'
  -log-level=INFO
)
if [ "$ROLE" = "coordinator" ]; then
  CONSUL_ARGS=(
    "${CONSUL_ARGS[@]}"
    -server
    -bootstrap-expect="${BOOTSTRAP_EXPECT}"
    -ui
  )
fi

log "starting consul agent"
/usr/local/bin/consul "${CONSUL_ARGS[@]}" 2>&1 | prefix consul &
CONSUL=$!

# ---- 4. envoy sidecar (workers only) ----
ENVOY=
if [ "$ROLE" = "worker" ]; then
  ADMIN_PORT=$((19100 + ORDINAL))
  log "starting envoy bootstrap loop (admin=$ADMIN_PORT)"
  (
    # Wait for the local consul agent to accept connections, then
    # generate the Envoy bootstrap config and exec envoy. The wait
    # loop is identical in spirit to the old sidecar/ entrypoint;
    # it tolerates the consul process taking a few seconds to listen.
    until consul connect envoy \
            -sidecar-for="webdemo-${PEER_ID}" \
            -admin-bind="127.0.0.1:${ADMIN_PORT}" \
            -bootstrap \
            -http-addr="127.0.0.1:${HTTP_PORT}" \
            -grpc-addr="127.0.0.1:${GRPC_PORT}" \
            > /tmp/envoy-bootstrap.json 2>/dev/null; do
      echo "waiting for sidecar registration..."
      sleep 3
    done
    exec envoy -c /tmp/envoy-bootstrap.json -l info
  ) 2>&1 | prefix envoy &
  ENVOY=$!
fi

CHILDREN=("$MESH" "$CONSUL")
[ -n "$ENVOY" ] && CHILDREN+=("$ENVOY")

# Forward SIGTERM/SIGINT to all background pipelines. Each inner
# process is the head of a `cmd | prefix` pipeline; killing the
# pipeline group is enough — sed exits when the upstream closes.
shutdown() {
  log "received signal, terminating children"
  for c in "${CHILDREN[@]}"; do
    kill -TERM "$c" 2>/dev/null || true
  done
}
trap shutdown TERM INT

# Block until ANY child exits; then reap the rest and let compose's
# `restart: on-failure` handle re-bringup. The `|| EXIT=$?` form keeps
# `set -e` from aborting the script when wait sees a non-zero rc — we
# want to fall through and clean up siblings before exiting.
EXIT=0
wait -n "${CHILDREN[@]}" || EXIT=$?
log "child exited (code=$EXIT) — tearing down sidecar"
for c in "${CHILDREN[@]}"; do
  kill -TERM "$c" 2>/dev/null || true
done
wait || true
exit "$EXIT"
