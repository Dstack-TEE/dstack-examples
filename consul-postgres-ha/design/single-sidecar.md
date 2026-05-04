# Design: collapse platform plumbing to a single sidecar container

**Status**: not started. Standalone deliverable, branch off
`dstack-consul-ha-db`, PR back into it.

## Why

A user adapting this example for their own workload sees **eight
containers** in `compose/worker.yaml`: `keepalive`, `bootstrap-secrets`,
`mesh-conn`, `consul`, `patroni`, `webdemo`, `sidecar` (Envoy), and
`tester`. Five of those are platform plumbing. That's a lot to think
about for someone whose only goal is "run my Postgres / Redis /
Kafka on a dstack-TEE mesh".

Target: collapse the platform plumbing into **one container** so the
user sees their own workload + one opaque "dstack mesh sidecar".

## Scope

**In:** `keepalive`, `bootstrap-secrets`, `mesh-conn`, `consul`,
`sidecar` (Envoy bootstrapper).

**Out:**
- `patroni` — the workload, stays separate.
- `webdemo` — example app sitting on the mesh, stays separate (and
  is what users *swap out* for their own service).
- `tester` (`netshoot`) — debugging-only, stays separate, optional.
- `signaling` — runs on the *external coordinator*, not on the worker
  CVMs. Untouched.

Net effect: per-worker CVM goes from 8 → 3 containers (sidecar +
patroni + webdemo) plus an optional debug tester.

## Approach

Single image, multiple processes, simple init script as PID 1. **Not**
a process-per-PID-1 supervisor like s6-overlay — that's overkill for
phase 1. We can graduate to s6 later if we hit limits (per-process
restart, log multiplexing, complex dep ordering beyond what shell
gives us).

### Why a shell init is enough for now

The current `compose/worker.yaml` ordering is:

```
bootstrap-secrets  ──completed──►  mesh-conn ──started──►  consul ──started──►  patroni
                                                                  │
                                                                  └──►  webdemo ──started──►  sidecar
```

Two real ordering constraints:
1. `bootstrap-secrets` must finish (writes `/run/secrets/*` and
   `/run/instance/info.json`) before *anything* else starts.
2. `mesh-conn` must be up before `consul` — Consul's serf gossip
   needs the localhost-forwarded ports.

Sidecar Envoy bootstrapping needs Consul up; this is currently
encoded as a polling `until consul connect envoy ...; do sleep 3; done`
in `sidecar/`'s entrypoint, and that pattern carries over.

Everything else is "start in parallel, stay alive, fail loudly". A
~30-line shell script of `wait_for /run/instance/info.json` + `&` +
`wait` covers it.

### Concrete shape

