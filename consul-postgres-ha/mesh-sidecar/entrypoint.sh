#!/bin/bash
# PID 1 inside the consolidated dstack-mesh sidecar container.
#
# This is the entire platform plumbing for a CVM, in one process tree:
#   1. bootstrap-secrets — one-shot init; writes /run/instance/info.json
#                          (identity only — no per-protocol ports)
#   2. ip addr add       — provisions peer-VIP loopback aliases for every
#                          peer in PEERS_JSON, and service-VIP aliases
#                          for every entry in SERVICES_JSON (workers only)
#   3. mesh-conn         — QUIC-on-pion/ICE overlay; binds the allowlist
#                          (per-service sidecar ports + {8300, 8301})
#                          on every OTHER peer's VIP and forwards
#   4. consul agent      — server (coordinators) or client (workers).
#                          bind=127.0.0.1, advertise=127.50.0.<self-vip>;
#                          retry-joins to coords' VIPs on serf port
#   5. admission-broker  — coordinators only when attestation admission
#                          is enabled. Verifies quotes and mints
#                          service-identity ACL tokens.
#   6. envoy × N         — workers only. One Envoy per producer-side
#                          sidecar (one per unique canonical port in
#                          SERVICES_JSON). Each Envoy gets a distinct
#                          --base-id and admin-port.
#   7. config entries    — coordinator-0 only, after quorum: writes
#                          proxy-defaults, per-parent subset resolvers,
#                          per-subset redirect resolvers, and per-parent
#                          default-allow intentions — all generated from
#                          SERVICES_JSON, no per-workload code paths.
#
# SERVICES_JSON shape (single source of truth; cluster.tf generates this):
#
#   [
#     {
#       "name":             "webdemo",     # Consul service name + /etc/hosts alias
#       "port":             8080,          # canonical app port (127.0.0.1:port)
#       "subset":           null,          # optional subset filter
#       "vip":              10,            # service-VIP last octet (127.10.0.vip)
#       "sidecar_port":     21000,         # Envoy public mTLS port (shared per backend)
#       "parent":           "webdemo",     # parent Consul service name
#       "registers_parent": true           # platform registers parent service inline
#     },
#     ...
#   ]
#
# Services with the same canonical `port` collapse onto one backend
# (one sidecar_port, one Envoy). For `registers_parent=false`, the
# workload owns the *authoritative* parent service registration
# (tags, health check) under its own `scope` — e.g. Patroni's native
# Consul integration registers `${scope}/${peer}` with role tags and a
# REST-API health check. To avoid the chicken-and-egg where the
# workload can't run (no consumer-side Envoy listener yet) before it
# has registered (Patroni only registers after pg_basebackup, which
# needs the listener), the platform pre-registers a *stub* parent
# service at the same service_id so Consul's proxycfg can populate
# the connect-proxy's state immediately. The workload's later PUT
# overwrites the stub in place (same service_id ⇒ idempotent), adding
# its check and role tags.
#
# Supervision policy: any one inner process dying takes the whole
# container down. Compose `restart: on-failure` brings it back in
# ~5s, well inside typical leader-lock TTLs.

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

# Service VIPs (workers only): one 127.10.0.<vip>/32 alias per logical
# service entry, including subset entries (postgres-master + -replica
# each get their own VIP, so they resolve to distinct consumer-side
# Envoy listeners even when they share a producer-side sidecar).
SERVICES_JSON="${SERVICES_JSON:-[]}"
if [ "$ROLE" = "worker" ]; then
  for vip in $(jq -r '.[].vip' <<<"$SERVICES_JSON"); do
    ip addr add "127.10.0.${vip}/32" dev lo 2>/dev/null || true
  done
  log "service VIPs provisioned: $(jq -r '[.[] | "\(.name)=127.10.0.\(.vip):\(.port)"]' <<<"$SERVICES_JSON")"
fi

