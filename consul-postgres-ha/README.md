# consul-postgres-ha

Highly-available PostgreSQL across dstack-TEE CVMs, deployed by `terraform apply`.

The example shows how to run a stateful workload (HA Postgres via Patroni)
across CVMs that can't talk to each other directly: the platform NATs
every CVM to the same public IP, and there's no L3 mesh between them.
Service-to-service traffic instead rides a userspace overlay
(`mesh-conn`) that uses pion/ICE for NAT traversal and QUIC for
reliable, multiplexed streams. On top of that overlay sit Consul (for
service discovery + leader election KV), Patroni (for Postgres
leader/replica orchestration), and Envoy sidecars (for Connect mTLS).

You can use this as-is for a 3-replica Patroni cluster, or as a
template — swap Patroni for any other stateful workload, the rest of
the platform plumbing keeps working unchanged.

## Architecture in one paragraph

Three **coordinator** CVMs run a Consul server quorum (Raft). Three
**worker** CVMs run Patroni + Postgres + a Consul client agent +
two Envoy Connect sidecars. All six are dstack-TEE CVMs hosted
behind a provider NAT. One **external coordinator** (a regular Linux
box with a public IP) runs coturn (STUN/TURN) plus a tiny signaling
broker — that's the rendezvous infrastructure each CVM uses to find
peers' ICE candidates; no data ever passes through it once peers
connect. Per-CVM and per-cluster secrets are split: the TURN HMAC is
derived per-CVM from dstack KMS, while cluster-wide-identical
material (gossip key, Patroni passwords) is generated in Terraform
and broadcast via env until attestation-rooted admission lands.
Connect CA uses Consul's built-in CA provider — root in Raft, no
external derivation needed.

For the full topology and layering walkthrough, see
[`ARCHITECTURE.md`](ARCHITECTURE.md).

### The three address spaces (you'll see these everywhere)

Apps and operators run into three loopback ranges in this example. Knowing
which one to use is most of the mental model:

| Range | What it means | Who binds it | Who dials it |
|---|---|---|---|
| `127.0.0.1:<port>` | "The local instance of this service on *this* CVM." Postgres on `:5432`, Consul HTTP on `:8500`, Patroni REST on `:8008`, etc. — every CVM binds the same canonical ports. | The app process itself (Patroni, Consul, webdemo). | The local Envoy sidecar (and ad-hoc debugging via `docker exec`). |
| `127.10.0.<svc>:<port>` | "A service I consume." One per Connect upstream declared in `cluster.tf`. The `/etc/hosts` file maps service names (`postgres-master`, `webdemo`) to these. | The **local Envoy sidecar**, one listener per declared upstream. | **Your app**. App calls `postgres-master:5432` → `getaddrinfo` → `127.10.0.20:5432` → Envoy → remote service. |
| `127.50.0.<peer>:<port>` | "A peer's loopback, reachable via mesh-conn over QUIC." Platform-internal: only Envoy-public listeners and Consul agents ever talk here. | `mesh-conn` (per-peer aliases) + the local Consul/Envoy on its self-VIP. | **Never app code.** Envoy uses it to reach remote sidecars (`:21000`/`:21001`); Consul uses it for serf gossip (`:8301`) and Raft RPC (`:8300`). |

App code only ever uses the first two. The peer plane is platform plumbing
that the example sets up automatically — adding a service to your app's
upstream list in `cluster.tf` is enough to make `service:port` work from
inside the app.

## Quick start (~5 minutes after image push)

Prerequisites:

- A Phala Cloud API key for the account you want this cluster billed to.
  Get one from the Phala dashboard (Settings → API Keys) or use the
  one already in your `~/.phala-cloud/credentials.json` profile if
  you've used `phala` CLI before — but **pick a specific token**,
  don't let it follow whatever profile is currently selected.
