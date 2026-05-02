# Stage 4 — Developer-experience overhaul

## Why this stage

Stages 0–3b are stitched together with shell scripts and per-stage
docker-compose files. Each peer's deploy needs ~20 env vars right.
That worked for an experiment but it's the wrong shape for handing to
a developer:

- **TEE apps have predefined code.** The compose hash is part of the
  app's identity (and what KMS keys derive from). You can't SSH in
  to fix a typo — every deploy is final. The deploy *itself* must be
  the only thing that varies.
- **Topology is duplicated across CVMs.** Every peer needs the same
  PEERS_JSON, the same gossip key, the same coordinator URL. Drift
  is silent and only surfaces under load.
- **Network policy lives outside the deploy.** Intentions are
  created with `curl POST` after the cluster boots. There's no
  declarative way to say "this is the cluster" once.
- **The rendezvous infra is a separate moving piece.** A user
  shouldn't need to know about a Vultr box.

Stage 4 unifies all of this into:

1. **One file (`cluster.yaml`)** that describes the whole cluster.
2. **One command (`./cluster up`)** that brings it up.
3. **Optional bundled control plane** — when Phala admin-enables UDP
   ingress on the control CVM, coturn + signaling + Consul server
   collapse into a single dstack app and the external Vultr box
   disappears from the picture.

## The cluster.yaml

The single source of truth. Roughly:

```yaml
cluster:
  name: demo
  datacenter: dstack-mesh

# Where the control plane lives.
# Mode "embedded" requires Phala to expose UDP on the control CVM
# (3478 + 49152-49999 for coturn). Falls back to "external" if not
# available — see "Coordinator placement" below.
coordinator:
  mode: embedded                 # embedded | external
  external:                      # only when mode=external
    host: 1.2.3.4
    ssh: root@1.2.3.4

# Protocol slots used by mesh-conn. Each slot reserves a port range
# (one port per peer, computed at deploy time as base + peer_index).
protocols:
  - name: serf_lan
    base: 18000
  - name: server_rpc
    base: 18100
  - name: http_api
    base: 18200
  - name: grpc
    base: 18300
  - name: webdemo
    base: 18500
  - name: sidecar_public
    base: 18600

peers:
  - id: ctrl
    role: server                 # consul server, single bootstrap
  - id: w1
    role: client
  - id: w2
    role: client
  - id: w3
    role: client

# Network policy in declarative form. Compiled into Consul intentions
# at boot.
intentions:
  - source: webdemo
    destination: webdemo
    action: allow

# Phala-deploy-time options. Apply to every peer unless overridden in
# the peer's entry above.
deploy:
  instance_type: tdx.small
  kms: phala
  region: us-west
  public_logs: true
  dev_os: true                   # for the experiment; flip off for prod

# Secrets. Each one is either an explicit value, a `path:` to a file
# the CLI reads, or `auto:` meaning the deploy CLI generates one and
# stores it under .local/.
secrets:
  gossip_key: auto
  turn_shared_secret: auto
  # Stage-4-future: replace these with KMS-derived values via
  # /var/run/dstack.sock so the deploy CLI never sees them.

# Image references. The CLI builds and pushes from local source; for
# experiments we fall back to ttl.sh, for production these point at a
# real registry (ghcr.io, etc.).
images:
  mesh_conn: build:./stage1/mesh-conn
  webdemo:   build:./stage3b/webdemo
  sidecar:   build:./stage3b/sidecar
  consul:    hashicorp/consul:1.19
  envoy:     handled-by-sidecar
```

## The `cluster` CLI

A small Go program that consumes `cluster.yaml` and drives
`phala deploy`. Single binary, ~500 LoC.

```
./cluster validate cluster.yaml         # static checks
./cluster plan     cluster.yaml         # diff vs current state
./cluster up       cluster.yaml         # apply
./cluster down     cluster.yaml         # tear down
./cluster status   cluster.yaml         # consul members + Envoy listeners + ICE pairs
./cluster logs ctrl                     # tail one peer's container logs
```

Internals:

1. **Validate**
   - Schema check.
   - All peer ids unique, all protocol bases differ enough to not
     overlap (e.g. base+len(peers) must not bleed into next slot).
   - Exactly one peer with `role: server` (or three for HA).
   - Coordinator mode consistent with where the control peer lives.

2. **Compute derived inputs**
   - Per-peer ports = `[ proto.base + peer_index for proto in protocols ]`.
   - `PEERS_JSON` for mesh-conn = a single JSON string identical
     across all peers.
   - Coordinator address — either the control peer's gateway URL
     (embedded mode) or the configured external host.

3. **Provision secrets**
   - For each `secrets.<name>: auto`, generate once and store at
     `.local/<cluster>/<name>` (gitignored).
   - Long term: derive these inside each TEE via
     `getKey()` so the deploy host never holds them in cleartext.

4. **Build + push images**
   - Anything `build:./path` gets `docker build` + `docker push`.
   - Default registry: ttl.sh for dev, configurable per-cluster for
     prod.

5. **Deploy peers**
   - In dependency order: control plane / Consul server first, then
     workers in parallel.
   - Each peer's `phala deploy` gets the same template compose +
     per-peer env vars derived from the topology.

6. **Bootstrap policy**
   - Wait for Consul cluster to form (`/v1/agent/members` → all
     peers alive).
   - Apply intentions from `cluster.yaml` via Consul HTTP API.
   - Verify by re-reading and diffing.

7. **Status**
   - For each peer: container health, mesh-conn link state,
     Consul-membership view, sidecar listener count.
   - Report cluster-wide health on a single screen.

## Coordinator placement: embedded vs external

### Embedded mode (preferred when available)

One dstack CVM runs all of these:

