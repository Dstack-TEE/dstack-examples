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

## Quick start (~5 minutes after image push)

Prerequisites:

- A Phala Cloud account with API credentials at `~/.phala-cloud/credentials.json`.
- A Linux box with a public IP for the external coordinator (coturn + signaling).
- The four container images (`mesh-sidecar`, `patroni`, `webdemo`,
  `signaling`) either already published to GHCR (via the CI workflow
  on this repo's main branch) or pushed by you to a registry of your
  choice. See [`PUBLISHING.md`](PUBLISHING.md).

```bash
cd consul-postgres-ha/cluster-example
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars   # set gateway_domain, image refs, external_*

export PHALA_CLOUD_API_KEY=$(python3 -c "
import json; d=json.load(open('$HOME/.phala-cloud/credentials.json'))
print(d['profiles'][d['current_profile']]['token'])")

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

Three things make this opinionated for Patroni; everything else is
generic platform plumbing.

| Patroni-specific | Lives in |
|---|---|
| The Patroni image itself | `patroni/` |
| Patroni env block + REST/Postgres port choices | `compose/worker.yaml` |
| Postgres service VIPs + Connect upstreams | `cluster-example/cluster.tf` (`local.service_vips`) |
| Postgres Connect sidecar registration + Envoy launch | `mesh-sidecar/entrypoint.sh` |

To run something else (a Redis cluster, a Kafka broker, your own
stateful service): swap those three pieces, leave `mesh-conn`,
`bootstrap-secrets`, `consul`, `sidecar`, the coordinator topology,
and the Terraform structure as-is.

## Key operational properties

| | |
|---|---|
| In-place env updates | Yes — change image tags or env values, `terraform apply`, CVMs update without losing pgdata. Requires provider `phala-network/phala 0.2.0-beta.3+`. |
| Failover RTO | ~24s soft-kill, ~33s hard-kill (default Patroni `ttl=30`). See [`FAILOVER.md`](FAILOVER.md). |
| Cheap rejoin | Yes — a recovered ex-leader replays local WAL and rejoins as a streaming replica without pg_basebackup. |
| Disk-loss rejoin | Yes — Patroni detects empty pgdata, runs full pg_basebackup over the QUIC overlay (~25 MB/s sustained between dstack workers). |
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
