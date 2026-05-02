# Stage 4 — Developer-experience overhaul (revised)

## What changed in this revision

After a first round, four user decisions reshape this plan:

1. **No new CLI.** Use the official
   [`Phala-Network/terraform-provider-phala`](https://github.com/Phala-Network/terraform-provider-phala)
   instead. Avoids "yet another tool" and inherits the standard Terraform
   workflow (plan / apply / state / etc.).
2. **No human in the secret path.** Gossip key, TURN secret, and any
   future shared cluster keys are **derived inside each TEE** via
   `dstack-sdk getKey()`. The deploy host never holds them in cleartext;
   they exist only inside the CVMs that derive them.
3. **Multi-server Consul** is necessary, but landing it is the *next*
   stage after the dev-experience overhaul. Once shipped, **the
   service-mesh members discover the hole-punch / control-plane
   endpoints from Consul itself** — the control plane self-bootstraps
   via the catalog, removing one more hardcoded address from the
   topology.
4. **In-place updates** that preserve CVM disk volumes (Consul KV,
   webdemo state, future Patroni WAL, etc.).

This document supersedes the first revision.

## The whole stage in one paragraph

Operators write **one `cluster.tf`** describing peers, ports, and
intentions. They `terraform apply`. The Phala provider creates one
`phala_app` per peer-role; all peers share an `app_id` (via
`custom_app_id` + a per-cluster nonce), so every TEE derives the same
gossip / TURN secret via `getKey()` without those keys ever leaving
the CVM. Workers boot, mesh-conn handshakes through the embedded
coordinator, Consul forms its cluster. A small `cluster-init` job
(also a Terraform resource) materialises the intentions in Consul.
Re-running `apply` after a code change updates the existing CVMs in
place; volumes survive.

## `cluster.tf` skeleton

Single source of truth for the cluster. Pure HCL.

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    phala = {
      source  = "phala-network/phala"
      version = ">= 0.2"
    }
    consul = {
      source  = "hashicorp/consul"
      version = ">= 2.20"
    }
  }
}

provider "phala" {}

# ---------- Cluster-wide knobs ----------

locals {
  cluster_name = "demo"

  # Ordered protocol slots used by mesh-conn.
  # Index `i` is the same protocol across peers; the per-peer port for
  # protocol[i] is `base + peer_index`.
  protocols = [
    { name = "serf_lan",       base = 18000 },
    { name = "server_rpc",     base = 18100 },
    { name = "http_api",       base = 18200 },
    { name = "grpc",           base = 18300 },
    { name = "webdemo",        base = 18500 },
    { name = "sidecar_public", base = 18600 },
  ]

  peers = [
    { id = "ctrl", role = "server", index = 0 },
    { id = "w1",   role = "client", index = 1 },
    { id = "w2",   role = "client", index = 2 },
    { id = "w3",   role = "client", index = 3 },
  ]

  # PEERS_JSON is identical on every peer (validated at mesh-conn
  # startup; digest must match across all peers' logs).
  peers_json = jsonencode([
    for p in local.peers : {
      id    = p.id
      ports = [for proto in local.protocols : proto.base + p.index]
    }
  ])

  # AppAuth shared across every peer in this cluster: same app-id =>
  # every peer's getKey() returns the same value. Computed
  # deterministically from a per-cluster nonce so re-applies are
  # reproducible.
  cluster_nonce = 1   # bump to rotate the entire cluster's identity
}

# ---------- Bootstrap coordinator (embedded mode) ----------

# The "ctrl" peer doubles as the rendezvous: it runs Consul server +
# coturn + signaling. Its compose template is different from workers'
# — see compose/control.yaml.
resource "phala_app" "ctrl" {
  name           = "${local.cluster_name}-ctrl"
  size           = "tdx.small"
  region         = "US-WEST-1"
  custom_app_id  = local.cluster_app_id
  nonce          = local.cluster_nonce
  docker_compose = file("${path.module}/compose/control.yaml")

  # Non-secret env. Secrets are derived inside the TEE via getKey().
  env = {
    PEER_ID            = "ctrl"
    ROLE               = "server"
    PEERS_JSON         = local.peers_json
    SERF_LAN_PORT      = 18000
    SERVER_PORT        = 18100
    HTTP_PORT          = 18200
    GRPC_PORT          = 18300
    SIDECAR_PORT       = 18600
    CTRL_SERF_LAN_PORT = 18000
  }

  wait_for_ready = true
}

# ---------- Worker peers ----------

