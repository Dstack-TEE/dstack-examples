# Stage 4 — integrated dev experience

Consul service mesh + Connect mTLS across dstack CVMs, deployed via
**one `cluster.tf`** + **one `terraform apply`**, with secrets
**TEE-derived** (no human in the path) and disk volumes **preserved
across in-place updates** (verified empirically — see
`../stage4-experiments/disk-persistence/RESULTS.md`).

## Layout

```
stage4/
├── README.md                          (this file)
├── bootstrap-secrets/                 init container; the keystone
│   ├── main.go                        ~250 LoC, dstack SDK + Consul KV
│   ├── go.mod / go.sum
│   └── Dockerfile
├── mesh-conn/                         port-forwarder (stage1 + small fixes)
│   ├── main.go
│   ├── validate_test.go
│   └── Dockerfile
├── compose/                           frozen templates
│   ├── coordinator.yaml               1 CVM: consul server + coturn + signaling
│   └── worker.yaml                    N CVMs: consul client + webdemo + sidecar
└── cluster-example/                   the user-facing surface
    ├── cluster.tf                     full topology in HCL
    ├── terraform.tfvars.example       fill in image refs + gateway domain
    └── rollout.sh                     workload-aware rolling update driver
```

Stages 0–3b stay frozen as historical reference.

## How a deploy works

```bash
cd stage4/cluster-example
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set gateway_domain + image refs

PHALA_CLOUD_API_KEY=$(your token) terraform init
PHALA_CLOUD_API_KEY=$(your token) terraform apply
```

Behind the scenes:

1. Terraform creates one `phala_app.coordinator` (`replicas: 1`) and
   one `phala_app.worker` (`replicas: 3` by default). All replicas of
   each app share that app's `app_id`.
2. Each CVM boots. `bootstrap-secrets` runs first (init container,
   `restart: "no"`, `service_completed_successfully` gate):
   - Calls `dstack.NewDstackClient().Info(ctx)` → AppID, InstanceID,
     ComposeHash. Per-CVM identity rooted in the platform.
   - Calls `client.GetKey(ctx, path, "cluster", "secp256k1")` for
     `dstack-mesh/gossip`, `…/turn`, `…/connect-ca`. Same 32 bytes
     on every replica that shares the app_id.
   - Workers claim a stable ordinal (0..N-1) via Consul KV CAS on
     `cluster/<name>/slots/<i>`. Coordinator is always ordinal 0.
   - Writes secrets to a tmpfs volume + identity to
     `/run/instance/info.json`.
3. `consul`, `mesh-conn`, `coturn`, `signaling`, `webdemo`, `sidecar`
   start in dependency order, reading their config from
   `/run/instance/info.json` (ports computed from the ordinal).
4. `mesh-conn` opens ICE+yamux links to every other peer in
   PEERS_JSON; once a Consul cluster is up, gossip + RPC + Connect
   mTLS all flow through the overlay.

## Adding a peer

Edit `cluster.tf` (or `terraform.tfvars`):

```diff
- worker_replicas = 3
+ worker_replicas = 4
```

`terraform apply`. The provider does an in-place update on
`phala_app.worker`, which propagates the new `PEERS_JSON` env to
every existing CVM (their disks survive — verified) AND launches the
new replica's CVM, which calls `bootstrap-secrets`, claims the next
free ordinal slot in Consul KV, and joins.

## Updating images / config

Same shape: bump the image ref in `terraform.tfvars` and apply.
The provider's in-place update path swaps the container while
preserving the disk volume (`/consul/data`, future Patroni WAL,
etc.).

For **leader-bearing rolling updates** (Consul server quorum,
Patroni promotion), use `./rollout.sh` instead of bare
`terraform apply`. It snapshots Consul, applies one app at a time
via `-target`, and waits for the cluster to be all-alive between
steps. Once `phala-cloud#243` lands `phala_app.update_policy`, this
script collapses into HCL.

## Identity rotation