- A Linux box with a public IP for the external coordinator (coturn + signaling).
- The four container images (`mesh-sidecar`, `patroni`, `webdemo`,
  `signaling`) either already published to GHCR (via the CI workflow
  on this repo's main branch) or pushed by you to a registry of your
  choice. See [`PUBLISHING.md`](PUBLISHING.md).

```bash
cd consul-postgres-ha/cluster-example
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars   # set gateway_domain, image refs, external_*

# Set this explicitly to a specific account's token. Do NOT auto-pull
# from credentials.json's `current_profile` — that follows whichever
# account you last `phala auth login`-ed into, and a wrong-account
# deploy is silent until you spot it in the dashboard.
export PHALA_CLOUD_API_KEY=phak_...

terraform init
terraform apply -parallelism=1   # phala-cloud#247 needs serial creates
```

Once apply finishes, the cluster is HA Postgres on
`coordinator_replicas + worker_replicas` CVMs. From inside any
worker CVM, connect to the current leader as
`psql -h postgres-master -p 5432` — the local Envoy upstream
listener proxies via Connect mTLS to whichever CVM Patroni has
elected leader. `postgres-replica:5432` reaches any non-leader for
read-only queries.

### dstack gateway URL convention

Two forms, easy to confuse:

| Form | Behavior | Use when |
|---|---|---|
| `<app-id>-<port>.<gateway-domain>` | Gateway terminates TLS using a pre-issued wildcard cert and forwards plain HTTP to `<port>` on the CVM. | The backend speaks plain HTTP (Consul HTTP API on `:8500`, Patroni REST on `:8008`, webdemo on `:8080`). |
| `<app-id>-<port>s.<gateway-domain>` | Gateway does TLS pass-through — encrypted bytes go straight to `<port>`. | The backend speaks TLS itself (Envoy public mTLS listener on `:21000` or `:21001`). |

Picking the wrong form fails permanently. Plain-HTTP backend with the
`s` form yields `SSL_ERROR_SYSCALL` early and `wrong version number`
once routing is live; trivially mistakable for a transient gateway
provisioning delay. If the URL doesn't work after ~2 min from CVM
ready, suspect the suffix.

## What's in this directory

```
consul-postgres-ha/
├── README.md             you are here
├── ARCHITECTURE.md       the three-layer stack, peer topology, port plan
├── FAILOVER.md           soft-kill / hard-kill / disk-loss recipes + measured RTO
├── PUBLISHING.md         CI publish flow, manual ttl.sh shortcuts, hot-patch
├── ROBUSTNESS.md         where each layer breaks + mitigations
│
├── cluster-example/      one cluster.tf — opinionated worked example
├── compose/              coordinator.yaml + worker.yaml templates
├── coordinator/          docker-compose for the external coordinator (coturn + signaling)
│
├── mesh-sidecar/         consolidated platform sidecar image (bootstrap-secrets + mesh-conn + consul + envoy)
├── bootstrap-secrets/    Go source — TEE-derives per-CVM secrets (built into sidecar)
├── mesh-conn/            Go source — QUIC-over-pion/ICE overlay (built into sidecar)
├── patroni/              Patroni + Postgres image
├── webdemo/              example workload sitting on the mesh
├── signaling/            HTTP /publish + /poll broker for ICE auth/candidate exchange
└── quic-on-ice/          standalone smoke test for the QUIC-over-ICE transport
```

## Adapting to your own workload

The mesh is **declarative**: `local.services` in `cluster.tf` is the
single source of truth, and the platform sidecar generates Consul
registrations, Envoy supervise loops, loopback aliases, `/etc/hosts`
entries, and `mesh-conn`'s peer-VIP allowlist from it. Adding a
microservice is one HCL block plus an image; no edits to `mesh-conn`,
the sidecar entrypoint, your app's source, or the CI workflow.

### Add a service: worked example

Say you want a billing service on port 9090 that the existing
`webdemo` calls into. End-to-end:

1. **Declare it in `cluster.tf`** — append one entry to
   `local.services`:

   ```hcl
   services_raw = [
     { name = "webdemo",          port = 8080, subset = null    },
     { name = "postgres-master",  port = 5432, subset = "master" },
     { name = "postgres-replica", port = 5432, subset = "replica" },
     { name = "billing",          port = 9090, subset = null    },  # ← new
   ]
   ```

   This is the only edit to the platform.

2. **Add the image** to `terraform.tfvars` (`billing_image = "..."`),
   wire a `BILLING_IMAGE` variable + env entry on `phala_app.worker`,
   and add a `billing` service to `compose/worker.yaml` (modelled on
   `webdemo` — it just binds `127.0.0.1:9090` and serves).

3. **`terraform apply`**. The provider's in-place env update pushes
   the new `SERVICES_JSON` to every CVM:

   - `mesh-conn`'s allowlist extends to `{21000, 21001, 21002,
     8300, 8301}` automatically — `MESH_CONN_ALLOWLIST` is computed
     from `SERVICES_JSON` in `mesh-sidecar/entrypoint.sh`.
   - Workers provision `127.10.0.13/32 dev lo`, append
     `127.10.0.13 billing` to `/etc/hosts`, and start a third Envoy
     supervise loop with `--base-id 3 -admin-bind 127.0.0.1:19002`.
   - Coordinator-0 writes a default-allow intention for `billing`
     and any subset/redirect resolvers implied by the declaration.

4. **From any container on any peer**, `curl http://billing:9090/...`
   load-balances across all peers' `billing` instances over Connect
   mTLS. No application-side service-discovery code.

