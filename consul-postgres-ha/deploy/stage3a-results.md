# Stage 3a — Consul service discovery + plain HTTP between services

**Date:** 2026-05-01
**Goal:** layer a tiny user-facing demo on top of stage-2's Consul
cluster: each peer runs an HTTP service that registers itself with the
local Consul agent, and exposes a `/all` endpoint that fans out
`/hello` requests to every other instance discovered via Consul's
service catalog.

**Outcome:** ✅ all 4 instances register; every peer's `/all` returns
correct responses from all 4.

## Setup

- Same 4 dstack CVMs (ctrl + 3 workers), same overlay (mesh-conn) +
  Consul cluster (1 server + 3 clients) as stage 2.
- Per-peer port plan grew by one slot (index 4 = webdemo HTTP):
  `ctrl=18500, w1=18501, w2=18502, w3=18503`. mesh-conn now forwards
  five ports per peer.
- New service `webdemo` (~150 LoC Go, `stage3a/webdemo/main.go`):
  - on startup, `PUT /v1/agent/service/register` to local Consul
    (note: Consul wants PUT, not POST — caught this on first try);
  - registers as `Name="webdemo", ID="webdemo-<peer>",
    Address="127.0.0.1", Port=<own webdemo port>` plus an HTTP
    health-check pointed at its own `/hello`;
  - `/hello` returns `hello from <peer>`;
  - `/all` queries `/v1/catalog/service/webdemo` from local Consul,
    fans out HTTP GETs to every result address (which lands at
    `127.0.0.1:<peer-port>` and is routed by mesh-conn).

## Verification

Catalog (queried from ctrl):

```
{ "Node": "ctrl", "ServiceID": "webdemo-ctrl", "ServiceAddress": "127.0.0.1", "ServicePort": 18500 }
{ "Node": "w1",   "ServiceID": "webdemo-w1",   "ServiceAddress": "127.0.0.1", "ServicePort": 18501 }
{ "Node": "w2",   "ServiceID": "webdemo-w2",   "ServiceAddress": "127.0.0.1", "ServicePort": 18502 }
{ "Node": "w3",   "ServiceID": "webdemo-w3",   "ServiceAddress": "127.0.0.1", "ServicePort": 18503 }
```

`/all` from each peer returns all 4 hellos:

```
$ curl http://127.0.0.1:18501/all | jq .results
{
  "webdemo-ctrl": "hello from ctrl",
  "webdemo-w1":   "hello from w1",
  "webdemo-w2":   "hello from w2",
  "webdemo-w3":   "hello from w3"
}
```

Identical from w1, w2, w3 (and from ctrl by symmetry). Every fan-out
HTTP call goes app → local Consul (service discovery) → mesh-conn → peer
mesh-conn → peer app, all without the app knowing the overlay exists.

## What this demonstrates

- **End-to-end Consul service discovery on dstack.** A real client app
  registers, a real client app discovers, plain HTTP calls succeed
  across TEE-isolated CVMs.
- **The address Consul gives clients (`127.0.0.1:<peer-port>`) is
  resolvable from anywhere in the cluster** thanks to mesh-conn's
  identity-port plan. No address rewrites, no client-side hacks.
- **Health-checks pass over the overlay.** Each peer's local Consul
  HTTP-checks its own webdemo at `/hello`; if we wanted cross-peer
  Consul health-checking it would work the same way (HTTP via
  mesh-conn).

## Bug caught and fixed

First attempt used `http.Post` for service registration → Consul
returned `405 method POST not allowed`. `/v1/agent/service/register`
must be PUT. Fixed in `stage3a/webdemo/main.go`.

## Next

3b: replace the plain HTTP with Consul Connect sidecars (Envoy) and
service intentions, so traffic is mTLS'd between peers and access is
explicit.