Bumping `cluster_nonce` (currently implicit; add a variable when
needed) rotates the cluster's TEE identity → new app_id → new
KMS-derived keys → new gossip key → new Connect CA root. **Always
deliberate, never an accidental side-effect**.

## Known limitation: worker↔worker mesh-conn instability under load

Patroni leader election works (validated end-to-end: write+read on the
elected primary). Patroni replication does **not** — `pg_basebackup`
from leader to either replica fails reliably mid-transfer because the
worker↔worker mesh-conn link drops within seconds of `link up`.

**Symptoms (from a stuck-link debug session):**
- ICE selects `srflx <-> prflx` and reports `Connected`
- yamux throws `accept: short buffer` 5–60 s later
- `runPeerLink` retries cleanly (the ICE-Failed cancel and
  drain-then-push pollLoop fixes do their job), but the next link
  has the same problem
- `pg_basebackup`'s 18703 forwarder gets bound, accepts a connection,
  starts streaming, then dies — Patroni rolls back the data dir and
  retries indefinitely

**What works:**
- Coord↔coord, coord↔worker links: stable. Consul Raft (3 servers)
  + 6-member catalog stays up indefinitely.
- The worker↔worker pair *can* reach each other through ICE — this
  isn't a "no path exists" problem. The path exists but is lossy
  enough that yamux's framing breaks.

**What didn't help (already tried):**
- `MESH_CONN_RELAY_ONLY=1` (force pion to gather only Relay
  candidates). Made things worse — pion's relay-only path doesn't
  establish relay-relay pairs reliably under load (TURN allocation
  churn is observable on the coturn side). The flag stays in the
  code as an escape hatch but is off by default.
- Sequenced bounces, signaling broker stale-message drop, mesh-conn
  drain-then-push auth, ICE-Failed cancel. These all fix
  *secondary* failure modes; the primary "yamux short buffer
  shortly after link up" is untouched.

**What probably is the root cause:**
- The path pion picks (`srflx <-> prflx`, peer-reflexive) goes
  through whichever NAT mapping discovered itself during the
  connectivity check. Those mappings are short-lived on dstack's
  worker NAT (we never see TURN-relay selected when host/srflx is
  available). UDP packet loss on that path then truncates yamux
  frames, and yamux has no per-frame integrity check — it just
  errors on `accept: short buffer`.

**What an instrumentation pass actually found:**
A trace with byte counters + yamux logging surfaced two distinct bugs
on top of the network instability — both fixed:

1. **`ice.Conn.Read` returned `io.ErrShortBuffer`.** pion's
   `ice.Conn` is packet-oriented: each `Read` returns at most one
   UDP datagram, and if the caller's buffer is smaller, pion
   *truncates* the datagram and returns `ErrShortBuffer`. yamux's
   internal `bufio.Reader` is 4096 B — TURN-encapsulated relayed
   datagrams routinely exceed that. yamux saw a corrupt frame
   stream and aborted with "accept: short buffer". Fixed by a
   65535-byte packetizing adapter (`countingConn`) that always
   reads full datagrams from `ice.Conn` and re-serves them to
   yamux as a stream.

2. **My own aggressive 5 s yamux keepalive killed the link.** I'd
   tried `KeepAliveInterval = 5s` to detect a stuck path quickly,
   but a single keepalive packet lost on the lossy UDP path under
   a `pg_basebackup` burst was enough to trigger keepalive timeout
   and tear the session down. Reverted to 30 s/10 s defaults.

**What still doesn't work (the actual wall):**
After both fixes, link establishes via `relay <-> relay` through
the Vultr coturn, transfers ~268 KB of pg_basebackup data cleanly,
then the next yamux keepalive packet is lost on the UDP relay leg
and yamux closes the session. yamux assumes a reliable byte stream
(TCP-like) — it has no retransmit. coturn relays via UDP between
the two clients regardless of the client→TURN transport.

