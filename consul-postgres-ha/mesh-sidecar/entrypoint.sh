#!/bin/bash
# PID 1 inside the consolidated dstack-mesh sidecar container.
#
# This is the entire platform plumbing for a CVM, in one process tree:
#   1. bootstrap-secrets — one-shot init; writes /run/instance/info.json
#                          (identity only — no per-protocol ports anymore)
#   2. ip addr add       — provisions peer-VIP loopback aliases for every
#                          peer in PEERS_JSON, and service-VIP aliases for
#                          every entry in UPSTREAMS_JSON (workers only)
#   3. mesh-conn         — QUIC-on-pion/ICE overlay; binds the static
#                          allowlist {21000, 21001, 8300, 8301} on every
#                          OTHER peer's VIP and forwards
#   4. consul agent      — server (coordinators) or client (workers).
#                          bind=127.0.0.1, advertise=127.50.0.<self-vip>;
#                          retry-joins to coords' VIPs on serf port
#   5. envoy × 2         — workers only. One Envoy per Connect sidecar:
#                          21000 for webdemo, 21001 for postgres. Stock
#                          Consul Connect requires one sidecar per service,
#                          hence two Envoy processes.
#   6. config entries    — coordinator-0 only, after quorum: writes
#                          proxy-defaults, postgres service-resolver,
#                          and a default-allow intentions stub
#
# Phase-1 supervision policy: any one inner process dying takes the
# whole container down. Compose `restart: on-failure` brings it back
# in ~5s, well inside Patroni's 30s lock TTL.

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

PEER_ID=$(jq -r '.role + "-" + (.ordinal|tostring)' "$INFO")
ORDINAL=$(jq -r '.ordinal' "$INFO")

# ---- 2. peer + service VIP loopback aliases ----
# Peer VIPs: 127.50.0.<vip>/32 for every peer in PEERS_JSON, including
# self. Self's alias is the local short-circuit: dialing 127.50.0.<self>
# routes through the kernel loopback driver to whatever's listening on
# 127.0.0.1:<port> (Envoy on workers, consul agent on coordinators), so
# the same address works for both local-self and cross-peer reach.
PEERS_JSON="${PEERS_JSON:?PEERS_JSON required}"
SELF_VIP=$(jq -r --arg id "$PEER_ID" '.[] | select(.id == $id) | .vip' <<<"$PEERS_JSON")
[ -n "$SELF_VIP" ] || { log "self id $PEER_ID not in PEERS_JSON"; exit 1; }
log "self vip=127.50.0.$SELF_VIP"

for vip in $(jq -r '.[].vip' <<<"$PEERS_JSON"); do
  ip addr add "127.50.0.${vip}/32" dev lo 2>/dev/null || true
done
log "peer VIPs provisioned: $(jq -r '[.[].vip]' <<<"$PEERS_JSON")"

# Service VIPs (workers only): 127.10.0.<vip>/32 per declared upstream.
# UPSTREAMS_JSON shape: [{"name": "postgres-master", "vip": 20, "port": 5432}, ...]
# Each entry gets a loopback alias; the actual Envoy listener on
# (127.10.0.<vip>, port) is created later when the sidecar Envoy starts.
UPSTREAMS_JSON="${UPSTREAMS_JSON:-[]}"
if [ "$ROLE" = "worker" ]; then
  for vip in $(jq -r '.[].vip' <<<"$UPSTREAMS_JSON"); do
    ip addr add "127.10.0.${vip}/32" dev lo 2>/dev/null || true
  done
  log "service VIPs provisioned: $(jq -r '[.[] | "\(.name)=127.10.0.\(.vip):\(.port)"]' <<<"$UPSTREAMS_JSON")"
fi

# ---- 3. mesh-conn (background, long-running) ----
log "starting mesh-conn"
/usr/local/bin/mesh-conn 2>&1 | prefix mesh-conn &
MESH=$!

# ---- 4. consul agent ----
# Build retry-join args from COORDINATOR_VIPS (comma-separated VIPs).
# Workers retry-join every coordinator on serf port 8301 over the peer
# VIP. Coordinators retry-join every coordinator EXCEPT themselves
# (self-join is implicit via -bootstrap-expect).
COORDINATOR_VIPS="${COORDINATOR_VIPS:?COORDINATOR_VIPS required (comma-separated)}"
RETRYJOIN=()
for cv in $(echo "$COORDINATOR_VIPS" | tr ',' ' '); do
  if [ "$ROLE" = "coordinator" ] && [ "$cv" = "$SELF_VIP" ]; then
    continue
  fi
  RETRYJOIN+=("-retry-join=127.50.0.${cv}:8301")
