# Disk-persistence test for in-place phala_app updates.
#
# Stage 4's design assumes that the on-disk state of a CVM survives
# in-place compose/env updates (so each instance can persist its
# identity + Consul Raft state + Patroni WAL). Verify empirically:
#
#   1. Apply v1: container writes a unique marker to a named volume
#      if not present, then serves it via nginx.
#   2. curl the marker — record value M1.
#   3. Bump `compose_marker` variable (changes startup script body
#      but keeps marker-write logic conditional). Apply.
#   4. Wait for container restart, curl again — value M2.
#   5. M1 == M2 => disk survived. M1 != M2 => disk wiped.

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

variable "experiment_tag" {
  type = string
}

variable "compose_marker" {
  description = "Toggle to force an in-place compose change between applies"
  type        = string
  default     = "v1"
}

resource "phala_app" "disk" {
  name       = "disk-persist-${var.experiment_tag}"
  size       = "tdx.small"
  region     = "US-WEST-1"
  disk_size  = 20
  replicas   = 1
  storage_fs = "zfs"

  docker_compose = <<-YAML
    # compose-marker: ${var.compose_marker}     (bump to trigger update)
    services:
      marker:
        image: nginx:1.27-alpine
        restart: unless-stopped
        volumes:
          - data:/usr/share/nginx/html
        command:
          - "sh"
          - "-c"
          - |
            if [ ! -f /usr/share/nginx/html/marker.txt ]; then
              MARKER="$(date +%s%N)-$$$$"
              echo "$MARKER" > /usr/share/nginx/html/marker.txt
              echo "wrote new marker: $MARKER"
            else
              echo "marker already present (size=$(wc -c < /usr/share/nginx/html/marker.txt))"
            fi
            exec nginx -g 'daemon off;'
        ports:
          - "8080:80"
    volumes:
      data:
  YAML

  listed         = false
  public_logs    = true
  public_sysinfo = false

  wait_for_ready       = true
  wait_timeout_seconds = 600
}

output "app_id"   { value = phala_app.disk.app_id }
output "endpoint" { value = phala_app.disk.endpoint }
