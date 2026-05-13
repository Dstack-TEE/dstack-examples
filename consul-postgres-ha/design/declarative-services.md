# Design: declarative service mesh — adding a microservice is one HCL block

**Status**: design accepted, not started. Single rewrite, no migration
scaffolding — old impl is committed, rollback is `git revert`, nothing
in production. Branch off `dstack-consul-ha-db`, PR back into it.

**Dependencies**: builds on the service-VIP / peer-VIP architecture
that landed at `808836c`. Attestation-rooted admission is still the
last architectural stage; this work keeps the TF-broadcast secrets
pattern unchanged.

## Why

A DX review showed that adding a microservice to the current cluster
takes edits in **seven places**: `cluster.tf`, `mesh-conn/main.go`'s
hardcoded port allowlist (requires a Go rebuild + image republish +
tag bump in `tfvars`), `compose/worker.yaml`, the Envoy supervise
block in `mesh-sidecar/entrypoint.sh` (copy-paste 50 lines, change
`--base-id` and admin port), the app binary's Consul-registration
JSON literal, the CI publish workflow, and the consumer's upstream
list. None of those edits assert against each other; port-number
mismatches surface as silent EDS-empty or TLS handshake failures.

Compare with the reference points the example is being measured
against:

- **Istio bookinfo**: one `Service` + `Deployment` YAML per
  microservice; sidecar injector handles the rest. Zero port
  arithmetic.
- **Consul HashiCups**: one tiny HCL `service { … connect {
  sidecar_service { upstreams = [...] } } }` per microservice;
  `consul services register` reads it. Zero platform edits.

The fix: **declare the service mesh in `cluster.tf`. Everything else
generates from that declaration.**

In particular: **mesh-conn becomes invisible to developers.** Today's
hardcoded `peerVIPAllowlist` in `mesh-conn/main.go:114-119` is a leak
of app-level concerns (which sidecar ports cross peer boundaries) into
platform-level code. After this work, adding a microservice does not
involve mesh-conn at all — not even a config touch.

## Goal

After this work, adding a microservice "billing" on `:9090` that the
existing `webdemo` consumes is **one HCL block edit in
`cluster.tf`**:

```hcl
local.services = [
  { name = "webdemo",          port = 8080 },
  { name = "postgres-master",  port = 5432, subset = "master" },
  { name = "postgres-replica", port = 5432, subset = "replica" },
  { name = "billing",          port = 9090 },  # ← only addition
]
```