```
 control CVM (dstack)
 ├── mesh-conn        (just like every other peer)
 ├── consul (server)  (-server -bootstrap-expect=1)
 ├── coturn           (UDP+TCP, 3478, 49152-49999)
 └── signaling        (TCP 7000)
```

Workers' mesh-conn uses `coordinator.address = <ctrl-app-id>.<gw>`
for both signaling (TCP via dstack-gateway) and STUN/TURN (UDP, must
be admin-enabled).

**Requires Phala admin to enable UDP ingress on the control CVM.**
The user has confirmed this is supported on Phala Cloud, just needs
the admin to flip the switch per-app.

Pros:
- Whole stack runs on dstack. No external infra. No second host.
- Coordinator's TURN credentials and gossip-relay traffic stay in
  TEE. Less attack surface.
- One thing for the dev to manage.

Cons:
- Needs Phala admin involvement to enable UDP.
- The control CVM is now in the data path (TURN relay) for any
  cross-CVM traffic that ever falls back to relay. Same as the
  external host today but with TEE attestation.

### External mode (fallback)

A non-TEE Linux box runs coturn + signaling. Control CVM runs only
the Consul server.

Pros:
- No Phala-admin gate.
- Coordinator can be cheap commodity infra.

Cons:
- Two hosts to manage.
- Coordinator is untrusted; metadata leaks (see ROBUSTNESS.md
  Layer 0).

### How the CLI handles the choice

`coordinator.mode` in cluster.yaml controls everything. When
`embedded`:
- The control peer's compose includes the coturn + signaling
  services in addition to consul.
- mesh-conn URLs on every peer point at `<ctrl-app-id>.<gw>`.

When `external`:
- The CLI SSH's to the user's coordinator host and brings up
  coturn + signaling there.
- mesh-conn URLs point at the external IP.

Switching between modes is a config-only change; no code differences
in mesh-conn or webdemo.

## Predefined-code constraint

A TEE app's compose hash is its identity. To keep this story clean:

- **One compose template per role** (control / worker), shipped in
  the repo. The deploy CLI never modifies these — only the env vars
  passed at deploy time.
- **All per-peer differences live in env vars**. PEER_ID,
  per-protocol port numbers, ROLE, the same PEERS_JSON for everyone.
- **The compose template is the audit surface.** Reviewers can see
  exactly what runs in the TEE; the only "moving" parts are the env
  values.

Future direction: secrets like `GOSSIP_KEY` and `TURN_SHARED_SECRET`
should ideally not be passed in env at all. Each TEE can derive them
deterministically via `dstack-sdk getKey("gossip")` etc., as long as
all peers share the same `app-id` (via AppAuth). This puts secret
material entirely inside the trust boundary. Stage 4 keeps env-passed
secrets for simplicity and notes this as the next refinement.

## Migration from stages 1–3b

- Stage 4 is a **new top-level layout**:
  ```
  consul-postgres-ha/
    stage4/
      cluster/             # the CLI source
      compose/
        control.yaml       # control-plane template (incl. embedded coturn+signaling)
        worker.yaml        # worker template
      examples/
        4-peer-demo/cluster.yaml
        single-pair-test/cluster.yaml
  ```
- Stages 0–3b stay as historical reference. They demonstrate
  individual ideas (port-forwarder, yamux, Consul, Connect) in
  isolation. Stage 4 is the integrated product.
- The mesh-conn Go module moves from `stage1/mesh-conn/` to
  `stage4/mesh-conn/` (or stays — implementation detail). The
  webdemo and sidecar images move from `stage3b/` to `stage4/`.

## What's actually being built

In rough order:

1. **`cluster` CLI**:
   - YAML schema definition (in Go structs).
   - Validate.
   - Render compose env from topology.
   - Drive `phala deploy` per peer, in parallel.
   - Apply intentions.
   - Status.

2. **Control-plane compose template** that runs all four control
   services (mesh-conn, consul-server, coturn, signaling). New
   compared to stage 3b.

3. **Worker compose template** — same shape as stage 3b's, but
   purely template (no per-stage forks).

4. **A signaling broker compatible with embedded mode.** The
   existing one (a tiny Go HTTP service) works as-is; just needs to
   be put in a Docker image and added to the control-plane compose.

5. **Coturn-in-TEE.** Same coturn image we use externally; just
   moved into the control-plane compose. Needs Phala UDP ingress.

6. **End-to-end smoke test.** `./cluster up examples/4-peer-demo/`
   followed by `./cluster status` reporting all-green.

## Risks

- **Phala UDP admin enablement** — out of our control. If it lands
  late, embedded mode ships unconfigured but works as soon as the
  switch flips. Until then we ship external-mode by default.
- **Compose hash stability** — if the template changes between
  deploys, app-id changes, KMS-derived keys change. Stage 4 should
  freeze the compose template versions and bump them deliberately.
- **CLI vs `phala deploy`** — the CLI shells out to `phala deploy`.
  CLI compatibility is its own concern. Long term we'd talk to the
  Phala API directly.

## Open questions for the user

1. **Languages / CLI shape.** Go for consistency with mesh-conn?
   Or Python / Node since the deploy is shell-script-shaped today?
2. **Secrets handling.** Env vars (today) vs `getKey()` (TEE-native)
   vs an external secret manager. Pick one stage-4 default.
3. **Multi-server Consul HA** for the control plane? Three control
   CVMs with shared `bootstrap_expect=3`? Adds quorum but also
   requires inter-server gossip+RPC, which already works through
   the overlay.
4. **Re-deploys.** When cluster.yaml changes, do we rolling-replace
   the affected CVMs or tear down & recreate? Patroni-style rolling
   restart needs Consul-aware deploy logic.
