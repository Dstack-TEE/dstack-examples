# Stage 1 — mesh-conn MVP results (TUN-based, single peer pair)

**Date:** 2026-05-01
**Goal:** prove that arbitrary IP traffic — not just hand-written echo — can
flow between two dstack CVMs over a pion/ice-established UDP path.

**Outcome:** ✅ works, with one important caveat.

## Setup

- 2 dstack CVMs running `consul-postgres-ha/stage1/docker-compose.yaml`
  (services: `mesh-conn` + `nicolaka/netshoot` tester).
- `mesh-conn` (Go, ~280 LoC, pion/ice v2 + songgao/water TUN):
  - opens TUN `mesh0` with virtual IP `10.66.0.{1,2}`;
  - establishes one ICE link to its partner via the same coturn +
    signaling broker used in phase-0;
  - 1:1 pumps L3 packets between TUN and the ICE socket.
- Coturn + signaling continued running on `155.138.146.255` from phase-0.

## Caveat: docker-bridge networking forces TURN-relay path

First test had `mesh-conn` on the default bridge network. ICE selected
`host <-> relay`: peer-b appeared to peer-a as
`udp4 relay 155.138.146.255:49442 related 172.18.0.2:48334`. RTT was
**~163 ms** (Vultr-east → US-West).

Cause: when ICE gathers an `srflx` candidate from inside a docker bridge,
it sends a STUN binding from the container's bridge IP (172.18.0.x). The
provider NAT learns the mapping for **the host's** outgoing source port,
not for the bridge socket. Reply packets land at the host but
docker-bridge has no `iptables` rule to forward them back to the
container, so the connectivity check fails for the srflx pair, and ICE
falls back to the always-reachable TURN relay. This is the same
"docker-bridge breaks NAT-traversal" issue Tailscale and similar tools
warn about.

Fix: `network_mode: host` for `mesh-conn` (and for the tester sidecar so
it shares the host netns and sees the TUN device).

## After the fix — direct srflx hole-punch

```
2026-05-01 21:14:39  ICE state: Connected
                     selected pair: local=host  remote=srflx
                     local : udp4 host  10.0.2.10:42895
                     remote: udp4 srflx 66.220.6.105:47618 related 0.0.0.0:47873

ping 10.66.0.2 from 10.66.0.1:
  rtt min/avg/max/mdev = 4.814 / 6.242 / 8.399 / 1.332 ms (5 of 5)
```

Same NAT-hairpinned path phase-0 found, ~6 ms RTT, no packet loss.

## What this proves

- Stage-0's "direct UDP works" result generalises: not just hand-written
  echo on top of an `ice.Conn`, but **arbitrary IP traffic** (ICMP here;
  TCP/UDP equally would work) routes through the pion/ice pipe.
- The userspace overhead (TUN read → ICE write → kernel out → kernel in
  → ICE read → TUN write) adds essentially nothing beyond the underlying
  path RTT (6 ms here vs phase-0's 6 ms over a raw `ice.Conn`).
- Container network mode is a load-bearing detail. Anything in this
  family (ICE-based mesh, WireGuard, Tailscale, …) will need
  `network_mode: host` on dstack CVMs to avoid silent fallback to relay.

## Where this leaves the design

The TUN approach proved the concept but is heavier than needed for our
real workload (apps in CVMs talking to each other). Next iteration moves
to a **userspace port-forwarding agent**: each peer publishes its
direct UDP/TCP endpoints (srflx mappings); apps bind locally and the
agent bridges sockets pair-wise. Pion/ice stays as the negotiation
primitive (hole-punch coordination + TURN fallback) but no TUN device,
no virtual L3, no kernel routing. Apps see ordinary `localhost:<port>`
upstreams pointed at peers.

## Cleanup

Both MVP CVMs deleted. coturn + signaling on `155.138.146.255` still up.
