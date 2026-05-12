# Example cluster — peer-VIP / service-VIP layout.
#
# This whole HCL file IS the cluster definition. To bring up an
# HA Postgres + webdemo cluster on dstack:
#
#   PHALA_CLOUD_API_KEY=$(your token) terraform apply -parallelism=1
#
# Adding a worker is a `replicas` bump on phala_app.worker; terraform
# apply propagates the new PEERS_JSON to every CVM via in-place env
# update (no destroy/recreate; disks survive).

terraform {
  required_version = ">= 1.5"
  required_providers {
    phala = {
      source = "phala-network/phala"
      # 0.2.0-beta.3 is the first version where in-place env-block
      # updates actually take effect — earlier betas silently no-op'd
      # them (Phala-Network/phala-cloud#246, fixed in
      # Phala-Network/terraform-provider-phala#8). Pin exactly because
      # Terraform's `>=` operator doesn't include later prerelease
      # versions; bump this line by hand when a newer beta ships.
      version = "0.2.0-beta.3"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}

provider "phala" {}

# ---------- Cluster-wide shared secrets (WORKAROUND) ----------
#
# These three secrets MUST be byte-identical across every CVM that
# joins the cluster (gossip auth, Patroni replication, Patroni superuser).
# The principled answer is "derive them in the TEE, never let a human
# touch them" — but each phala_app in this cluster has its own app_id
# (one resource per CVM, deliberate; see the for_each comments on
# phala_app.coordinator/worker) and dstack's GetKey() is rooted at
# app_id, so per-CVM derivation produces DIFFERENT bytes on each peer.
#
# Until attestation-rooted admission lands (see
# `consul-postgres-ha/design/attestation-admission.md`), we generate
# them in Terraform and hand the same bytes to every phala_app via
# env. Trade-off accepted: anyone with read access to terraform.tfstate
# (or the apply host's memory) sees plaintext keys. The attestation
# work closes this.
#
# Connect CA root is NOT in this list — Consul's built-in CA provider
# generates the root in Raft on first quorum, no external derivation
# required and no per-CVM problem.
resource "random_bytes" "gossip_key" {
  length = 32
}
resource "random_bytes" "patroni_superuser_pw" {
  length = 32
}
resource "random_bytes" "patroni_replication_pw" {
  length = 32
}

# ---------- Cluster knobs ----------

variable "cluster_name" {
  type    = string
  default = "demo"
}

variable "coordinator_replicas" {
  type        = number
  default     = 3
  description = "Number of voting Consul-server CVMs. 3 gives fault tolerance of 1; 5 of 2."
}

variable "worker_replicas" {
  type    = number
  default = 3
}

variable "gateway_domain" {
  type        = string
  description = "Phala dstack gateway domain (e.g. dstack-pha-prod5.phala.network)"
}

# Image references. The mesh_sidecar image bundles
# bootstrap-secrets, mesh-conn, consul agent, and envoy; workers and
# coordinators both reference it and the entrypoint dispatches on ROLE.
variable "mesh_sidecar_image" { type = string }
variable "webdemo_image" { type = string }
variable "patroni_image" { type = string }

# External coordinator (Vultr coturn + signaling box). Used until
# Phala admin enables UDP ingress on dstack apps; once that lands we
# can host coturn + signaling inside the dstack mesh and drop these
# external_* vars.
variable "external_coordinator_host" { type = string }
variable "external_signaling_url" { type = string }
variable "external_turn_secret" {
  type      = string
  sensitive = true
}

# Force ICE to gather Relay candidates only — routes all peer traffic
# through coturn instead of attempting NAT-hairpin direct paths. Set
# this when worker↔worker direct-pair ICE handshakes are unstable
# (the dstack provider NAT path is known-flaky for these pairs).
variable "mesh_conn_relay_only" {
  type    = string
  default = ""
}

# Set to "1" to enable pion's verbose ICE debug logs (connectivity
# checks, STUN attribute parsing). Useful when debugging hot-patch
# / re-handshake flakiness; off by default because it's very chatty.
variable "mesh_conn_debug_ice" {
  type    = string
  default = ""
}

# ---------- Cluster topology + VIP allocation ----------

locals {
  # Peer VIPs: 127.50.0.<vip>/32. Allocated as ordinal+1 (so vip=1
  # for the first coordinator, never 0 — the validate_test in
  # mesh-conn rejects vip=0). PEERS_JSON shape: [{id, vip}], same
  # on every CVM. mesh-conn binds the static infra-port allowlist
  # ({21000, 21001, 8300, 8301}) on every other peer's VIP.
  peers = concat(
    [
      for i in range(var.coordinator_replicas) : {
        id      = "coordinator-${i}"
        ordinal = i
        role    = "coordinator"
        vip     = i + 1
      }
    ],
    [
      for i in range(var.worker_replicas) : {
        id      = "worker-${i + var.coordinator_replicas}"
        ordinal = i + var.coordinator_replicas
        role    = "worker"
        vip     = i + var.coordinator_replicas + 1
      }
    ],
  )

  peers_json = jsonencode([
    for p in local.peers : { id = p.id, vip = p.vip }
  ])

  # COORDINATOR_VIPS — comma-separated for serf retry-join.
  coordinator_vips = join(",", [for p in local.peers : tostring(p.vip) if p.role == "coordinator"])

  # Service VIPs: 127.10.0.<vip>/32 — one per Connect upstream a
  # worker consumes. Three services in this template (extend by
  # adding entries here + Connect upstreams in the sidecar config):
  #   webdemo          for the cross-peer fan-out demo
  #   postgres-master  the Patroni leader, leader-aware via subset filter
  #   postgres-replica any Patroni replica
  service_vips = [
    { name = "webdemo", vip = 10, port = 8080 },
    { name = "postgres-master", vip = 20, port = 5432 },
    { name = "postgres-replica", vip = 21, port = 5432 },
  ]
  upstreams_json = jsonencode(local.service_vips)
}

# ---------- Coordinator ----------

resource "phala_app" "coordinator" {
  # One phala_app per coordinator (with replicas:1) — same per-resource
  # ordinal pattern as workers, same chicken-and-egg sidestep
  # (bootstrap-secrets needs to know its own ordinal before Consul is
  # reachable, since Consul is on the coordinators themselves).
  for_each = { for i in range(var.coordinator_replicas) : tostring(i) => i }

  name           = "${var.cluster_name}-coordinator-${each.key}"
  size           = "tdx.small"
  region         = "US-WEST-1"
  disk_size      = 20
  replicas       = 1
  storage_fs     = "zfs" # MUST pin (terraform-provider-phala#5)
  docker_compose = file("${path.module}/../compose/coordinator.yaml")

  env = {
    CLUSTER_NAME        = var.cluster_name
    PEERS_JSON          = local.peers_json
    COORDINATOR_ORDINAL = tostring(each.value)
    BOOTSTRAP_EXPECT    = tostring(var.coordinator_replicas)
    COORDINATOR_VIPS    = local.coordinator_vips
    SIGNALING_URL       = var.external_signaling_url
    TURN_HOST           = var.external_coordinator_host
    TURN_SHARED_SECRET  = var.external_turn_secret
    MESH_SIDECAR_IMAGE  = var.mesh_sidecar_image
    # WORKAROUND — see `random_bytes` block at top of file.
    GOSSIP_KEY           = random_bytes.gossip_key.base64
    MESH_CONN_RELAY_ONLY = var.mesh_conn_relay_only
    MESH_CONN_DEBUG_ICE  = var.mesh_conn_debug_ice
  }

  listed         = false
  public_logs    = true
  public_sysinfo = false

  wait_for_ready       = true
  wait_timeout_seconds = 600
}

# ---------- Workers ----------

resource "phala_app" "worker" {
  # One phala_app per worker (with replicas:1) instead of a single
  # app with replicas:N. Reason: each worker needs its OWN ordinal
  # passed in via env so bootstrap-secrets can write the correct
  # /run/instance/info.json without a Consul KV CAS round-trip.
  for_each = { for i in range(var.worker_replicas) : tostring(i + 1) => i + var.coordinator_replicas }

  name           = "${var.cluster_name}-worker-${each.key}"
  size           = "tdx.small"
  region         = "US-WEST-1"
  disk_size      = 20
  replicas       = 1
  storage_fs     = "zfs"
  docker_compose = file("${path.module}/../compose/worker.yaml")

  env = {
    CLUSTER_NAME       = var.cluster_name
    PEERS_JSON         = local.peers_json
    UPSTREAMS_JSON     = local.upstreams_json
    WORKER_ORDINAL     = tostring(each.value)
    EXPECTED_REPLICAS  = var.worker_replicas + var.coordinator_replicas
    COORDINATOR_VIPS   = local.coordinator_vips
    SIGNALING_URL      = var.external_signaling_url
    TURN_HOST          = var.external_coordinator_host
    TURN_SHARED_SECRET = var.external_turn_secret
    MESH_SIDECAR_IMAGE = var.mesh_sidecar_image
    WEBDEMO_IMAGE      = var.webdemo_image
    PATRONI_IMAGE      = var.patroni_image
    # WORKAROUND — see `random_bytes` block at top of file.
    GOSSIP_KEY             = random_bytes.gossip_key.base64
    PATRONI_SUPERUSER_PW   = random_bytes.patroni_superuser_pw.hex
    PATRONI_REPLICATION_PW = random_bytes.patroni_replication_pw.hex
    MESH_CONN_RELAY_ONLY   = var.mesh_conn_relay_only
    MESH_CONN_DEBUG_ICE    = var.mesh_conn_debug_ice
  }

  listed         = false
  public_logs    = true
  public_sysinfo = false

  wait_for_ready       = true
  wait_timeout_seconds = 600

  depends_on = [phala_app.coordinator]
}

output "coordinator_app_ids" { value = { for k, c in phala_app.coordinator : k => c.app_id } }
output "worker_app_ids" { value = { for k, w in phala_app.worker : k => w.app_id } }
output "consul_ui" {
  # Coordinator-0's Consul HTTP API on the canonical 8500. Plain HTTP
  # backend → use the no-`s` gateway form (gateway terminates TLS).
  # See README "dstack gateway URL convention".
  value = "https://${phala_app.coordinator["0"].app_id}-8500.${var.gateway_domain}/ui"
}