# ---- 3. mesh-conn allowlist + start ----
# MESH_CONN_ALLOWLIST: per-backend sidecar_ports (unique because
# services sharing a canonical port collapse onto one sidecar) plus
# the two static Consul-infra ports (8300 RPC, 8301 gossip). mesh-conn
# reads this from env at startup; the substance — which ports cross
# peer boundaries — is declared in cluster.tf, not in mesh-conn code.
MESH_CONN_ALLOWLIST=$(
  jq -c '
    ( [ .[] | .sidecar_port ] | unique | map({port: ., udp: false}) )
    +
    [ {port: 8300, udp: false}, {port: 8301, udp: true}, {port: 8787, udp: false} ]
  ' <<<"$SERVICES_JSON"
)
export MESH_CONN_ALLOWLIST
log "mesh-conn allowlist: $MESH_CONN_ALLOWLIST"

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

admission_broker_urls() {
  echo "$COORDINATOR_VIPS" | tr ',' '\n' | awk 'NF { printf "%shttp://127.50.0.%s:8787", sep, $1; sep="," }'
}

CONSUL_AGENT_TOKEN=""
ADMISSION_BROKER_URLS=""
if [ "$ROLE" = "worker" ] && [ "${ADMISSION_BROKER_ENABLE:-}" = "1" ]; then
  ADMISSION_BROKER_URLS=$(admission_broker_urls)
  NODE_TOKEN_FILE="/tmp/consul-agent-token"
  log "requesting attested Consul agent token (${CLUSTER_NAME}/node)"
  /usr/local/bin/admission-client \
    -identity "spiffe://${CLUSTER_NAME}/node" \
    -broker-urls "$ADMISSION_BROKER_URLS" \
    -token-file "$NODE_TOKEN_FILE" \
    -cluster "$CLUSTER_NAME" \
    -peer-id "$PEER_ID" \
    -timeout 15m 2>&1 | prefix admission-client-node
  CONSUL_AGENT_TOKEN=$(tr -d '\r\n' < "$NODE_TOKEN_FILE")
  [ -n "$CONSUL_AGENT_TOKEN" ] || { log "attested Consul agent token is empty"; exit 1; }
fi

CONSUL_ARGS=(
  agent
  -node="$PEER_ID"
  -datacenter="${CLUSTER_NAME}"
  # bind on the self-VIP so serf + RPC listen there. Consumers (other
  # peers AND self) reach this Consul at 127.50.0.<self-vip>:8301/8300:
  #   - other-peer dials → that peer's mesh-conn forwards via QUIC →
  #     this peer's mesh-conn dispatches to 127.50.0.<self-vip>:port →
  #     Consul receives.
  #   - self-dial (e.g. internal "server health" probe) → kernel
  #     loopback → Consul receives directly. No mesh-conn hop.
  -bind="127.50.0.${SELF_VIP}"
  -advertise="127.50.0.${SELF_VIP}"
  # HTTP API + gRPC stay loopback-only — apps and workload entrypoints
  # use them from inside the same network namespace, never via the mesh.
  -client=127.0.0.1
  -serf-lan-port=8301
  -server-port=8300
  -http-port=8500
  -grpc-port=8502
  -dns-port=-1
  "${RETRYJOIN[@]}"
  -data-dir=/consul/data
  -hcl='connect { enabled = true }'
  # WORKAROUND: GOSSIP_KEY is generated in Terraform and broadcast
  # to every CVM via env. Attestation-rooted admission will replace
  # this with TEE-rooted material — see design/attestation-admission.md.
  -encrypt="${GOSSIP_KEY:?GOSSIP_KEY required}"
  -log-level=INFO
)
if [ "${ADMISSION_BROKER_ENABLE:-}" = "1" ]; then
  if [ "$ROLE" = "coordinator" ]; then
    : "${CONSUL_MANAGEMENT_TOKEN:?CONSUL_MANAGEMENT_TOKEN required on coordinators when admission is enabled}"
    CONSUL_ARGS+=(
      -hcl="acl { enabled = true default_policy = \"deny\" enable_token_persistence = true tokens { initial_management = \"${CONSUL_MANAGEMENT_TOKEN}\" agent = \"${CONSUL_MANAGEMENT_TOKEN}\" } }"
    )
  else
    : "${CONSUL_AGENT_TOKEN:?CONSUL_AGENT_TOKEN missing after attestation admission}"
    CONSUL_ARGS+=(
      -hcl="acl { enabled = true default_policy = \"deny\" enable_token_persistence = true tokens { agent = \"${CONSUL_AGENT_TOKEN}\" } }"
    )
  fi
