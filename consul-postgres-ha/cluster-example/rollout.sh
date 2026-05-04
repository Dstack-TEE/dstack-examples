#!/usr/bin/env bash
# Stage 4 — workload-aware rolling update driver.
#
# Until phala-cloud#243 lands `phala_app.update_policy`, the platform's
# in-place app update touches all replicas in unspecified order. That's
# fine for stateless workers but dangerous for the Consul quorum (and
# any other leader-bearing workload). This script drives the rollout
# from outside Terraform with workload-aware drains between replica
# updates.
#
# Usage:
#   ./rollout.sh                       # full rolling update (apply per-app, gated)
#   ./rollout.sh --app worker          # roll only the worker app
#   ./rollout.sh --plan                # show what would happen, don't apply
#
# Requires:
#   PHALA_CLOUD_API_KEY env (or terraform `phala` provider config)
#   terraform CLI on PATH
#   A working overlay (mesh-conn + Consul) so we can query cluster health.

set -euo pipefail

# ---------- Config ----------

CLUSTER_NAME="${CLUSTER_NAME:-demo}"
GATEWAY_DOMAIN="${GATEWAY_DOMAIN:-dstack-pha-prod5.phala.network}"
COORDINATOR_HTTP_PORT="${COORDINATOR_HTTP_PORT:-18200}"
MIN_READY_SECONDS="${MIN_READY_SECONDS:-30}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-180}"

PLAN_ONLY=false
APP_FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)  PLAN_ONLY=true; shift ;;
    --app)   APP_FILTER="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ---------- Helpers ----------

CONSUL_BASE=""

resolve_consul_base() {
  local coord_id
  coord_id=$(terraform output -raw coordinator_app_id 2>/dev/null || true)
  if [[ -z "$coord_id" ]]; then
    echo "ERROR: terraform output coordinator_app_id failed; run terraform apply at least once" >&2
    exit 1
  fi
  CONSUL_BASE="https://${coord_id}-${COORDINATOR_HTTP_PORT}s.${GATEWAY_DOMAIN}"
}

consul_members_alive() {
  curl -sf "${CONSUL_BASE}/v1/agent/members" \
    | jq -r '[.[] | select(.Status==1)] | length' 2>/dev/null \
    || echo 0
}

consul_leader_present() {
  local lead
  lead=$(curl -sf "${CONSUL_BASE}/v1/status/leader" 2>/dev/null || echo '""')
  [[ "$lead" != '""' && -n "$lead" ]]
}

wait_for_quorum_healthy() {
  local expected="$1"
  local deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SECONDS ))
  while (( $(date +%s) < deadline )); do
    local alive
    alive=$(consul_members_alive)
    if [[ "$alive" == "$expected" ]] && consul_leader_present; then
      sleep "$MIN_READY_SECONDS"
      # re-check after the cool-off
      alive=$(consul_members_alive)
      if [[ "$alive" == "$expected" ]] && consul_leader_present; then
        return 0
      fi
    fi
    sleep 5
  done
  return 1
}

snapshot_consul() {
  local label="$1"
  local snap_dir="snapshots"
  mkdir -p "$snap_dir"
  local f="$snap_dir/${label}-$(date +%Y%m%d-%H%M%S).snap"
  if curl -sf -X PUT "${CONSUL_BASE}/v1/snapshot" -o "$f"; then
    echo "snapshot saved: $f"
  else
    echo "WARN: snapshot save failed (continuing)" >&2
  fi
}

# Transfer Raft leader off the named node if it's currently leader.
# No-op if some other node is leader.
maybe_transfer_leader() {
  local current_node="$1"
  local lead
  lead=$(curl -sf "${CONSUL_BASE}/v1/status/leader" 2>/dev/null | jq -r .)
  echo "current leader: $lead; this node: $current_node"
  # Heuristic: if leader contains current_node's RPC port, transfer.
  if [[ "$lead" == *":${current_node}"* ]]; then
    echo "transferring leadership away from $current_node"
    curl -sf -X POST "${CONSUL_BASE}/v1/operator/raft/transfer-leader" >/dev/null \
      || echo "WARN: leader transfer rejected (likely single-server cluster)"
    sleep 5
  fi
}

# ---------- Main ----------

resolve_consul_base
echo "Consul UI base: $CONSUL_BASE"

EXPECTED=$(curl -sf "${CONSUL_BASE}/v1/agent/members" 2>/dev/null | jq -r 'length' || echo 0)
echo "current members alive: $(consul_members_alive) / $EXPECTED"

if ! consul_leader_present; then
  echo "ERROR: cluster has no leader; refusing to roll" >&2
  exit 1
fi

snapshot_consul "pre-rollout"

if $PLAN_ONLY; then
  terraform plan
  exit 0
fi

# For now: a single `terraform apply` triggers Phala's in-place app
# update for every changed app. Until per-instance updates are
# available (phala-cloud#243), we can only gate at the app boundary.
#
# Apply order: workers first (stateless mostly; if one fails we still
# have the others), coordinator last (it's the Consul server, biggest
# blast radius).

APPS_TO_ROLL=()
if [[ -z "$APP_FILTER" || "$APP_FILTER" == "worker" ]]; then
  APPS_TO_ROLL+=("phala_app.worker")
fi
if [[ -z "$APP_FILTER" || "$APP_FILTER" == "coordinator" ]]; then
  APPS_TO_ROLL+=("phala_app.coordinator")
fi

for app in "${APPS_TO_ROLL[@]}"; do
  echo "=== applying ${app} ==="
  terraform apply -auto-approve -target="${app}"
  echo "=== waiting for cluster to settle ==="
  if ! wait_for_quorum_healthy "$EXPECTED"; then
    echo "ERROR: cluster did not return to all-alive within ${HEALTH_TIMEOUT_SECONDS}s after ${app}" >&2
    echo "snapshot saved at start of rollout; restore via consul snapshot restore" >&2
    exit 1
  fi
  echo "=== ${app}: green ==="
done

echo "rollout complete; final state:"
curl -sf "${CONSUL_BASE}/v1/agent/members" | jq -r '.[] | .Name + " " + (.Status|tostring)'