resource "phala_app" "worker" {
  for_each = { for p in local.peers : p.id => p if p.role == "client" }

  name           = "${local.cluster_name}-${each.value.id}"
  size           = "tdx.small"
  region         = "US-WEST-1"
  custom_app_id  = local.cluster_app_id
  nonce          = local.cluster_nonce
  docker_compose = file("${path.module}/compose/worker.yaml")

  env = {
    PEER_ID             = each.value.id
    ROLE                = "client"
    PEERS_JSON          = local.peers_json
    SERF_LAN_PORT       = 18000 + each.value.index
    SERVER_PORT         = 18100 + each.value.index
    HTTP_PORT           = 18200 + each.value.index
    GRPC_PORT           = 18300 + each.value.index
    WEBDEMO_PORT        = 18500 + each.value.index
    SIDECAR_PORT        = 18600 + each.value.index
    CTRL_SERF_LAN_PORT  = 18000

    # Bootstrap-only: the gateway URL of ctrl's signaling broker.
    # Once Consul catalog is populated, mesh-conn re-resolves the
    # coordinator endpoints from there.
    SIGNALING_URL = "http://${phala_app.ctrl.app_id}.${var.gateway_domain}:7000"
    TURN_HOST     = "${phala_app.ctrl.app_id}.${var.gateway_domain}"
  }

  depends_on = [phala_app.ctrl]
}

# ---------- Network policy ----------

provider "consul" {
  # Reach the cluster's Consul HTTP API through the dstack gateway,
  # using a Connect-CA-issued client cert (see compose/control.yaml).
  address = "${phala_app.ctrl.app_id}-18200s.${var.gateway_domain}:443"
  scheme  = "https"
}

