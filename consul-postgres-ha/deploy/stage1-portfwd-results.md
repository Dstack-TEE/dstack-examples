# Stage 1 — port-forwarder rewrite results

**Date:** 2026-05-01
**Goal:** prove the simpler port-forwarding agent (no TUN, no virtual L3)
can shuttle UDP between two CVMs over a pion/ice direct path, and that
the source-port-preservation trick works so apps see peers at a stable
identity-port on `127.0.0.1`.

**Outcome:** ✅ works.

## Setup

- 2 dstack CVMs running the rewritten `consul-postgres-ha/stage1`. Same
  coturn + signaling on `155.138.146.255` from phase-0.
- Identity ports: `peer-a=18001`, `peer-b=18002`.
- mesh-conn now does no TUN, just one bound `net.ListenUDP` per remote
  peer, bridged 1:1 with one pion/ice connection per peer-pair.

## Path selection

```
2026-05-01 21:23:40  [peer-b] selected pair: host <-> prflx
2026-05-01 21:23:40  [peer-b] link up — listening on 127.0.0.1:18002,
                              peer reachable via ICE
```

Direct hole-punch via NAT hairpinning, same as phase-0 and the TUN MVP.

## Functional test

On peer-b: `socat -d -d UDP4-RECVFROM:18002,fork EXEC:cat` (UDP echo on
its own identity port).

From peer-a: 5 datagrams sent from `127.0.0.1:18001` to
`127.0.0.1:18002`:

```
reply='ping-1' rtt=0ms
reply='ping-2' rtt=0ms
reply='ping-3' rtt=0ms
reply='ping-4' rtt=0ms
reply='ping-5' rtt=0ms
```

(`rtt=0ms` is the shell-math measurement, not a real number — what
matters is all 5 echoes returned the correct payload, proving both
directions of the bridge work, including the source-port substitution.)

## Why it works

Each mesh-conn has one socket per *other* peer, bound to that peer's
identity port. When the local app sends to `127.0.0.1:<peer-X-port>`,
mesh-conn reads from that bound socket and forwards over ICE. On the
remote side, mesh-conn reads from ICE and writes to the local app's
identity port, *using the bound socket whose port is the source's
identity*. The kernel sets the UDP source to the bound port, so the app
sees the packet as coming from `127.0.0.1:<sender's identity port>`,
which is exactly what its peer-discovery / clustering protocols expect.

No TUN, no virtual subnet, no `cap_add: NET_ADMIN` (just `host` net
mode). Smaller blast radius, simpler config, same wire performance.

## Cleanup

Both test CVMs deleted. coturn + signaling still up.

## Next

Extend to N=4 (1 control + 3 workers). Each worker's mesh-conn maintains
3 ICE links + 3 bound sockets (one per other peer). Then layer Consul on
top: server on control, clients on workers, gossiping over the
forwarder.