New image, replacing the existing four (`bootstrap-secrets`,
`mesh-conn`, the keepalive's alpine, and `sidecar`):

```
consul-postgres-ha-sidecar/
├── Dockerfile          multi-stage: builds bootstrap-secrets +
│                       mesh-conn from Go sources, pulls envoy +
│                       consul + tini binaries, copies entrypoint.sh
├── entrypoint.sh       PID 1 init — orderly start, log prefix per
│                       process, signal-forwarding, exit code = first
│                       child to die abnormally
└── README.md           what's inside, how to debug
```

Compose simplifies to:

```yaml
services:
  sidecar:
    image: ${SIDECAR_IMAGE}
    network_mode: host
    restart: on-failure
    environment: { ... existing env ... }
    volumes:
      - /var/run/dstack.sock:/var/run/dstack.sock:ro
      - /tmp/dstack-runtime/secrets:/run/secrets
      - /tmp/dstack-runtime/instance:/run/instance
      - consul-data:/consul/data

  patroni:
    image: ${PATRONI_IMAGE}
    network_mode: host
    depends_on: [sidecar]
    # ... unchanged

  webdemo:                           # optional, demo only
    image: ${WEBDEMO_IMAGE}
    network_mode: host
    depends_on: [sidecar]
    # ... unchanged
```

`bootstrap-secrets`, `mesh-conn`, `consul`, the previous `sidecar`
(Envoy) entries all collapse into the one `sidecar` service.

### entrypoint.sh sketch

```bash
#!/bin/sh
set -e
exec 2>&1   # merge stderr into stdout

prefix() { sed -u "s/^/[$1] /"; }

# 1. bootstrap-secrets writes /run/secrets/* and /run/instance/info.json
echo "[init] running bootstrap-secrets"
/usr/local/bin/bootstrap-secrets 2>&1 | prefix bootstrap-secrets

[ -f /run/instance/info.json ] || { echo "bootstrap-secrets did not write info.json"; exit 1; }

# 2. mesh-conn first — others need it for inter-CVM traffic
/usr/local/bin/mesh-conn 2>&1 | prefix mesh-conn &
MESH=$!

# 3. consul agent
PEER_ID=$(jq -r '.role + "-" + (.ordinal|tostring)' /run/instance/info.json)
SERF=$(jq -r '.ports.serf_lan' /run/instance/info.json)
... # exactly the consul invocation that's in compose/worker.yaml today
consul agent ... 2>&1 | prefix consul &
CONSUL=$!

# 4. envoy sidecar — wait for consul to be reachable on localhost,
#    then bootstrap and exec
( until consul connect envoy -sidecar-for=$WORKLOAD -bootstrap > /tmp/envoy-bootstrap.json 2>/dev/null; do sleep 3; done
  envoy -c /tmp/envoy-bootstrap.json -l info ) 2>&1 | prefix envoy &
ENVOY=$!

# Forward SIGTERM/SIGINT to all children
trap 'kill -TERM $MESH $CONSUL $ENVOY 2>/dev/null' TERM INT

# Exit when the first child dies — sidecar restarts via compose's
# `restart: on-failure`, which gives us correct cluster-wide recovery
# behavior for free (the same behavior you get today when any one of
# bootstrap-secrets/mesh-conn/consul/envoy crashes its container).
wait -n $MESH $CONSUL $ENVOY
EXIT=$?
echo "[init] one child exited: $EXIT — tearing down"
kill -TERM $MESH $CONSUL $ENVOY 2>/dev/null || true
exit $EXIT
```

`tini` (or `dumb-init`) wraps this so PID 1 reaping + signal handling
follow the conventions other tools expect, and `wait -n` (BusyBox sh
supports it) unblocks the moment any child dies.

## What changes outside the new image

1. **`compose/worker.yaml`** + **`compose/coordinator.yaml`** drop
   the four superseded services, add the single `sidecar`. Coordinator
   compose still also has `coturn` + `signaling` (those run *only* on
   the external coordinator, not on the worker CVMs — so coordinator
   compose is for the Vultr box, not for dstack CVMs).
2. **`cluster.tf`** env block — references shrink: `SIDECAR_IMAGE`
   subsumes `BOOTSTRAP_SECRETS_IMAGE`, `MESH_CONN_IMAGE`, etc.
3. **`.github/workflows/consul-postgres-ha-publish.yml`** matrix
   shrinks from 6 images to 4 (`sidecar`, `patroni`, `webdemo`,
   `signaling`).
4. **`PUBLISHING.md`** + **`README.md`** image lists shrink.
5. **`bootstrap-secrets/`**, **`mesh-conn/`** Go-source directories
   stay (each is still its own Go binary; the new image's Dockerfile
   just builds both as build stages and copies their binaries in).
   The old `sidecar/` directory's contents (Envoy bootstrap shell)
   move into the new sidecar image's `entrypoint.sh`.

## Success criteria

- [ ] One `consul-postgres-ha-sidecar` image builds clean.
- [ ] On a fresh `terraform apply`, every worker CVM ends with 3
      containers (`sidecar` + `patroni` + `webdemo`) instead of 7.
- [ ] All FAILOVER.md scenarios still pass: soft-kill RTO, hard-kill
      RTO, cheap rejoin, disk-loss rejoin. RTO should be unchanged
      (single-container restart vs four-container restart shouldn't
      noticeably affect Patroni's TTL-driven election).
- [ ] `terraform apply` in-place env update works end-to-end (the
      sidecar image-tag bump propagates without CVM destroy/recreate,
      same as the multi-image path does today).
- [ ] CI matrix shrinks to 4 images, all green.
- [ ] Per-process logs are still distinguishable (`docker logs
      dstack-sidecar-1` shows `[bootstrap-secrets] ...`,
      `[mesh-conn] ...`, etc.).

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| One inner process crashes → whole sidecar container restarts → causes Patroni to flap | Acceptable phase-1 behavior. Compose `restart: on-failure` brings it back fast (~5s). Patroni's TTL=30 absorbs that. If we see real flap-storms in practice, that's the signal to upgrade to s6-overlay (per-process restart). |
| Bigger image → slower pulls | Multi-stage build keeps final image lean (Go binaries are static, Envoy is a single binary, Consul is a single binary). Should be ≤ sum of current images, often less. |
| Harder to debug "which inner process is wedged" | Log prefixes mitigate. `docker exec dstack-sidecar-1 ps` works inside the container. |
| Inner process startup races (e.g., consul tries to talk to mesh-conn before it's listening) | The shell `&` + retry pattern in the entrypoint handles this; identical to how the existing compose `depends_on: service_started` resolves it (which is itself just "wait for the process to spawn", not for it to be ready). Today's webdemo/sidecar already poll until consul is reachable. |
| Loss of `keepalive`'s "hold the CVM up regardless of failures" property | Replace with the shell init script's own resilience: if all platform plumbing dies, the container exits and gets restarted. The point of `keepalive` was to keep dstack from tearing down the CVM during a stack-wide bug — same effect here as long as the sidecar exit code is non-fatal to dstack. |

## Open questions for the implementing agent

1. **`consul-postgres-ha-sidecar` vs renaming the existing `sidecar/`**
   directory: the existing `sidecar/` is just the Envoy bootstrap; the
   new meaning is broader. Pick a name that doesn't collide. Suggested:
   directory name `sidecar/`, image suffix `consul-postgres-ha-sidecar`
   (matching the rest of the matrix), and the *old* Envoy-bootstrap
   contents become a shell snippet inside `entrypoint.sh` rather than
   a directory.
2. Whether the `tester` (netshoot) is still useful day-to-day. If
   yes, leave it. If we never `docker exec` into it, drop it.
3. Whether to make webdemo's existence in the per-CVM compose
   conditional via env (`WEBDEMO_ENABLED=1`) so users adapting this
   for their own workload can drop it without editing the template.
   Probably yes; small change.

## Hand-off

Agent should branch off `dstack-consul-ha-db`. Smoke against the live
cluster (or a fresh `terraform apply` in a new region) before opening
the PR. PR target is `dstack-consul-ha-db` (the mega PR's branch),
not `main` directly.