resource "consul_intention" "webdemo_to_webdemo" {
  source_name      = "webdemo"
  destination_name = "webdemo"
  action           = "allow"

  depends_on = [phala_app.ctrl, phala_app.worker]
}
```

The whole topology is **declarative**. To add a peer: append to
`local.peers`, `terraform apply`. To add an intention: drop another
`consul_intention` resource. To rotate cluster identity: bump
`cluster_nonce`, `terraform apply` (CVMs get new app_id, KMS keys
rotate).

## TEE-only secrets via `getKey()`

The deploy host (and Terraform state) **never** see the gossip key or
TURN shared secret. They are derived inside each TEE at startup:

```
+---------------------------+
|  CVM (TEE)                |
|                           |
|  init container           |
|   ├── reads /var/run/     |
|   │       dstack.sock     |
|   ├── derives secrets:    |
|   │     gossip = getKey("dstack-mesh:gossip")
|   │     turn   = getKey("dstack-mesh:turn")
|   │     ca-pwd = getKey("dstack-mesh:connect-ca")
|   ├── writes to tmpfs:    |
|   │     /run/secrets/*    |
|   └── exits               |
|                           |
|  consul, mesh-conn, sidecar
|  read /run/secrets/* on   |
|  startup                  |
+---------------------------+
```

Both peers in a cluster share the same `app_id` (via `custom_app_id`
+ deterministic nonce), so `getKey()` returns the same bytes on every
peer for the same input string. No coordination needed; no shared
secret is ever transmitted.

The init container is a tiny Go program (~100 LoC). Adds one new
service to each compose:

```yaml
services:
  bootstrap-secrets:
    image: ${BOOTSTRAP_IMAGE}
    network_mode: host
    volumes:
      - /var/run/dstack.sock:/var/run/dstack.sock:ro
      - run-secrets:/run/secrets
    restart: "no"          # one-shot; tmpfs persists for sibling services
  consul:
    # ...
    volumes:
      - run-secrets:/run/secrets:ro
    environment:
      - GOSSIP_KEY_FILE=/run/secrets/gossip   # consul agent supports
                                              # reading -encrypt from a
                                              # file; same for TLS keys
volumes:
  run-secrets:
    driver: local
    driver_opts:
      type: tmpfs
      device: tmpfs
```

(Consul agent has `-encrypt` flag — but reading from a file is
supported via `-encrypt-key-file` or HCL `encrypt = "@/run/secrets/gossip"`.)

The bootstrap container also generates the **Consul Connect CA root
seed** the same way — so the mTLS CA is itself rooted in a TEE-derived
secret, not in a Terraform-provided value.

## Multi-server Consul as the next stage (and what it unlocks)

When we add servers (next stage), the `phala_app.ctrl` resource gets
`replicas = 3`, or we split into three named control resources. All
three share the same compose hash and `app_id`, so KMS-derived
secrets remain identical and Connect CA still bootstraps from
`getKey("dstack-mesh:connect-ca")` on any one of them and replicates
via Raft.

That gives us a **self-discovering control plane**:

1. Each control CVM registers itself with the cluster as a service:
   - service `mesh-coordinator`, address `127.0.0.1:7000` (signaling)
   - service `mesh-turn`, address `127.0.0.1:3478`
2. New peers booting up know **one** initial control endpoint
   (hardcoded in cluster.tf bootstrap env). After their mesh-conn
   joins via that endpoint and Consul has gossiped, they call
   `consul.health.service("mesh-coordinator", passing_only: true)`
   and update their own coordinator list to **all** healthy control
   nodes. From then on, mesh-conn rotates coordinators on its own.
3. Adding/removing a control node is a Terraform diff on
   `replicas`. New peers immediately discover it via Consul; existing
   peers learn through gossip-propagated catalog updates.

The structural payoff: **the topology of the rendezvous infra is
itself a service-mesh-managed concern.** No external configuration,
no client-side hardcoding beyond the bootstrap.

## In-place updates that preserve data

Phala apps' disk volumes survive compose updates (this is what
"upgrade an existing CVM" is for in `phala deploy --cvm-id`). The
provider exposes this through Terraform's standard update path — a
diff in `docker_compose` or `env` triggers an in-place patch, NOT a
recreate.

Concretely:

- `phala_app.ctrl` and each `phala_app.worker` keep a stable
  identity across `terraform apply` cycles unless something
  identity-bound changes (`custom_app_id`, `nonce`, `kms`, ...). The
  underlying CVM's disk volumes — Consul Raft state, KV, sidecar
  certs, future Patroni WAL — are untouched.
- Compose / env changes propagate by stopping the affected
  containers, swapping to the new image / env, restarting. The
  container's volumes (`consul-data`, etc.) are remounted unchanged.
- For **rolling control-plane updates** (when we have 3 servers
  next stage), Terraform's `create_before_destroy` lifecycle on the
  set of control resources, combined with an explicit `terraform
  apply -target=phala_app.ctrl[N]` per node, gives a per-node
  rollout. `consul info` health-checks gate each step.

What this rules out:

- **Bumping `custom_app_id` or `nonce`** rotates the cluster's
  identity. KMS keys change; Connect CA re-roots; gossip key
  changes. Useful for incident response, but disruptive — should
  always be a deliberate operator action, not an accidental side
  effect of editing the file.
- **Changing the compose template structure** (e.g., new services,
  different volumes) is fine for env / image bumps but a fundamental
  rewrite is closer to a fresh deploy than an update.

## Compose template story

Two templates:

- `compose/control.yaml` — runs `mesh-conn`, `consul agent -server`,
  `coturn`, `signaling`, `bootstrap-secrets`, plus the `webdemo` if
  we want symmetry with workers.
- `compose/worker.yaml` — runs `mesh-conn`, `consul agent` (client),
  `webdemo`, `sidecar` (Envoy), `bootstrap-secrets`.

Templates are **frozen** between revisions. Their compose hash is
the audit surface for what runs in the TEE. A revision bumps the
template path and `cluster_nonce` together so the change is
intentional.

## "Embedded vs external" coordinator — still in the plan

The `compose/control.yaml` includes `coturn` + `signaling`. That's
embedded mode. Requires Phala admin to enable UDP ingress on the
control app (3478/UDP, 49152-49999/UDP — ports configurable).

Until that switch is flipped (or for clusters that prefer external
infra), an alternate `compose/control-external.yaml` strips the
coturn + signaling services and the operator brings up a coordinator
host themselves. cluster.tf chooses which to mount via a
`coordinator_mode` variable. No code changes elsewhere.

## Punch-list mapping

The original ROBUSTNESS.md punch list folds into stage 4 cleanly:

- ✅ #1 (reconnect bug) — already shipped pre-stage-4.
- ✅ #2 gossip key — already shipped, but stage 4 moves it to
   TEE-derived (no human in path).
- ⏳ #3 multi-server Consul — explicit next-stage after #4.
- ✅ #4 PEERS_JSON validation — already shipped.
- ⏳ #5 real registry — stage 4 default (no more `ttl.sh`).
- ⏳ #6 two coordinators + signed signalling — covered by
   self-discovery once multi-server lands.
- ⏳ #7 mesh-conn integration test — stage 4 CI.
- ⏳ #8 metrics — stage 4 follow-up.

## What's actually being built in stage 4

In rough order:

1. `compose/control.yaml` and `compose/worker.yaml` — frozen
   templates, replacing the per-stage forks (stage1/stage2/stage3a/
   stage3b composes become reference-only).
2. `bootstrap-secrets` init container (~100 LoC Go, mounts
   dstack.sock, derives keys, writes tmpfs).
3. `cluster.tf` example pinned to one specific cluster ("demo"),
   plus a Terraform module so other clusters reuse the topology
   logic without copy-paste.
4. CI: a Terraform-plan + `mesh-conn` integration test running
   peers in containers locally (no CVMs needed for everything below
   the network).
5. Migration note in repo README: "stages 0–3b are the
   step-by-step build-up; stage 4 is the integrated product."
6. **Smoke test**: `terraform apply` on a fresh AWS-style account,
   wait for `consul members` to be all-alive, hit `/all` from a
   worker — same checks we've been running by hand.

## Open items

- The Phala Terraform provider is at `0.2.0-beta.1` as of the
  March 2026 release we found. Need to confirm `replicas`,
  `encrypted_env`, in-place env update, and `custom_app_id` work
  the way the schema implies before betting the dev-ex on it.
- Embedded coturn + UDP ingress is admin-gated on Phala. Until
  enabled, default cluster.tf uses external coordinator mode.
- The "self-discovering coordinator" loop in mesh-conn (peer asks
  Consul for the live coordinator list) is a small mesh-conn
  addition (~80 LoC) — fits in the multi-server stage, not stage 4.
