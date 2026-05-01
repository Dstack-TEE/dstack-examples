# Stage 2 — Consul cluster across dstack CVMs over the mesh-conn overlay

**Date:** 2026-05-01
**Goal:** stand up a real Consul cluster (1 server + 3 clients) on four
TEE-isolated dstack CVMs, with all gossip + RPC + HTTP traffic flowing
through the userspace mesh-conn overlay built in stage 1.

**Outcome:** ✅ cluster forms, every peer sees every other peer, KV
round-trips work across CVMs.

## Setup

- 4 dstack CVMs, identical compose, distinguished by `PEER_ID` and
  per-peer port env vars.
- Each peer's Consul agent binds to `127.0.0.1` with a unique port set:
  | role  | serf | RPC   | HTTP  | gRPC  |
  | ---   | ---  | ---   | ---   | ---   |
  | ctrl  | 18000 | 18100 | 18200 | 18300 |
  | w1    | 18001 | 18101 | 18201 | 18301 |
  | w2    | 18002 | 18102 | 18202 | 18302 |
  | w3    | 18003 | 18103 | 18203 | 18303 |
- ctrl runs `consul agent -server -bootstrap-expect=1 -ui`. Workers run
  `consul agent -retry-join=127.0.0.1:18000`.
- mesh-conn (the multi-port port-forwarder from stage 1) maps each
  127.0.0.1 listener to the corresponding peer over the ICE+yamux mesh.
  Apps and Consul see only `127.0.0.1`.

## Verification

### Membership

`/v1/agent/members` from every peer:

```
ctrl sees: ctrl, w1, w2, w3
w1   sees: ctrl, w1, w2, w3
w2   sees: ctrl, w1, w2, w3
w3   sees: ctrl, w1, w2, w3
```

Every peer reports Status=alive for every other peer. Per-peer ports
gossip correctly: ctrl's `Port` field is `18000` (its serf port),
its `Tags.port=18100` (its RPC port), `Tags.grpc_port=18300`. Same
shape for the workers, with their own unique ports.

### Leader / RPC

`/v1/status/leader` from every peer:

```
ctrl: leader="127.0.0.1:18100"
w1:   leader="127.0.0.1:18100"
w2:   leader="127.0.0.1:18100"
w3:   leader="127.0.0.1:18100"
```

`127.0.0.1:18100` is ctrl's RPC identity port — every worker's leader
lookup goes through the overlay and arrives at ctrl's Consul server.

### Cross-CVM KV

Write from w1, read from w3:

```
w1$ curl -X PUT --data 'hello-from-w1@221243' http://127.0.0.1:18201/v1/kv/demo/key1
w3$ curl http://127.0.0.1:18203/v1/kv/demo/key1
    → "hello-from-w1@221243"
```

KV writes go through w1's local Consul → RPC to leader (ctrl) over the
overlay → committed to Raft → readable on w3 via its own local agent.
Full read-after-write across 3 CVMs.

## What this proves

- **Consul-on-dstack is real.** A real HashiCorp Consul cluster, not a
  mock, works across TEE CVMs that have *no* direct routable
  connectivity to each other. The only inter-CVM data path is the
  mesh-conn overlay.
- **All 3 transport classes** Consul cares about — UDP gossip, TCP RPC,
  TCP HTTP — round-trip cleanly through the same yamux session per
  peer-pair.
- **Identity-port preservation works under realistic protocol load.**
  Consul's clustering is sensitive to addresses being stable from every
  peer's perspective; the per-peer port plan + source-port preservation
  in mesh-conn delivers exactly that with no Consul-side awareness of
  the overlay.

## Next

Layer 3 simple HTTP services + Consul Connect sidecars on the workers,
demonstrate `/all` fan-out where each service calls the other two
through their Connect sidecars (mTLS).
