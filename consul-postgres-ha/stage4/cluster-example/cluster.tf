# Stage 4 — example cluster.
#
# This whole HCL file IS the cluster definition. To bring up a 4-instance
# Consul + Connect mesh on dstack:
#
#   PHALA_CLOUD_API_KEY=$(your token) terraform apply
#
# Adding a worker is a `replicas` bump on phala_app.worker; terraform
# apply propagates the new PEERS_JSON to every CVM via in-place env
# update (no destroy/recreate; disks survive — verified in
# stage4-experiments/disk-persistence/).

terraform {
  required_version = ">= 1.5"
  required_providers {
    phala = {
      source = "phala-network/phala"
      # >= 0.2.0-beta.3 is required for in-place env-block updates to
      # actually take effect — earlier versions silently no-op'd them
      # (Phala-Network/phala-cloud#246, fixed in
      # Phala-Network/terraform-provider-phala#8).
      version = ">= 0.2.0-beta.3"
    }
  }
}

provider "phala" {}

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

variable "bootstrap_secrets_image" { type = string }
variable "mesh_conn_image"         { type = string }
variable "signaling_image"         { type = string }
variable "webdemo_image"           { type = string }
variable "sidecar_image"           { type = string }
variable "patroni_image"           { type = string }

# External coordinator (Vultr coturn + signaling box) used until
# Phala admin enables UDP ingress on dstack apps. coordinator's own
# coturn + signaling services in compose still run but are unused.
variable "external_coordinator_host" { type = string }
variable "external_signaling_url"    { type = string }
variable "external_turn_secret" {
  type      = string
  sensitive = true
}

# ---------- Protocol port plan ----------

