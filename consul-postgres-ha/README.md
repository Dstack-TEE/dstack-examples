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
**worker** CVMs run Patroni + Postgres + a Consul client agent. All
six are dstack-TEE CVMs hosted behind a provider NAT. One **external
coordinator** (a regular Linux box with a public IP) runs coturn
(STUN/TURN) plus a tiny signaling broker — that's the rendezvous
infrastructure each CVM uses to find peers' ICE candidates; no
data ever passes through it once peers connect. Per-CVM secrets
(TURN HMAC key, Consul gossip key, Connect CA root) are derived from
the dstack platform's KMS at boot — no human in the path.

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
`coordinator_replicas + worker_replicas` CVMs. Connect to the leader
through any worker's `127.0.0.1:18703+ordinal` (forwarded by mesh-conn
to whichever CVM Patroni elected leader).

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
| Per-CVM postgres + patroni rest port assignments | `compose/worker.yaml` env block |
| The Patroni service entry in `cluster.tf`'s env | `cluster-example/cluster.tf` |

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