done

CONSUL_ARGS=(
  agent
  -node="$PEER_ID"
  -datacenter="${CLUSTER_NAME}"
  -bind=127.0.0.1
  -advertise="127.50.0.${SELF_VIP}"
  -client=127.0.0.1
  -serf-lan-port=8301
  -server-port=8300
  -http-port=8500
  -grpc-port=8502
  -dns-port=-1
  "${RETRYJOIN[@]}"
  -data-dir=/consul/data
  -hcl='connect { enabled = true }'
  # Stage-1 WORKAROUND: GOSSIP_KEY is generated in Terraform and
  # broadcast to every CVM via env. Stage-2 attestation will replace
  # this with TEE-rooted material — see design/attestation-admission.md.
  -encrypt="${GOSSIP_KEY:?GOSSIP_KEY required}"
  -log-level=INFO
)
if [ "$ROLE" = "coordinator" ]; then
  CONSUL_ARGS+=(
    -server
    -bootstrap-expect="${BOOTSTRAP_EXPECT}"
    -ui
  )
fi

log "starting consul agent (advertise=127.50.0.$SELF_VIP)"
/usr/local/bin/consul "${CONSUL_ARGS[@]}" 2>&1 | prefix consul &
CONSUL=$!

CONSUL_HTTP="127.0.0.1:8500"
export CONSUL_HTTP_ADDR="$CONSUL_HTTP"

# Wait for the local agent to accept HTTP requests; everything below
# (sidecar registration, leaf cert, envoy bootstrap) goes through it.
wait_consul_ready() {
  local n=0
  until consul members >/dev/null 2>&1; do
    n=$((n+1))
    if [ $n -gt 60 ]; then
      log "consul agent not reachable after 60s"
      return 1
    fi
    sleep 1
  done
}

# ---- 5. workers: register postgres sidecar + launch both Envoys ----
ENVOYS=()
if [ "$ROLE" = "worker" ]; then
  log "waiting for local consul agent..."
  wait_consul_ready

  # Register the standalone postgres Connect sidecar proxy. The proxy's
  # destination_service_name is `postgres` (the parent service Patroni
  # auto-registers); inbound mTLS for `postgres` lands here and is
  # forwarded to local 127.0.0.1:5432. Service-resolver entries map
  # `postgres-master`/`postgres-replica` to subsets of `postgres`
  # filtered by the role tag Patroni stamps on each registration.
  POSTGRES_MASTER_VIP=$(jq -r '.[] | select(.name=="postgres-master") | .vip' <<<"$UPSTREAMS_JSON")
  POSTGRES_REPLICA_VIP=$(jq -r '.[] | select(.name=="postgres-replica") | .vip' <<<"$UPSTREAMS_JSON")
  cat > /tmp/postgres-sidecar.json <<EOF
{
  "kind": "connect-proxy",
  "id": "postgres-sidecar-${PEER_ID}",
  "name": "postgres-sidecar-proxy",
  "address": "127.50.0.${SELF_VIP}",
  "port": 21001,
  "proxy": {
    "destination_service_name": "postgres",
    "destination_service_id": "postgres-${PEER_ID}",
    "local_service_address": "127.0.0.1",
    "local_service_port": 5432,
    "upstreams": [
      {
        "destination_name": "postgres-master",
        "local_bind_address": "127.10.0.${POSTGRES_MASTER_VIP}",
        "local_bind_port": 5432
      },
      {
        "destination_name": "postgres-replica",
        "local_bind_address": "127.10.0.${POSTGRES_REPLICA_VIP}",
        "local_bind_port": 5432
      }
    ]
  }
}
EOF
  # Re-register on every boot; Consul's API is PUT-style so this is
  # idempotent. Patroni's auto-registration of the regular `postgres`
  # service may not have landed yet — that's fine, the sidecar can
  # register before its destination service exists.
  log "registering postgres-sidecar-proxy (port=21001)"
  until consul services register /tmp/postgres-sidecar.json; do
    log "postgres-sidecar-proxy register failed; retrying"
    sleep 2
  done

  # Wait for Connect CA to be able to mint leaf certs. Servers don't
  # need Envoy to form quorum (Raft RPC rides peer VIPs as plain TCP),
  # but workers can't start their sidecars until a server can issue.
  log "waiting for connect CA to be ready..."
  until consul connect ca leaf -service=postgres >/dev/null 2>&1; do
    sleep 2
  done
  log "connect CA ready"

  # Webdemo Envoy supervise loop. Webdemo registers itself + a
  # SidecarService block with port=21000 from its own entrypoint;
  # consul connect envoy waits for that registration to land.
  (
    until consul connect envoy \
            -sidecar-for="webdemo-${PEER_ID}" \
            -admin-bind="127.0.0.1:19000" \
            >/dev/null 2>/dev/null; do
      echo "[envoy-webdemo] waiting for webdemo sidecar registration..."
      sleep 2
    done
  ) 2>&1 | prefix envoy-webdemo &
  ENVOYS+=("$!")

  # Postgres Envoy supervise loop. The proxy-id is what we registered
  # above; consul connect envoy bootstraps Envoy from that registration.
  (
    until consul connect envoy \
            -proxy-id="postgres-sidecar-${PEER_ID}" \
            -admin-bind="127.0.0.1:19001" \
            >/dev/null 2>/dev/null; do
      echo "[envoy-postgres] waiting for ca leaf..."
      sleep 2
    done
  ) 2>&1 | prefix envoy-postgres &
  ENVOYS+=("$!")