fi
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

# ---- 5. coordinators: optional admission broker ----
ADMISSION_BROKER_PID=""
if [ "$ROLE" = "coordinator" ] && [ "${ADMISSION_BROKER_ENABLE:-}" = "1" ]; then
  log "starting admission-broker"
  /usr/local/bin/admission-broker -listen "127.50.0.${SELF_VIP}:8787" 2>&1 | prefix admission-broker &
  ADMISSION_BROKER_PID=$!
fi

# Wait for the local agent to listen on its HTTP socket. This is deliberately
# a transport-level local check, not a Consul API authorization check and not
# cluster membership: workers cannot join servers until mesh-conn is up, and
# ACL-protected agent endpoints can return primary-dc-down before that join.
wait_consul_ready() {
  local n=0
  until timeout 1 bash -c "cat < /dev/null > /dev/tcp/${CONSUL_HTTP%:*}/${CONSUL_HTTP##*:}" 2>/dev/null; do
    n=$((n+1))
    if [ $n -gt 60 ]; then
      log "consul agent not reachable after 60s"
      return 1
    fi
    sleep 1
  done
}

# ---- 6. workers: register one Consul service+sidecar per backend, launch Envoys ----
ENVOYS=()
if [ "$ROLE" = "worker" ]; then
  log "waiting for local consul agent..."
  wait_consul_ready

  # Iterate unique backends — one per distinct sidecar_port. For each
  # backend we render one Consul registration JSON and one Envoy
  # supervise loop. The two patterns are folded inline because they
  # only diverge in how Consul resolves the parent service:
  #
  #   pattern A (registers_parent=true):  inline SidecarService on
  #     the parent service (webdemo-style). The PUT below registers
  #     BOTH the parent service AND its sidecar in one shot.
  #
  #   pattern B (registers_parent=false): standalone connect-proxy
  #     registration — the parent service is auto-registered by the
  #     workload itself under its `scope`; the platform just stands up
  #     the Envoy proxy that fronts it.
  BACKENDS=$(jq -c '
    group_by(.sidecar_port) | map({
      sidecar_port:     .[0].sidecar_port,
      port:             .[0].port,
      parent:           .[0].parent,
      registers_parent: .[0].registers_parent,
      # Upstreams = all logical services sharing this backend. Each
      # one gets its own consumer-side Envoy listener on its VIP.
      # Distinct VIPs across backends mean every Envoy can bind its
      # upstream listeners without colliding with other Envoys.
      upstreams: [.[] | {
        DestinationName:  .name,
        LocalBindAddress: ("127.10.0." + (.vip|tostring)),
        LocalBindPort:    .port
      }],
      admission_identity: .[0].admission_identity
    })
  ' <<<"$SERVICES_JSON")

  BACKEND_IDX=0
  while IFS= read -r BACKEND; do
    [ -z "$BACKEND" ] && continue

    PARENT=$(jq -r '.parent' <<<"$BACKEND")
    SIDECAR_PORT=$(jq -r '.sidecar_port' <<<"$BACKEND")
    LOCAL_PORT=$(jq -r '.port' <<<"$BACKEND")
    REGISTERS_PARENT=$(jq -r '.registers_parent' <<<"$BACKEND")
    UPSTREAMS=$(jq -c '.upstreams' <<<"$BACKEND")
    ADMISSION_IDENTITY=$(jq -r '.admission_identity // empty' <<<"$BACKEND")
    BASE_ID=$((BACKEND_IDX + 1))
    ADMIN_PORT=$((19000 + BACKEND_IDX))
    SPEC_FILE="/tmp/sidecar-${PARENT}.json"
    ENVOY_BOOT="/tmp/envoy-${PARENT}.json"
    TOKEN_FILE="/tmp/consul-token-${PARENT}"
    BACKEND_CONSUL_TOKEN=""

    if [ "${ADMISSION_BROKER_ENABLE:-}" = "1" ]; then
      [ -n "$ADMISSION_IDENTITY" ] || { log "backend ${PARENT} missing admission_identity"; exit 1; }
      if [ "$PARENT" = "$CLUSTER_NAME" ]; then
        TOKEN_FILE="/run/consul-tokens/consul-token-${PARENT}"
      fi
      log "requesting admission token for ${PARENT} (${ADMISSION_IDENTITY})"
      /usr/local/bin/admission-client \
        -identity "$ADMISSION_IDENTITY" \
        -broker-urls "$ADMISSION_BROKER_URLS" \
        -token-file "$TOKEN_FILE" \
        -cluster "$CLUSTER_NAME" \
        -peer-id "$PEER_ID" \
        -timeout 15m 2>&1 | prefix "admission-client-${PARENT}"
      BACKEND_CONSUL_TOKEN=$(tr -d '\r\n' < "$TOKEN_FILE")
      [ -n "$BACKEND_CONSUL_TOKEN" ] || { log "admission token for ${PARENT} is empty"; exit 1; }
    fi

    # Both patterns use a single registration with inline SidecarService:
    # that's the shape Consul recognises as a Connect-aware service +
    # its proxy. A bare `Kind: connect-proxy` plus a separate parent
    # without `Connect.SidecarService` is not enough — Consul won't
    # return the proxy as a Connect endpoint for the parent, so the
    # discovery chain resolves to zero hosts and consumer Envoys close
    # incoming connections immediately.
    #
    # The two patterns differ only in service_id and what overwrites
    # the registration over time:
    #
    #   pattern A (webdemo): platform-only. Parent ID is
    #     "${parent}-${peer}", tagged "peer=${peer}". Nothing else
    #     touches this registration.
    #
    #   pattern B (Patroni): platform pre-registers a "stub" with no
    #     role tags. Patroni's entrypoint role-watcher re-PUTs the
    #     same service_id with tags ["master"] / ["replica"] tracked
    #     from Patroni REST. We keep `register_service: false` in
    #     patroni.yml so Patroni's own integration stays out of the
    #     service catalog (it only uses Consul as DCS); see
    #     patroni/entrypoint.sh for the role-watcher.
    # Service ID format is `${parent}-${peer}` for both patterns so it
    # never contains a slash. Slashes in service IDs trip up
    # `consul connect envoy -sidecar-for` URL handling.
    PARENT_ID="${PARENT}-${PEER_ID}"
    if [ "$REGISTERS_PARENT" = "true" ]; then
      TAGS_JSON='["peer='"$PEER_ID"'"]'
    else
      TAGS_JSON='[]'
    fi

    CURL_TOKEN_ARGS=()
    [ -n "$BACKEND_CONSUL_TOKEN" ] && CURL_TOKEN_ARGS=(-H "X-Consul-Token: ${BACKEND_CONSUL_TOKEN}")

    # Defensive cleanup: a prior boot may have used different IDs for
    # the same logical proxy (e.g. an earlier release of this image
    # registered Pattern B as `Kind: connect-proxy` with ID
    # `${parent}-sidecar-${peer}`). Consul-data is a persistent volume
    # so the stale entries survive container restarts; if they linger
    # alongside the new inline SidecarService, `consul connect envoy
    # -sidecar-for` sees two matches and refuses to render. Deregister
    # known stale IDs idempotently before we PUT the new spec.
    STALE_SIDECAR_ID="${PARENT}-sidecar-${PEER_ID}"
    curl -fsS "${CURL_TOKEN_ARGS[@]}" -X PUT "http://127.0.0.1:8500/v1/agent/service/deregister/${STALE_SIDECAR_ID}" \
      >/dev/null 2>&1 || true
    jq -n \
      --arg name "$PARENT" \
      --arg id "$PARENT_ID" \
      --argjson port "$LOCAL_PORT" \
      --arg vip "$SELF_VIP" \
      --argjson sport "$SIDECAR_PORT" \
      --argjson tags "$TAGS_JSON" \
      --argjson upstreams "$UPSTREAMS" '{
        Name: $name,
        ID: $id,
        Address: "127.0.0.1",
        Port: $port,
        Tags: $tags,
        Check: {
          TCP: ("127.0.0.1:" + ($port|tostring)),
          Interval: "10s",
          Timeout: "2s",
          DeregisterCriticalServiceAfter: "1m"
        },
        Connect: {
          SidecarService: {
            Address: ("127.50.0." + $vip),
            Port: $sport,
            Proxy: {
              LocalServiceAddress: "127.0.0.1",
              LocalServicePort: $port,
              Upstreams: $upstreams
            }
          }
        }
      }' > "$SPEC_FILE"
    ENVOY_ARGS=(-sidecar-for="$PARENT_ID")

    # Re-register on every boot via the agent HTTP API (PUT-idempotent).
    log "registering ${PARENT} (id=${PARENT_ID}) + sidecar (port=${SIDECAR_PORT}, base-id=${BASE_ID})"
    until curl -fsS "${CURL_TOKEN_ARGS[@]}" -X PUT --data-binary @"$SPEC_FILE" \
             http://127.0.0.1:8500/v1/agent/service/register; do
      log "${PARENT} register failed; retrying"
      sleep 2
    done

    # Wait for Connect CA to be able to mint leaf certs — done once
    # per backend, but the operation is idempotent so the extra polls
    # on subsequent backends are cheap.
    log "waiting for connect CA to be ready (backend=${PARENT})..."
    until curl -fsS "${CURL_TOKEN_ARGS[@]}" "http://127.0.0.1:8500/v1/agent/connect/ca/leaf/${PARENT}" >/dev/null 2>&1; do
      sleep 2
    done

    # Envoy supervise loop. `consul connect envoy -bootstrap` generates
    # the JSON, then we exec envoy ourselves; this bypasses Consul's
    # Envoy version-compat check (Envoy 1.30 isn't on Consul 1.19's
    # supported list, but the bootstrap config itself is fine).
    #
    # `set +e` because envoy crashes mid-startup count as expected
    # events the while loop handles by retrying — outer `set -e` would
    # bubble them up as a "child exited" → container teardown.
    #
    # --base-id distinguishes each envoy from its siblings; otherwise
    # they fight over the default base-id=0 hot-restart domain socket
    # and one fails with EADDRINUSE.
    (
      set +eo pipefail
      while true; do
        if CONSUL_HTTP_TOKEN="${BACKEND_CONSUL_TOKEN:-}" consul connect envoy \
              "${ENVOY_ARGS[@]}" \
              -admin-bind="127.0.0.1:${ADMIN_PORT}" \
              -bootstrap \
              > "$ENVOY_BOOT" 2>/dev/null; then
          envoy -c "$ENVOY_BOOT" -l info --base-id "$BASE_ID" 2>&1
        else
          echo "[envoy-${PARENT}] waiting for sidecar registration / leaf cert..."
        fi
        sleep 2
      done
    ) 2>&1 | prefix "envoy-${PARENT}" &
    ENVOYS+=("$!")

    BACKEND_IDX=$((BACKEND_IDX + 1))
  done < <(jq -c '.[]' <<<"$BACKENDS")
