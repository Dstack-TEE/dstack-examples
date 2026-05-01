# Stage 1 — N=4 mesh verification

**Date:** 2026-05-01
**Goal:** confirm the port-forwarder scales past N=2, with one process
maintaining (N-1) ICE links + (N-1) bound UDP sockets, and traffic flowing
on every link concurrently.

**Outcome:** ✅ all 6 ICE links established direct (no TURN relay); all
12 cross-peer one-way UDP deliveries received correctly.

## Setup

- 4 dstack CVMs deployed from the same `consul-postgres-ha/stage1`
  compose, distinguished only by `PEER_ID` and a shared `PEERS_JSON`.
- Identity ports: `ctrl=18000`, `w1=18001`, `w2=18002`, `w3=18003`.
- Each mesh-conn opens 3 ICE connections + 3 bound UDP sockets.

## Connectivity matrix (selected ICE candidate pairs)

```
        ctrl       w1         w2         w3
ctrl    -          host<->prflx host<->prflx host<->prflx
w1      host<->prflx -          host<->srflx host<->prflx
w2      host<->prflx srflx<->prflx -          host<->prflx
w3      host<->prflx host<->prflx host<->prflx -
```

Every pair direct (NAT-hairpinned). No relay candidates selected.

## Fan-out test

On every peer: `socat -u UDP4-LISTEN:<own_port>,reuseaddr,fork
OPEN:/tmp/recv.log,creat,append`. From every peer to every other peer:
one tagged datagram `from-<src>-to-<dst>`.

Receivers:

```
[ctrl]  from-w1-to-ctrl   from-w2-to-ctrl   from-w3-to-ctrl
[w1]    from-ctrl-to-w1   from-w2-to-w1     from-w3-to-w1
[w2]    from-ctrl-to-w2   from-w1-to-w2     from-w3-to-w2
[w3]    from-ctrl-to-w3   from-w1-to-w3     from-w2-to-w3
```

12/12 expected datagrams delivered. The mesh works.

## Implications for layering Consul next

- mesh-conn is currently UDP-only. Consul's `serf_lan` uses both UDP and
  TCP on the same port; UDP for periodic gossip + ping, TCP for
  push/pull state sync. UDP-only would let agents discover each other
  but slow / partial state convergence.
- Consul RPC (default 8300) is TCP. Cross-CVM RPC needs either
  TCP-forwarding through mesh-conn or going via dstack-gateway
  TLS-passthrough.
- Two paths from here:
  1. Add TCP forwarding to mesh-conn (one ICE conn per pair, custom
     framing or yamux multiplexed). Keeps the abstraction symmetric.
  2. UDP only via mesh-conn, route TCP (RPC + gossip-state-sync)
     via dstack-gateway with SNI passthrough (`<peer-app-id>-<port>s`).
     Heterogeneous transport but no new code needed in mesh-conn.

(2) is faster to demo; (1) is the more complete answer. Going with (1)
next so the agent stays the only thing apps need to know about.
