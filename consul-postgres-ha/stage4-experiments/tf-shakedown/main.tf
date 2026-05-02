# Phala Cloud terraform-provider-phala shakedown.
#
# Goal: feel out the provider's behaviour BEFORE committing the stage-4
# dev-experience to it. Things we need to verify hold:
#   - basic phala_app create / read / update / destroy works
#   - in-place compose/env update keeps the same app_id and disk volumes
#   - custom_app_id + nonce produces a deterministic app_id we can pin
#   - replicas works the way the schema implies
#   - encrypted_env actually encrypts values

terraform {
  required_version = ">= 1.5"
  required_providers {
    phala = {
      source  = "phala-network/phala"
      version = "0.2.0-beta.2"
    }
  }
}

provider "phala" {
  # api_key sourced from PHALA_CLOUD_API_KEY env var (set by run.sh)
}

variable "experiment_tag" {
  description = "Suffix appended to the app name; bump for a fresh deploy"
  type        = string
}

variable "compose_version" {
  description = "Toggle to test in-place updates"
  type        = string
  default     = "v1"
}

resource "phala_app" "shakedown" {
  name      = "tf-shakedown-${var.experiment_tag}"
  size       = "tdx.small"
  region     = "US-WEST-1"
  disk_size  = 20
  replicas   = 2     # bumped from 1 to test replica scaling
  # Pin storage_fs explicitly. If unset, plan reads it back as "zfs"
  # then treats the next apply as ForceNew → would destroy the CVM.
  # Worth flagging in the stage-4 doc as a provider gotcha.
  storage_fs = "zfs"

  # KMS auto-issues an app_id for us. (We'll test custom_app_id +
  # nonce in a separate file once we know the basic path works.)

  docker_compose = <<-YAML
    services:
      hello:
        image: nginx:1.27-alpine
        environment:
          - VERSION=${var.compose_version}
        ports:
          - "8080:80"
  YAML

  env = {
    EXAMPLE_ENV = "set-by-terraform-${var.compose_version}"
  }

  listed         = false
  public_logs    = true
  public_sysinfo = false

  wait_for_ready       = true
  wait_timeout_seconds = 600
}

output "app_id" {
  value = phala_app.shakedown.app_id
}

output "primary_cvm_id" {
  value = phala_app.shakedown.primary_cvm_id
}

output "endpoint" {
  value = phala_app.shakedown.endpoint
}

output "status" {
  value = phala_app.shakedown.status
}