locals {
  # Index i is the same protocol on every peer; the per-peer port for
  # protocol `name` at ordinal `n` is base + n. mesh-conn reads
  # /run/instance/info.json for this peer's actual ports (computed by
  # bootstrap-secrets from PROTOCOL_BASES + the ordinal it claimed).
  protocol_bases = {
    serf_lan       = 18000
    server_rpc     = 18100
    http_api       = 18200
    grpc           = 18300
    webdemo        = 18500
    sidecar_public = 18600
    postgres       = 18700 # Patroni-managed PostgreSQL listen
    patroni_rest   = 18800 # Patroni REST API (peer health, leader query)
  }

  # The full peer list, identical on every CVM. Coordinators occupy
  # ordinals 0..C-1 (where C = coordinator_replicas), workers fill
  # ordinals C..C+W-1. PEERS_JSON is what mesh-conn consumes; the
  # role-ordinal pair is what each peer self-identifies as in its
  # bootstrap-secrets-derived /run/instance/info.json (mesh-conn then
  # reads "<role>-<ordinal>" as its self ID).
  peers = concat(
    [
      for i in range(var.coordinator_replicas) : {
        id      = "coordinator-${i}"
        ordinal = i
        role    = "coordinator"
      }
    ],
    [
      for i in range(var.worker_replicas) : {
        # ID must match mesh-conn's self_id, which is `role-ordinal`,
        # NOT slot. Workers occupy ordinals C..C+W-1.
        id      = "worker-${i + var.coordinator_replicas}"
        ordinal = i + var.coordinator_replicas
        role    = "worker"
      }
    ],
  )

  peers_json = jsonencode([
    for p in local.peers : {
      id    = p.id
      ports = [for proto, base in local.protocol_bases : base + p.ordinal]
    }
  ])

  protocol_bases_json = jsonencode(local.protocol_bases)

  # Comma-separated lists of coordinator-ordinal-shifted ports. Workers
  # use COORDINATOR_SERF_PORTS to retry-join EVERY coordinator, and
  # COORDINATOR_HTTP_PORTS to pick ANY coordinator's HTTP API for
  # KV-CAS bootstrapping. Coordinators use COORDINATOR_SERF_PORTS to
  # gossip-join their server peers (consul -bootstrap-expect=N).
  coordinator_serf_ports = join(",", [for i in range(var.coordinator_replicas) : tostring(local.protocol_bases.serf_lan + i)])
  coordinator_http_ports = join(",", [for i in range(var.coordinator_replicas) : tostring(local.protocol_bases.http_api + i)])

  # First coordinator's HTTP port — used as a single endpoint for the
  # consul-ui output and for legacy single-coord callers.
  coordinator_http_port_first = local.protocol_bases.http_api + 0
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
  storage_fs     = "zfs"   # MUST pin (terraform-provider-phala#5)
  docker_compose = file("${path.module}/../compose/coordinator.yaml")

  env = {
    CLUSTER_NAME             = var.cluster_name
    PROTOCOL_BASES           = local.protocol_bases_json
    PEERS_JSON               = local.peers_json
    COORDINATOR_ORDINAL      = tostring(each.value)
    BOOTSTRAP_EXPECT         = tostring(var.coordinator_replicas)
    COORDINATOR_SERF_PORTS   = local.coordinator_serf_ports
    SIGNALING_URL            = var.external_signaling_url
    TURN_HOST                = var.external_coordinator_host
    TURN_SHARED_SECRET       = var.external_turn_secret
    BOOTSTRAP_SECRETS_IMAGE  = var.bootstrap_secrets_image
    MESH_CONN_IMAGE          = var.mesh_conn_image
    SIGNALING_IMAGE          = var.signaling_image
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
  # The CAS path has a chicken-and-egg: workers need Consul to
  # claim an ordinal, but Consul (on the coordinator) is reached
  # via mesh-conn, which depends on bootstrap-secrets having
  # finished. Per-worker resources sidestep this entirely.
  #
  # Once phala-cloud#243 lands phala_app_instance + per-instance
  # env, this reverts to one resource with replicas:N + per-instance
  # env block.
  # Key is the worker's 1-based slot (used in the CVM name); value is
  # the cluster-wide ordinal (= slot + coordinator_replicas, since
  # coordinators occupy ordinals 0..C-1).
  for_each = { for i in range(var.worker_replicas) : tostring(i + 1) => i + var.coordinator_replicas }

  name           = "${var.cluster_name}-worker-${each.key}"
  size           = "tdx.small"
  region         = "US-WEST-1"
  disk_size      = 20
  replicas       = 1
  storage_fs     = "zfs"
  docker_compose = file("${path.module}/../compose/worker.yaml")

  env = {
    CLUSTER_NAME             = var.cluster_name
    PROTOCOL_BASES           = local.protocol_bases_json
    PEERS_JSON               = local.peers_json
    WORKER_ORDINAL           = tostring(each.value)
    EXPECTED_REPLICAS        = var.worker_replicas + var.coordinator_replicas
    COORDINATOR_SERF_PORTS   = local.coordinator_serf_ports
    COORDINATOR_HTTP_PORTS   = local.coordinator_http_ports
    SIGNALING_URL            = var.external_signaling_url
    TURN_HOST                = var.external_coordinator_host
    TURN_SHARED_SECRET       = var.external_turn_secret
    BOOTSTRAP_SECRETS_IMAGE  = var.bootstrap_secrets_image
    MESH_CONN_IMAGE          = var.mesh_conn_image
    WEBDEMO_IMAGE            = var.webdemo_image
    SIDECAR_IMAGE            = var.sidecar_image
    PATRONI_IMAGE            = var.patroni_image
  }

  listed         = false
  public_logs    = true
  public_sysinfo = false

  wait_for_ready       = true
  wait_timeout_seconds = 600

  depends_on = [phala_app.coordinator]
}

output "coordinator_app_ids" { value = { for k, c in phala_app.coordinator : k => c.app_id } }
output "worker_app_ids"      { value = { for k, w in phala_app.worker : k => w.app_id } }
output "consul_ui" {
  # Any coordinator's HTTP port serves the UI. Pick coord-0 by convention.
  value = "https://${phala_app.coordinator["0"].app_id}-${local.coordinator_http_port_first}s.${var.gateway_domain}/ui"
}
