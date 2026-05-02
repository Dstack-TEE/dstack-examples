# Stage 4 — Developer-experience overhaul (revision 2)

## What's new in this revision

Three things changed since revision 1:

1. **Provider shakedown.** Verified `phala_app` create / in-place
   compose+env update / `replicas: N` / destroy all work; documented
   two gotchas (`storage_fs` ForceNew, `>=` constraint excluding
   pre-release). See `stage4-experiments/tf-shakedown/RESULTS.md`.
2. **dstack's grain is `app -> instance`.** I'd over-modelled stage 4
   as one `phala_app` per peer (which would require AppAuth-shared
   identity to bridge them). The cleaner shape is **one `phala_app`
   per role with `replicas: N`**, leveraging dstack's native
   instance-bound disk + on-disk identity.
3. **Per-instance Terraform resources are not (yet) a thing.** Filed
   [phala-cloud#243](https://github.com/Phala-Network/phala-cloud/issues/243)
   to ask for `phala_app_instance` + `update_policy` + lifecycle
   hooks + `auto_healing`, modelled on GCP MIG / k8s StatefulSet.
   Not a blocker for the architecture testing — see "Rolling updates
   without per-instance resources" below.

This revision keeps the four user-decisions from rev-1 (no new CLI,
TEE-only secrets, multi-server Consul self-discovery, in-place
updates). What changes is **how identity flows**: cluster-wide via
`getKey()`, per-instance via on-disk UUID written on first boot.

## Whole stage in one paragraph

Operators write **one `cluster.tf`**: a `phala_app` per role
(`coordinator`, `consul_server`, `worker`) with `replicas: N`. All
replicas of an app share an `app_id` → all derive identical
cluster-wide secrets via `getKey()` (gossip key, TURN secret,
Connect-CA seed). Each replica reads its **per-instance UUID** from
its persisted disk on boot (writes on first boot). It registers
itself with Consul as a service tagged with its identity-port set;
mesh-conn discovers peers from the catalog instead of from a baked-in
`PEERS_JSON`. `terraform apply` does the deploys; rolling updates run
through a small `rollout.sh` that shells out to workload-aware drain
verbs (consul transfer-leader, etc.) before bumping each replica.
A bootstrap-secrets init container is the only piece that holds key
material in plaintext, and it does so entirely inside the TEE.

## Why one `phala_app` per role + replicas

dstack's native shape is **app → instance**, where each instance:
- has its own persisted disk that survives in-place compose updates,
- carries identity baked into its disk (per the dstack architecture
  the user described),
- shares its parent app's `app_id` (so cluster-wide `getKey()`
  agrees across instances).

This maps 1:1 to GCP MIG / k8s StatefulSet — one resource definition,
N stateful instances under it. Concretely:

```
phala_app.coordinator    replicas = 1   (the embedded coturn + signaling
                                         + Consul server seed; later 3 for HA)
phala_app.consul_server  replicas = 3   (the quorum)
phala_app.worker         replicas = N   (services, can scale freely)
```

vs revision 1 which proposed:

```
phala_app.ctrl   replicas = 1
phala_app.w1     replicas = 1
phala_app.w2     replicas = 1
phala_app.w3     replicas = 1
```

(rev-1 needed each peer to be a separate Terraform resource because
each one needed a different `PEER_ID` env var. Rev-2 doesn't, because
peer identity comes from on-disk UUID.)

## `cluster.tf` skeleton

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    phala = {
      source  = "phala-network/phala"
      version = "0.2.0-beta.2"   # pin exactly; >= excludes pre-release
    }
    consul = {
      source  = "hashicorp/consul"
      version = ">= 2.20"
    }
  }
}

provider "phala" {}

# ---------- Shared cluster knobs ----------

locals {
  cluster_name = "demo"

  # Protocol slot ports: index i is the same protocol across all
  # instances; the per-instance port is computed at runtime by
  # bootstrap-secrets reading the on-disk UUID and looking up its
  # ordinal in Consul (or, for the very first server, using ordinal 0).
  protocol_slots = ["serf_lan", "server_rpc", "http_api", "grpc",
                    "webdemo", "sidecar_public"]
}

# ---------- Coordinator (= initial Consul server + coturn + signaling) ----------

resource "phala_app" "coordinator" {
  name       = "${local.cluster_name}-coordinator"
  size       = "tdx.small"
  region     = "US-WEST-1"
  disk_size  = 20
  replicas   = 1                  # bump to 3 in the multi-server stage
  storage_fs = "zfs"              # MUST pin (provider gotcha #5)

  docker_compose = file("${path.module}/compose/coordinator.yaml")

  env = {
    CLUSTER_NAME    = local.cluster_name
    ROLE            = "coordinator"
    PROTOCOL_SLOTS  = jsonencode(local.protocol_slots)
  }

  wait_for_ready = true
}

# ---------- Workers ----------