Plus `terraform apply`. Plus (if it's a new image) updating
`webdemo`'s consumer list to include `billing` — one line.

No `mesh-conn/main.go` edit. No `mesh-sidecar/entrypoint.sh` edit. No
Consul-registration code in the app binary. No port arithmetic. No
CI workflow change unless the image is brand new.

## Non-goals

- **Replacing Consul Connect or Envoy.** Stock Connect remains the
  data plane.
- **Workload identity beyond service names.** Attestation-rooted
  intentions still live in `design/attestation-admission.md`; this
  work uses plain service-name intentions.
- **A service-mesh CLI or DSL.** The "declaration" is just HCL in
  `cluster.tf`. We're not building tooling on top.
- **Maintaining backward compatibility with the current `mesh-conn`
  allowlist shape.** This is a fresh rewrite.

## Approach

Four coupled changes, all on the same feature branch:

### 1. `cluster.tf` declares the full service list

Replace today's `local.service_vips` with a single
`local.services` list that captures everything the platform needs
to know about each service:

```hcl
local.services = [
  {
    name   = "webdemo"        # Consul service name, /etc/hosts alias
    port   = 8080             # canonical port (binds 127.0.0.1:port locally)
    subset = null             # optional: subset filter for service-resolver
  },
  {
    name   = "postgres-master"
    port   = 5432
    subset = "master"         # → service-resolver redirects to stage4@master
  },
  …
]
```

VIP octets (`127.10.0.<n>`) and Envoy sidecar ports (`21000+n`) are
**allocated automatically** by ordering — first service gets `vip=10
sidecar_port=21000`, second `vip=11 sidecar_port=21001`, etc. The
allocations are derived in HCL, not hand-managed.

For services where one canonical Patroni instance backs multiple
logical names (the `postgres-master` / `postgres-replica` split is
the only case today), they **share a single Envoy public listener +
sidecar_port** — they're the same backend, just resolved through
different subset filters. The HCL declares them as two entries with
the same `port` and different `subset`; the generated config
collapses them into one producer-side sidecar.

The resulting `SERVICES_JSON` env var is the **single source of
truth** all other components read.

### 2. `mesh-conn` reads its allowlist from runtime config

Drop the hardcoded `peerVIPAllowlist` in `mesh-conn/main.go`.
Replace with a `MESH_CONN_ALLOWLIST` env (JSON: `[{port, udp}, …]`)
that the platform sidecar populates at startup.

The allowlist is always
`{21000, 21001, …, 21000+N-1, 8300, 8301}` — the per-service
sidecar ports for every producer-side sidecar, plus the two static
Consul-infra ports. The platform sidecar generates this from
`SERVICES_JSON` in `entrypoint.sh`; `mesh-conn` just reads it.

`validatePeers()` extends to validate the allowlist too: no
duplicates, all ports in valid range.

### 3. Platform sidecar entrypoint generates Envoy supervise loops + Consul registration from `SERVICES_JSON`

Today: `mesh-sidecar/entrypoint.sh:231-269` has two copy-pasted
50-line Envoy supervise blocks (one for webdemo, one for postgres),
plus app code in `webdemo/main.go:76-129` does the Consul service
registration via the Go SDK.

After: one `for service in SERVICES_JSON` loop in the entrypoint
that, for each declared service:

- Allocates the loopback alias (`127.10.0.<vip>`).
- Updates `/etc/hosts`.
- Generates the Envoy bootstrap and starts a supervise loop on the
  appropriate `--base-id` and admin port.
- **Registers the Consul service + sidecar via `consul services
  register` from a generated HCL/JSON spec** — apps stop calling the
  Consul API themselves.

The app binary's job collapses to: bind `127.0.0.1:<canonical-port>`
and serve. No registration code, no platform awareness.

For services that need dynamic tag-mgmt (e.g. Patroni's role
watcher), the platform sidecar registers the service with **no
initial tags**, and the app's own entrypoint augments the
registration with role tags via `consul services register -replace`.
This keeps the platform-vs-app split clean: platform creates the
service, app manages its dynamic state.

### 4. Patroni-specific code moves out of `mesh-sidecar/`

The role-watcher loop currently in `mesh-sidecar/entrypoint.sh` (it
polls Patroni's REST every 5s and re-PUTs the postgres sidecar
registration with `Tags=["master"]` / `Tags=["replica"]`) is the
only Postgres-specific code in the platform sidecar. It moves
verbatim into `patroni/entrypoint.sh`, where it belongs.

After this, `mesh-sidecar/` contains zero workload-specific code.

## Where the architecture invariant lands

The layering invariant from the service-discovery rewrite —
**mesh-conn knows peers, not services** — gets strengthened:

> **The developer never touches mesh-conn.** mesh-conn's
> configuration is platform plumbing: generated from the declared
> service list by the sidecar's entrypoint, consumed by mesh-conn at
> startup, never edited by hand. Adding or removing a service does
> not require a mesh-conn rebuild.

Today's `peerVIPAllowlist` is a Go const; after this it's an env-var
that the entrypoint emits. The substance is the same; the user-
facing surface drops from "edit Go code" to "the platform handles
it."

## Implementation — single rewrite, by file

- **`cluster-example/cluster.tf`**: replace `service_vips` with
  `services` list. Compute VIPs + sidecar_ports in HCL. Emit
  `SERVICES_JSON` env on workers.
- **`mesh-conn/main.go`**: drop `peerVIPAllowlist` const; read
  `MESH_CONN_ALLOWLIST` env at startup. Extend `validatePeers()` to
  cover allowlist invariants.
- **`mesh-sidecar/entrypoint.sh`**:
  - Read `SERVICES_JSON` at top.
  - Compute and export `MESH_CONN_ALLOWLIST` for mesh-conn.
  - Loop over services to provision aliases, render `/etc/hosts`,
    register Consul sidecar services, and launch Envoy supervise
    loops.
  - Remove the postgres-specific role-watcher loop.
  - Remove the hardcoded webdemo / postgres Envoy blocks.
- **`compose/worker.yaml`**: replace per-app env-passing with
  `SERVICES_JSON`.
- **`webdemo/main.go`**: remove all Consul registration code.
  Binary becomes ~20 LoC: bind `127.0.0.1:8080`, serve, exit.
- **`patroni/entrypoint.sh`**: absorb the role-watcher loop from
  `mesh-sidecar/entrypoint.sh`. Patroni's entrypoint now drives the
  Patroni-specific tag dance against its own sidecar service
  registration.
- **`validate_test.go`**: cover the allowlist validation cases.
- **`README.md`**: update the "Adapting to your own workload"
  section to the new "add a service" flow.
- **`ARCHITECTURE.md`**: minor — Layer 2 narrative mentions the
  allowlist is platform-generated.

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| Apps that register their own services break because they're no longer the source of truth | webdemo + patroni are the only two in this repo; both are rewritten as part of this change. Document the new pattern in README so users adapting the template do the right thing. |
| `consul services register` from the platform sidecar races with the app coming up | Platform registers the *sidecar* (which is its own concern, not app-state); app-driven tag updates use `-replace` which is idempotent. Verified by reading the Consul API docs; covered by the existing health-check pattern. |
| `MESH_CONN_ALLOWLIST` env malformed → mesh-conn crashes silently | `validatePeers()` extends to fail-loud at startup with a specific error message. Same fail-fast philosophy as the existing PEERS_JSON validation. |
| Two services with the same canonical port (e.g. both want `:5432`) | HCL precomputes the assignments; if a collision exists, `cluster.tf` errors out at plan time. Check is in HCL, not at runtime. |
| Patroni role-watcher migrating breaks the existing failover behavior | Migrate verbatim — same loop, same poll interval, same `consul services register -replace`. Test against `FAILOVER.md` recipes. |

## Success criteria

- [ ] **Adding a new service to the cluster is one HCL block in
      `cluster.tf`** — verified by a worked example in the PR
      description.
- [ ] **`mesh-conn/main.go` has no const-defined service list.** The
      allowlist comes from env.
- [ ] **`mesh-sidecar/entrypoint.sh` has no Patroni-specific code.**
      `grep -i patroni mesh-sidecar/entrypoint.sh` returns nothing.
- [ ] **`webdemo/main.go` has no Consul SDK calls.** The binary just
      binds and serves.
- [ ] **All `FAILOVER.md` recipes still pass** with measured RTO
      within noise of the pre-rewrite baseline.
- [ ] **`go test` in `mesh-conn` covers allowlist-malformed cases.**

## Hand-off

This is a mechanically clean refactor — no policy choices, no SDK
uncertainty, no live-deploy verification required for the design to
land (though a deploy is the right way to validate). The implementing
agent should:

1. Read `ARCHITECTURE.md` for layering vocabulary.
2. Read this doc.
3. Implement on a feature branch off `dstack-consul-ha-db`.
4. Verify locally: `go test ./...`, `terraform validate`, all shell
   entrypoints parse with `bash -n` / `sh -n`.
5. Optional but recommended: a fresh live deploy via `terraform
   apply`, validate at least one `FAILOVER.md` recipe, then
   `terraform destroy`.
6. Update README's "Adapting to your own workload" section to walk
   through the new flow on the worked example (add a fictional
   third service like `billing:9090`).

After this lands, this doc gets deleted. Surviving artifacts: the
code + the updated README.
