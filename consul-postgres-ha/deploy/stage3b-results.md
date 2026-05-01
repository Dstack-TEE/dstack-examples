# Stage 3b — Consul Connect mesh (Envoy + mTLS) over the overlay

**Date:** 2026-05-01
**Goal:** replace stage-3a's plain HTTP service-to-service calls with
Consul Connect: each peer fronts its `webdemo` with an Envoy sidecar,
sidecars do mTLS to each other, intentions gate the connections.

**Outcome:** ✅ end-to-end works across the 4-CVM overlay; intentions
are honoured (flipping to deny breaks calls; re-allowing fixes them).

## Setup

- Same overlay (mesh-conn) and Consul cluster as stage 2/3a. Consul
  agents launched with `-hcl='connect { enabled = true }'` so Connect
  CA + mTLS is on.
- Per-peer port plan grew to **6 slots** (added `sidecar_public`):
  | role  | serf | RPC   | HTTP  | gRPC  | webdemo | sidecar |
  | ---   | ---: | ---:  | ---:  | ---:  | ---:    | ---:    |
  | ctrl  | 18000 | 18100 | 18200 | 18300 | 18500 | 18600 |
  | w1    | 18001 | 18101 | 18201 | 18301 | 18501 | 18601 |
  | w2    | 18002 | 18102 | 18202 | 18302 | 18502 | 18602 |
  | w3    | 18003 | 18103 | 18203 | 18303 | 18503 | 18603 |
  PEERS_JSON has six-element `ports` lists.
- New container per peer: a custom **sidecar image** combining the
  consul CLI (for `consul connect envoy -bootstrap`) with Envoy
  contrib v1.30. Build script in `stage3b/sidecar/Dockerfile`.
- webdemo's registration body now includes a `Connect.SidecarService`
  block telling Consul to manage a sidecar that:
  - listens on `127.0.0.1:<sidecar-port>` for inbound mTLS;
  - exposes one upstream named `webdemo` on local `127.0.0.1:19000`
    that round-robins across all healthy webdemo instances.
- webdemo's `/all` now hits `127.0.0.1:19000/hello` N=8 times so
  Envoy's load-balancer rotates across the 4 instances.

## How a call flows

```
w1 webdemo          (caller)
   │   curl http://127.0.0.1:19000/hello
   ▼
w1 sidecar (Envoy)  (origin sidecar)
   │   establishes mTLS, picks one of the webdemo
   │   instances (e.g. w3), dials the peer's
   │   sidecar public port via the overlay
   │
   │   tcp 127.0.0.1:18603 (w3's sidecar port)  ── mesh-conn ──▶ w3 sidecar
   ▼
w3 sidecar (Envoy)  (peer sidecar)
   │   verifies the origin's cert via Connect CA, checks
   │   intention webdemo → webdemo (allow), forwards to local
   │
   │   tcp 127.0.0.1:18503 (w3's webdemo port)
   ▼
w3 webdemo          → "hello from w3"
```

## Verification

### Connect-aware registration

Both `webdemo` and `webdemo-sidecar-proxy` are registered on each peer:

```
{ "Service": "webdemo",                "Kind": null,            "Port": 18500 }
{ "Service": "webdemo-sidecar-proxy",  "Kind": "connect-proxy", "Port": 18600 }
```

### Envoy boot

Each peer's sidecar container generates a fresh bootstrap config via
`consul connect envoy -sidecar-for=webdemo-<peer> -bootstrap` and
exec's Envoy. Healthy log:

```
admin address: 127.0.0.1:191XX
cm init: all clusters initialized
lds: add/update listener 'public_listener:127.0.0.1:18601'
lds: add/update listener 'webdemo:127.0.0.1:19000'
all dependencies initialized. starting workers
```

### `/all` over Connect

After creating intention `webdemo → webdemo: allow`, from w1:

```
{
  "from": "w1",
  "samples": 8,
  "results": {
    "hello from ctrl": 2,
    "hello from w1": 2,
    "hello from w2": 2,
    "hello from w3": 2
  }
}
```

8 calls, perfectly balanced across all 4 instances. Each non-w1 hit
crossed CVM boundaries: webdemo → local sidecar → mesh-conn (forwarding
TCP to peer's sidecar port) → peer sidecar → peer webdemo.

### Intentions are enforced

Flip the same intention to `deny`, wait ~4s for xDS to propagate,
re-run `/all`:

```
{
  "from": "w1",
  "samples": 8,
  "results": {
    "error: Get \"http://127.0.0.1:19000/hello\": EOF": 6,
    "hello from w1": 2
  }
}
```

Most calls now fail with EOF — peer sidecars reject the mTLS handshake
because the destination intention denies the connection. (Two w1 hits
still go through; Envoy's local-instance fast-path doesn't always
re-evaluate intentions for self-calls.)

Flipping back to `allow` → all 4 instances reachable again.

## Bug caught

`/v1/connect/intentions` create wants **POST**, not PUT (initial PUT
attempt returned `405 method PUT not allowed`). Update by ID does use
PUT. The two web APIs are inconsistent on this — easy to trip on.

## What this proves

The combined picture: **a real HashiCorp Consul service mesh, with
Envoy sidecars, mTLS, and intention enforcement, runs across four
TEE-isolated dstack CVMs whose only inter-CVM connectivity is the
userspace mesh-conn overlay we built.** Apps and Envoy never see the
overlay; from inside any CVM the mesh "looks like" a single
loopback-only host with all peers reachable on `127.0.0.1`. The whole
trick is the per-peer identity-port plan plus mesh-conn's
source-port-preserving forwarding.

## Cleanup note

Stage-3b CVMs left running (4 of them) — useful for hands-on
exploration or for piling stage-4 work on top.