resource "phala_app" "worker" {
  name       = "${local.cluster_name}-worker"
  size       = "tdx.small"
  region     = "US-WEST-1"
  disk_size  = 20
  replicas   = 3
  storage_fs = "zfs"

  docker_compose = file("${path.module}/compose/worker.yaml")

  env = {
    CLUSTER_NAME      = local.cluster_name
    ROLE              = "worker"
    PROTOCOL_SLOTS    = jsonencode(local.protocol_slots)

    # The ONLY bootstrap address — every worker reaches the
    # coordinator's gateway URL, learns the live cluster from
    # Consul, then keeps the coordinator list refreshed from the
    # catalog itself. Adding a second coordinator in the future is a
    # `replicas` bump, not a cluster.tf rewrite.
    BOOTSTRAP_COORDINATOR = "${phala_app.coordinator.app_id}.${var.gateway_domain}"
  }

  depends_on = [phala_app.coordinator]
}

# ---------- Network policy ----------

provider "consul" {
  address = "${phala_app.coordinator.app_id}-18200s.${var.gateway_domain}:443"
  scheme  = "https"
}

resource "consul_intention" "webdemo_to_webdemo" {
  source_name      = "webdemo"
  destination_name = "webdemo"
  action           = "allow"
}
```

That's the **whole** topology. Adding a worker is a `replicas` bump
and re-apply.

## TEE-only secrets via `getKey()`

Unchanged from rev-1, except that the bootstrap-secrets init container
now also handles **per-instance identity**:

```
+----------------------------------------------------------+
|  CVM (TEE) — every instance, all roles                  |
|                                                          |
|  bootstrap-secrets init container                       |
|   ├── reads /var/run/dstack.sock                        |
|   │                                                      |
|   ├── derives cluster-wide secrets (same across every   |
|   │   instance of an app, because shared app_id):       |
|   │     gossip = getKey("dstack-mesh:gossip")           |
|   │     turn   = getKey("dstack-mesh:turn")             |
|   │     ca-pwd = getKey("dstack-mesh:connect-ca")       |
|   │                                                      |
|   ├── reads /var/lib/dstack/instance-id (persisted disk)|
|   │     - if file exists: load existing UUID            |
|   │     - if absent (first boot): write a fresh UUID    |
|   │                                                      |
|   ├── decides this instance's port slots:               |
|   │     - asks Consul for current peers tagged          |
|   │       cluster=<CLUSTER_NAME>;                       |
|   │     - claims the lowest unused ordinal (atomic via  |
|   │       Consul KV CAS);                               |
|   │     - writes the ordinal back to disk so it sticks  |
|   │       across reboots                                |
|   │                                                      |
|   ├── writes derived state to tmpfs:                    |
|   │     /run/secrets/gossip                             |
|   │     /run/secrets/turn                               |
|   │     /run/secrets/ca-seed                            |
|   │     /run/instance/uuid                              |
|   │     /run/instance/ordinal                           |
|   │     /run/instance/ports.json                        |
|   │                                                      |
|   └── exits                                             |
|                                                          |
|  consul agent + mesh-conn + sidecar + webdemo            |
|  read /run/secrets/* and /run/instance/* at startup     |
+----------------------------------------------------------+
```

**Key property: the deploy host (and Terraform state) never see any
secret material**, never see any per-instance identity. The init
container is the keystone.

## Peer discovery via Consul (no `PEERS_JSON` env)

Each instance registers itself with the local Consul agent on boot:

```json
{
  "Name": "mesh-peer",
  "ID": "mesh-peer-${UUID}",
  "Tags": [
    "cluster=demo",
    "role=worker",
    "ordinal=2",
    "ports=18002,18102,18202,18302,18502,18602"
  ],
  "Port": 18002
}
```

mesh-conn polls `/v1/health/service/mesh-peer?passing=true`, parses
the tags into the peers list, opens / tears down ICE+yamux pairs as
peers come and go. No baked-in `PEERS_JSON`. **Adding a peer is just
a `replicas` bump — no cluster.tf rewrite.**

The PEERS_JSON validation we shipped in punch-list #4 still applies,
just at runtime against the Consul-fetched view rather than env JSON.

## Rolling updates without per-instance resources

Until phala-cloud#243 lands `phala_app_instance` + `update_policy`,
in-place updates touch all replicas in unspecified order. That's
fine for stateless workers, dangerous for the Consul quorum. The
workaround:

`rollout.sh` lives next to `cluster.tf`:

```
1. terraform plan -refresh-only         # see what would change
2. for app in worker, coordinator (last):
     for each replica:
         (a) drain workload-aware:
                 worker:      consul services deregister  + drain Envoy
                 coordinator: consul operator raft transfer-leader (if leader)
         (b) take snapshot for rollback
                 consul snapshot save snap-${app}-${replica}.snap
         (c) bump that single replica's image / env via the API
                 (today: opaque app-level update; we wait for Phala's
                  per-instance API or use `phala cvms restart <id>`
                  in a controlled order)
         (d) wait for green:
                 consul members | check this replica is alive
                 raft commit_index advancing
                 sidecar ready listeners loaded
         (e) min-ready: 30s of green before next replica
3. terraform apply                       # converge state
```

Until #243 lands the `update_policy` block, this rollout is the
gating layer. Once #243 lands, most of step 2 collapses into the
`update_policy` declarative form.

## Compose templates

Two templates, frozen between revisions (compose hash is the audit
surface):

- **`compose/coordinator.yaml`**: bootstrap-secrets, mesh-conn,
  consul (server, `-bootstrap-expect=1` initially; `-expect=3` when
  multi-server), coturn, signaling, optional webdemo for symmetry.
- **`compose/worker.yaml`**: bootstrap-secrets, mesh-conn, consul
  (client), webdemo, sidecar (Envoy), tester (development only).

A revision bumps the file path AND `cluster_nonce` together so the
change is intentional.

## `bootstrap-secrets` init container — design sketch

A small Go program (~150 LoC) that:

1. Imports `github.com/Dstack-TEE/dstack-sdk-go` for `getKey()`.
2. On startup:
   - Derives `gossip`, `turn`, `ca-seed` keys (32 bytes each, KDF'd
     from `getKey("dstack-mesh:" + role)`).
   - Writes them to `/run/secrets/{name}` (mode 0400, tmpfs).
3. Reads or creates `/var/lib/dstack/instance-id`:
   - If file exists: load UUID, log "instance %s rejoining".
   - Else: generate UUID v7, write atomically, log "instance %s
     fresh".
4. Bootstraps cluster joining (worker only):
   - Connects to local Consul agent (which is up because consul
     starts before bootstrap-secrets via `depends_on` — though it
     blocks on bootstrap-secrets's tmpfs being ready... so an
     ordering puzzle: probably Consul should start FIRST without
     gossip-key, bootstrap-secrets writes the key, Consul reads
     the key on next startup. Or Consul reads the key from a
     file and we delay Consul's start with a depends_on healthcheck.
     Defer the resolution to implementation.).
   - Asks Consul for current `cluster=<X>` peers; claims lowest
     unused ordinal via CAS on `cluster/<X>/ordinals`.
   - Writes ordinal + computed ports to `/run/instance/`.
5. Exits cleanly so siblings can start.

## Compose-hash stability

`custom_app_id` + `nonce` aren't strictly necessary for our use case
(KMS auto-issues an `app_id` we reference via `phala_app.x.app_id`),
but pinning them ensures **the same `app_id` across `terraform
destroy` + recreate cycles** — useful for incident replay /
identity rotation control. cluster.tf exposes a `cluster_nonce`
variable; bumping it explicitly rotates the entire cluster's TEE
identity.

## Open items to verify before code lands

Carrying forward from rev-1, plus new ones:

- [ ] **Disk persistence across in-place updates** — the keystone of
  this whole design. Test in `stage4-experiments/disk-persistence/`
  before any stage-4 code lands. (In progress now.)
- [ ] **Container ordering**: Consul reads gossip key from a file
  written by bootstrap-secrets; need a clean way to gate Consul's
  start until bootstrap-secrets has finished. Compose `depends_on`
  with `condition: service_completed_successfully` is the right
  shape (bootstrap-secrets is `restart: "no"`).
- [ ] **Consul KV CAS for ordinal claim** — verify the API behaviour
  for the lowest-unused-ordinal pattern; or consider per-instance
  fixed ordinals derived from instance UUID hash modulo replica
  count (less drift-prone, no CAS needed).
- [ ] **`encrypted_env`** in the Phala provider — does it
  client-side-encrypt? Even though our env contains no secrets in
  rev-2, knowing the answer matters for at-rest visibility.
- [ ] **Phala admin enables UDP ingress** on the coordinator app
  for embedded mode. Until enabled, default coordinator is
  external-host mode (separate compose template).

## Punch-list status (from ROBUSTNESS.md)

- ✅ #1 reconnect bug — shipped.
- ✅ #2 gossip key — shipped (env-passed); rev-2 moves to TEE-derived.
- ⏳ #3 multi-server Consul — explicit "next-stage-after-stage-4".
- ✅ #4 PEERS_JSON validation — shipped (becomes runtime catalog
  validation in rev-2).
- ⏳ #5 real registry — stage 4 default (no more `ttl.sh`).
- ⏳ #6 two coordinators + signed signalling — covered by
  multi-server self-discovery.
- ⏳ #7 mesh-conn integration test — stage 4 CI.
- ⏳ #8 metrics — stage 4 follow-up.

## Migration

Stages 0–3b stay as historical reference (each demonstrates one
idea in isolation). Stage 4 is the integrated product:

```
consul-postgres-ha/
  stage0-3b/                 # historical reference, frozen
  stage4/
    cluster.tf               # the example deployment
    compose/
      coordinator.yaml
      worker.yaml
    bootstrap-secrets/       # init container source
    rollout.sh               # workload-aware update driver
    README.md
  stage4-experiments/        # one-off shakedowns
    tf-shakedown/
    disk-persistence/        # in-progress
```