fi

# ---- 7. coordinator-0: write Connect config entries (idempotent) ----
# Done from coord-0 only because config entries are cluster-wide; any
# coord agent could do it. consul config write is idempotent (PUT-style).
if [ "$ROLE" = "coordinator" ] && [ "$ORDINAL" = "0" ]; then
  (
    log "config-entry writer: waiting for consul"
    wait_consul_ready
    # Wait for the full coordinator quorum to be visible — config-entry
    # writes need a server with leadership and a healthy quorum.
    until [ "$(CONSUL_HTTP_TOKEN="${CONSUL_MANAGEMENT_TOKEN:-}" consul members 2>/dev/null | awk 'NR>1 && $4=="server" && $3=="alive"' | wc -l)" -ge "${BOOTSTRAP_EXPECT}" ]; do
      sleep 2
    done
    log "config-entry writer: quorum ready, writing entries"

    CONSUL_HTTP_TOKEN="${CONSUL_MANAGEMENT_TOKEN:-}" consul config write - <<'HCL' || true
Kind = "proxy-defaults"
Name = "global"
Config { protocol = "tcp" }
HCL

    # Per-parent subset resolvers: for every parent service that has
    # any subset-bearing logical names, declare the subset filters on
    # the parent. The filter pulls instances whose Service.Tags
    # contains the subset name; the workload's own entrypoint writes
    # those tags onto its sidecar registration (pattern B).
    jq -c '
      group_by(.parent)
      | map({
          parent: .[0].parent,
          subsets: [ .[] | select(.subset != null) | .subset ] | unique
        })
      | map(select(.subsets | length > 0))
      | .[]
    ' <<<"$SERVICES_JSON" | while IFS= read -r row; do
      [ -z "$row" ] && continue
      parent=$(jq -r '.parent' <<<"$row")
      subsets_hcl=$(jq -r '.subsets | map("  " + . + " = { Filter = \"Service.Tags contains \\\"" + . + "\\\"\" }") | join("\n")' <<<"$row")
      CONSUL_HTTP_TOKEN="${CONSUL_MANAGEMENT_TOKEN:-}" consul config write - <<HCL || true
Kind    = "service-resolver"
Name    = "${parent}"
Subsets = {
${subsets_hcl}
}
HCL
    done

    # Per-subset redirect resolvers: each subset-bearing logical name
    # gets a service-resolver that redirects to its parent + subset.
    # That's what makes `postgres-master:5432` resolve to the master
    # subset of the parent service.
    jq -c '.[] | select(.subset != null)' <<<"$SERVICES_JSON" | while IFS= read -r row; do
      [ -z "$row" ] && continue
      name=$(jq -r '.name' <<<"$row")
      parent=$(jq -r '.parent' <<<"$row")
      subset=$(jq -r '.subset' <<<"$row")
      CONSUL_HTTP_TOKEN="${CONSUL_MANAGEMENT_TOKEN:-}" consul config write - <<HCL || true
Kind     = "service-resolver"
Name     = "${name}"
Redirect { Service = "${parent}", ServiceSubset = "${subset}" }
HCL
    done

    # Default-allow intentions per parent. Tightening this to per-pair
    # allow + default-deny is straightforward but out of scope here;
    # see design/attestation-admission.md for the longer-term shape.
    jq -r '[.[].parent] | unique | .[]' <<<"$SERVICES_JSON" | while IFS= read -r parent; do
      [ -z "$parent" ] && continue
      CONSUL_HTTP_TOKEN="${CONSUL_MANAGEMENT_TOKEN:-}" consul config write - <<HCL || true
Kind = "service-intentions"
Name = "${parent}"
Sources = [{ Name = "*", Action = "allow" }]
HCL
    done

    log "config-entry writer: done"
  ) 2>&1 | prefix consul-config &
fi

# ---- 8. signal handling + child supervision ----
CHILDREN=("$MESH" "$CONSUL")
[ -n "$ADMISSION_BROKER_PID" ] && CHILDREN+=("$ADMISSION_BROKER_PID")
[ ${#ENVOYS[@]} -gt 0 ] && CHILDREN+=("${ENVOYS[@]}")

# shellcheck disable=SC2317 # Invoked indirectly by the TERM/INT trap.
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
