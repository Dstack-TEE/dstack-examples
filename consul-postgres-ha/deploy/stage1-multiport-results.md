# Stage 1 — multi-port forwarding

**Date:** 2026-05-01
**Goal:** extend mesh-conn so each peer can forward several ports
through a single ICE+yamux pair. Required because Consul (and most
clustering middleware) advertises *one* bind address but uses several
ports for distinct protocols (serf-LAN gossip, server-RPC, HTTP API,
gRPC/xDS), and each protocol has to land at a different per-peer port
for the identity-port-preservation trick to work for all of them.

**Outcome:** ✅ 48/48 cross-peer HTTP fetches across the full
4-peer × 4-port matrix succeeded.

## Changes

- `Peer.Port int` → `Peer.Ports []int`. Order is significant: index `i`
  is "the same protocol" across peers (e.g. index 0 = serf, 1 = RPC, …).
- Stream header grew from 1 byte to 3: `tag (1)` + `receiver-side port
  (uint16 BE, 2)`.
- For each peer-pair we still use **one** ICE conn + **one** yamux
  session. Per-port behaviour:
  - lex-smaller side opens N long-lived UDP streams up front, one per
    port, each tagged with the *peer's* port for that index;
  - lex-larger side accepts streams, looks the port up in `self.Ports`,
    pairs each stream with the matching local UDP socket;
  - TCP: per-conn ephemeral streams, header carries the destination
    port so the receiver dials its own matching local listener.
- Shared-port-table model: PEERS_JSON now looks like
  `[{"id":"ctrl","ports":[18000,18100,18200,18300]},
    {"id":"w1","ports":[18001,18101,18201,18301]}, …]`.

## Verification

4-CVM cluster (ctrl + 3 workers), every peer with 4 ports forwarded.
mesh-conn link-up logs:

```
[w3] selected pair: host <-> srflx
[w3] link up — 4 ports forwarded (udp+tcp), peer reachable via ICE
… (12 such links, 6 pairs × 2 directions, all direct)
```

Per-port sanity: started a dedicated python http server on each of the
16 (peer × port) combinations, then from every peer `curl
http://127.0.0.1:<other-peer-port>/` for every (other-peer, port) pair:

```
48 / 48 OK
```

All directed cross-peer × cross-port HTTP requests round-tripped through
the bridge.

## Why "one ICE + one yamux" rather than "one ICE per port"

A peer-pair could alternatively run N independent ICE agents (one per
port). That's the simpler code change. Reasons we chose the muxed
single-conn approach:

- **Fewer NAT mappings.** N=4 ports × 6 peer-pairs would be 24 separate
  punch operations / TURN allocations instead of 6.
- **Stronger guarantee that all-or-none of the protocol slots are up.**
  Either yamux is up or it isn't. With per-port ICE conns we'd have to
  reason about partial failures across ports.
- **Single keep-alive surface** rather than N parallel ones.

The price is one head-of-line surface across all ports inside the
yamux session. For Consul-grade traffic (small, infrequent gossip
packets + low-volume RPC) that's not a concern. We can split into
two ICE conns (UDP-only + TCP-only) if a future workload becomes
jitter-sensitive.

## Next

Layer Consul on top.
