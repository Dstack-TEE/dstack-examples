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
      source  = "phala-network/phala"
      version = "0.2.0-beta.2"
    }
  }
}

provider "phala" {}

# ---------- Cluster knobs ----------

variable "cluster_name" {
  type    = string
  default = "demo"
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
  }

  # The full peer list, identical on every CVM. Coordinator is always
  # ordinal 0; workers fill ordinals 1..N. PEERS_JSON is what mesh-conn
  # consumes; the role-ordinal pair is what each peer self-identifies as
  # in its bootstrap-secrets-derived /run/instance/info.json (mesh-conn
  # then reads "<role>-<ordinal>" as its self ID).
  peers = concat(
    [{ id = "coordinator-0", ordinal = 0, role = "coordinator" }],
    [
      for i in range(var.worker_replicas) : {
        id      = "worker-${i + 1}"
        ordinal = i + 1
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

  # Coordinator's own per-protocol ports (ordinal 0, so == base).
  coordinator_serf_port = local.protocol_bases.serf_lan + 0
  coordinator_http_port = local.protocol_bases.http_api + 0
}

# ---------- Coordinator ----------

resource "phala_app" "coordinator" {
  name           = "${var.cluster_name}-coordinator"
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
  name           = "${var.cluster_name}-worker"
  size           = "tdx.small"
  region         = "US-WEST-1"
  disk_size      = 20
  replicas       = var.worker_replicas
  storage_fs     = "zfs"
  docker_compose = file("${path.module}/../compose/worker.yaml")

  env = {
    CLUSTER_NAME             = var.cluster_name
    PROTOCOL_BASES           = local.protocol_bases_json
    PEERS_JSON               = local.peers_json
    EXPECTED_REPLICAS        = var.worker_replicas + 1   # +1 for coordinator slot
    COORDINATOR_HOST         = "${phala_app.coordinator.app_id}.${var.gateway_domain}"
    COORDINATOR_SERF_PORT    = local.coordinator_serf_port
    COORDINATOR_HTTP_PORT    = local.coordinator_http_port
    BOOTSTRAP_SECRETS_IMAGE  = var.bootstrap_secrets_image
    MESH_CONN_IMAGE          = var.mesh_conn_image
    WEBDEMO_IMAGE            = var.webdemo_image
    SIDECAR_IMAGE            = var.sidecar_image
  }

  listed         = false
  public_logs    = true
  public_sysinfo = false

  wait_for_ready       = true
  wait_timeout_seconds = 600

  depends_on = [phala_app.coordinator]
}

output "coordinator_app_id" { value = phala_app.coordinator.app_id }
output "worker_app_id"      { value = phala_app.worker.app_id }
output "consul_ui" {
  value = "https://${phala_app.coordinator.app_id}-${local.coordinator_http_port}s.${var.gateway_domain}/ui"
}