fi

# ---- 6. coordinator-0: write Connect config entries (idempotent) ----
# Done from coord-0 only because config entries are cluster-wide; any
# coord agent could do it. consul config write is idempotent (PUT-style).
if [ "$ROLE" = "coordinator" ] && [ "$ORDINAL" = "0" ]; then
  (
    log "config-entry writer: waiting for consul"
    wait_consul_ready
    # Wait for the full coordinator quorum to be visible — config-entry
    # writes need a server with leadership and a healthy quorum.
    until [ "$(consul members 2>/dev/null | awk 'NR>1 && $4=="server" && $3=="alive"' | wc -l)" -ge "${BOOTSTRAP_EXPECT}" ]; do
      sleep 2
    done
    log "config-entry writer: quorum ready, writing entries"

    consul config write - <<'HCL' || true
Kind = "proxy-defaults"
Name = "global"
Config { protocol = "tcp" }
HCL

    # Postgres subset definitions. Patroni auto-registers the parent
    # `postgres` service with role tags (master|replica); subsets pick
    # the right instances by tag, and the redirect resolvers expose
    # consumer-facing names that are independent of Patroni's tagging.
    consul config write - <<'HCL' || true
Kind    = "service-resolver"
Name    = "postgres"
Subsets = {
  master  = { Filter = "Service.Tags contains \"master\"" }
  replica = { Filter = "Service.Tags contains \"replica\"" }
}
HCL

    consul config write - <<'HCL' || true
Kind     = "service-resolver"
Name     = "postgres-master"
Redirect { Service = "postgres", ServiceSubset = "master" }
HCL

    consul config write - <<'HCL' || true
Kind     = "service-resolver"
Name     = "postgres-replica"
Redirect { Service = "postgres", ServiceSubset = "replica" }
HCL

    # Default-allow intentions for now. Tightening this to per-pair
    # allow + default-deny is straightforward but out of scope here;
    # see design/attestation-admission.md for the longer-term shape.
    consul config write - <<'HCL' || true
Kind = "service-intentions"
Name = "postgres"
Sources = [{ Name = "*", Action = "allow" }]
HCL
    consul config write - <<'HCL' || true
Kind = "service-intentions"
Name = "webdemo"
Sources = [{ Name = "*", Action = "allow" }]
HCL
    log "config-entry writer: done"
  ) 2>&1 | prefix consul-config &
fi

# ---- 7. signal handling + child supervision ----
CHILDREN=("$MESH" "$CONSUL")
[ ${#ENVOYS[@]} -gt 0 ] && CHILDREN+=("${ENVOYS[@]}")

shutdown() {
  log "received signal, terminating children"
  for c in "${CHILDREN[@]}"; do
    kill -TERM "$c" 2>/dev/null || true
  done
}
trap shutdown TERM INT

# Block until ANY child exits; then reap the rest and let compose's
# `restart: on-failure` handle re-bringup.
EXIT=0
wait -n "${CHILDREN[@]}" || EXIT=$?
log "child exited (code=$EXIT) — tearing down sidecar"
for c in "${CHILDREN[@]}"; do
  kill -TERM "$c" 2>/dev/null || true
done
wait || true
exit "$EXIT"