**TCP-only escape hatch attempted (`MESH_CONN_TCP_ONLY=1`):**
Restricts pion to TCP NetworkTypes AND filters TURN URLs to
`Proto=TCP`. pion still picks `relay ... (proto=udp)` because
relay candidates inherit transport from the *relayed* leg (always
UDP unless RFC 6062 TCP allocation is requested, which pion's TURN
client doesn't do).

**Pickup guide for the next session:** [`RESUME.md`](RESUME.md) has
the live cluster's app IDs, the exact reproducer for the stuck-link
trace, what was already ruled out, and a list of open hypotheses
that deserve fresh eyes — without prejudging the fix.

## What was deferred from punch-list

The runtime stack is solid; what's left is operational polish:

- **Multi-server Consul HA** (`replicas: 3` on coordinator). One-line
  change to cluster.tf, but pulls the "stale slot cleanup" question
  forward (a permanently-retired instance leaves a KV slot owned by
  a dead InstanceID; production wants Consul Sessions with TTL
  instead of unconditional CAS-claim). **Done in commit `17f4642`.**
- **Real registry** instead of `ttl.sh` for the images.
- **`encrypted_env`** in the Phala provider for env-passed image
  refs (low risk today; nice to have).
- **CI** — local mesh-conn integration test + a `terraform
  validate` + `terraform plan` smoke check on every PR.
- **Periodic metrics** on mesh-conn (per-link bytes, ICE state,
  yamux stream count).
- **Shared TEE-derived secrets across separate `phala_app`s.**
  Today coordinator + each worker is its own `phala_app`, so each
  derives its own KMS root from its own AppAuth contract — they
  *can't* `getKey()` to the same value. We sidestep this by
  bootstrap-secrets only deriving values used locally (TURN secret,
  ordinal, info.json) and using Consul as the cross-CVM trust
  anchor. The clean fix is a "shared AppAuth contract" referenced
  by all 4 apps so they can derive identical gossip / Connect-CA
  seeds purely from the TEE — that wants on-chain KMS work and is
  the gating piece for stage 2 (attestation-gated mesh join).
- **mesh-conn ICE recovery beyond the in-process retry.** The fix
  in `dialICE` correctly cancels stuck `agent.Dial`/`Accept` on
  Failed/Closed and the outer `runPeerLink` retries every 5s — but
  if both sides of a link end up Failed simultaneously, the new
  attempts may race against still-cached signaling state. The
  mitigation today is bouncing the container; production wants the
  signaling broker to expire stale auth/candidate entries on a
  short timer.

## Open issues filed upstream

- [`Phala-Network/terraform-provider-phala#5`](https://github.com/Phala-Network/terraform-provider-phala/issues/5)
  — `storage_fs` ForceNew bug. We pin `storage_fs = "zfs"`
  explicitly in cluster.tf to avoid it.
- [`Phala-Network/phala-cloud#246`](https://github.com/Phala-Network/phala-cloud/issues/246)
  — env-block in-place updates silently noop (provider reports
  "No changes" even when env values changed). Cause likely lives
  in the API (no env-update path) with the provider downstream.
  Workaround during dev is hot-patching containers via `docker
  compose --env-file /dstack/.host-shared/.decrypted-env -p dstack
  up -d <svc>`.
- [`Phala-Network/phala-cloud#247`](https://github.com/Phala-Network/phala-cloud/issues/247)
  — `phala_app` create returns `400 "configuration parameters not
  compatible"` under concurrent creates against the same workspace.
  Affects every `terraform apply` that fans out more than ~1
  `phala_app` in parallel (default `-parallelism=10` reliably hits
  it). **Workaround**: `terraform apply -parallelism=1`. Adds
  ~5 min × N to bring-up time but always succeeds.
- [`Phala-Network/phala-cloud#242`](https://github.com/Phala-Network/phala-cloud/issues/242)
  — `phala cvms list` collapses replicas to one entry.
- [`Phala-Network/phala-cloud#243`](https://github.com/Phala-Network/phala-cloud/issues/243)
  — Per-instance Terraform resource + `update_policy` + lifecycle
  hooks + `auto_healing`. Once landed, `rollout.sh` collapses into
  declarative HCL.