### What the convention does for you

| Field on each entry | What it controls |
|---|---|
| `name` | Consul service name + `/etc/hosts` alias. Apps dial `${name}:${port}`. |
| `port` | Canonical app port. App binds `127.0.0.1:port`. Two entries sharing a port collapse onto one **backend** (one Envoy supervise loop, one `sidecar_port`, one Connect-mTLS endpoint) — that's how `postgres-master` and `postgres-replica` ride the same Patroni instance. |
| `subset` | Optional Consul service-subset filter (matches `Service.Tags`). Each subset-bearing entry generates a redirect resolver to the parent backend. Patroni's role-watcher (in `patroni/entrypoint.sh`) updates those tags on role flips. |

VIP octets and `sidecar_port` numbers are computed in HCL from
declaration order — first service gets `vip=10 sidecar_port=21000`,
second `vip=11 sidecar_port=21001`, and so on. Plan-time validation
catches duplicate `(name, subset)` tuples.

### Two patterns: Consul-blind vs. Consul-native workloads

A workload's relationship to Consul determines how its service-mesh
entry is shaped. Two patterns cover the realistic cases:

#### Pattern A — Consul-blind workload (`webdemo` is the example)

The app is a plain process that listens on a port. It doesn't know
Consul exists; it never opens a connection to the local Consul agent;
it has no leader/follower concept. The **platform sidecar** registers
the service on the app's behalf, with the canonical port as the
backend and a standalone Connect-proxy in front of it. There's only
one parent service, named the same as the entry, no subsets.

Declaration:

```hcl
{ name = "webdemo", port = 8080, subset = null }
```

This is the default for "I just wrote a microservice and I want it on
the mesh." If you have no opinions about leader election, this is the
shape to use.

#### Pattern B — Consul-native workload (`patroni` is the example)

The app integrates with Consul as part of how it operates — Patroni
uses Consul's KV store as its leader-election lock and registers
itself in Consul's service catalog under its `scope` (which we set to
`CLUSTER_NAME` = `"demo"`). On every failover, Patroni rewrites tags
(`master` / `replica`) on its own registration. From a single parent
service we get *multiple* logical names — one per role — each as a
service-resolver that filters the parent's tags into the subset its
consumer wants:

```hcl
{ name = "postgres-master",  port = 5432, subset = "master"  }
{ name = "postgres-replica", port = 5432, subset = "replica" }
```

Two entries, same canonical port → one Envoy public listener shared
across both, two service-resolvers with different subset filters. The
platform sidecar does **not** register a parent for this case (Patroni
already did it); it only stamps the Connect sidecar-proxy. The
role-watcher in `patroni/entrypoint.sh` is the loop that maintains
tag consistency between Patroni's view of leadership and Consul's
catalog.

Failover round-trips through this in <1 second:

```
Patroni promotes worker-5 to leader
      ↓
worker-5's role-watcher writes Tags=["master"] on worker-5's sidecar
      ↓
Consul EDS push: subset master = [worker-5's sidecar:21001]
      ↓
every consumer's Envoy retargets `postgres-master` to worker-5
      ↓
next psql connection lands on worker-5
```

No DNS update, no service deregistration, no client-side retry-loop.
That's what `subset` buys you, and it's why this field exists in our
config even though only one of the three example services uses it.

#### When to pick which

| Question | Pattern A | Pattern B |
|---|---|---|
| Does your workload have a built-in Consul integration? | No | Yes |
| Does your workload register itself with Consul? | No — platform does | Yes — workload does |
| Does your workload have leader election? | No | Probably yes |
| Will tags on the service change at runtime? | No | Yes (the workload rewrites them) |
| Number of `local.services` entries per workload? | One | One per role |
| Need a `subset` field? | No (`subset = null`) | One per role |

If you're not sure, you're probably building Pattern A. Pattern B is
specifically for "this thing has its own opinions about leader
election that need to surface to consumers" — Patroni, Vault, Nomad,
custom raft-based services.

### Workload-specific pieces remaining

Only two files contain workload-specific logic after this refactor:

| Workload-specific | Lives in |
|---|---|
| The Patroni image itself + role-watcher loop | `patroni/` |
| Patroni env block (`CLUSTER_NAME`, replication passwords, etc.) | `compose/worker.yaml` |

`mesh-sidecar/entrypoint.sh` contains zero per-workload code paths —
grep it for `patroni` or `webdemo` and you get nothing. To run
something other than Patroni (Redis, Kafka, your own service): replace
the `patroni` compose service and image with your own, edit
`local.services` to declare its names + ports, and leave the rest of
the platform plumbing untouched.

## Key operational properties

| | |
|---|---|
| In-place env updates | Yes — change image tags or env values, `terraform apply`, CVMs update without losing pgdata. Requires provider `phala-network/phala 0.2.0-beta.3+`. |
| Failover RTO | ~24s soft-kill, ~33s hard-kill (default Patroni `ttl=30`). See [`FAILOVER.md`](FAILOVER.md). |
| Cheap rejoin | Yes — a recovered ex-leader replays local WAL and rejoins as a streaming replica without pg_basebackup. |
| Disk-loss rejoin | Yes — Patroni detects empty pgdata and runs full pg_basebackup over the QUIC overlay. |
| Build provenance | Sigstore-attested via GitHub Build Provenance on every published image. Verify with `gh attestation verify oci://... --repo Dstack-TEE/dstack-examples`. |

## Known limitations

* Each `terraform apply` that fans out more than 1 `phala_app` create
  in parallel hits
  [`phala-cloud#247`](https://github.com/Phala-Network/phala-cloud/issues/247)
  — use `-parallelism=1` for now (~5 min × N to bring-up).
* The mesh-conn admission story is **shared-secret based today**
  (TURN HMAC), not attestation-based. Adding TEE attestation as the
  admission credential is the next architectural step.
* The cluster's gossip key, Patroni superuser password, and
  replication password are **generated in Terraform and broadcast
  via env to every CVM** — a workaround, because those bytes live
  in `terraform.tfstate` and pass through whoever runs `apply`. The
  attestation-rooted admission design
  ([`design/attestation-admission.md`](design/attestation-admission.md))
  replaces this with TEE-derived material that no human ever sees.

## Filed upstream

* [`Phala-Network/terraform-provider-phala#5`](https://github.com/Phala-Network/terraform-provider-phala/issues/5)
  — `storage_fs` triggers ForceNew when unset; we explicitly pin
  `storage_fs = "zfs"` in `cluster.tf`.
* [`Phala-Network/phala-cloud#247`](https://github.com/Phala-Network/phala-cloud/issues/247)
  — concurrent `phala_app` creates against the same workspace return
  `400 "configuration parameters not compatible"`. Workaround:
  `terraform apply -parallelism=1`.
* [`Phala-Network/phala-cloud#242`](https://github.com/Phala-Network/phala-cloud/issues/242)
  — `phala cvms list` collapses replicas to one entry.
* [`Phala-Network/phala-cloud#243`](https://github.com/Phala-Network/phala-cloud/issues/243)
  — per-instance Terraform resource + `update_policy` + lifecycle
  hooks would let `cluster-example/rollout.sh` collapse into HCL.
