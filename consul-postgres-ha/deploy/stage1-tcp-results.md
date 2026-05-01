# Stage 1 — TCP forwarding via yamux

**Date:** 2026-05-01
**Goal:** add TCP forwarding to the port-forwarder so Consul (which uses
both UDP gossip and TCP RPC + gossip-state-sync on the same port) can run
on the overlay without hitting either dstack-gateway or a separate
fallback.

**Outcome:** ✅ works. UDP + TCP forwarded over a single ICE
connection per peer-pair via yamux.

## How

mesh-conn opens **one** ICE connection per peer-pair (unchanged) and
wraps it in a `yamux.Session`. Lex-smaller side runs the yamux client,
the other runs the server — same convention used for ICE Dial/Accept.

Each yamux stream's first byte is a tag:

- `0x55 streamUDP`: the long-lived UDP control stream. Length-prefixed
  datagrams flow in both directions over this single stream. The
  client-side opens it eagerly on session start; the server picks the
  first incoming stream that carries the UDP tag.
- `0x33 streamTCP`: per-TCP-connection ephemeral stream. When a local
  TCP `Accept` happens on `127.0.0.1:<peer-port>`, mesh-conn opens a new
  yamux stream, writes the tag, then bidirectionally splices raw bytes.
  On the remote end, the receiver dials `127.0.0.1:<self-port>` and
  splices into the local app.

## Verification

4-CVM cluster (1 control + 3 workers), redeployed with the
yamux-enabled image. On each peer, started a python http server on its
own identity port. From every peer, `curl
http://127.0.0.1:<other-peer-port>/`:

```
  ctrl -> w1   : 'hello-from-w1'
  ctrl -> w2   : 'hello-from-w2'
  ctrl -> w3   : 'hello-from-w3'
  w1   -> ctrl : 'hello-from-ctrl'
  w1   -> w2   : 'hello-from-w2'
  w1   -> w3   : 'hello-from-w3'
  w2   -> ctrl : 'hello-from-ctrl'
  w2   -> w1   : 'hello-from-w1'
  w2   -> w3   : 'hello-from-w3'
  w3   -> ctrl : 'hello-from-ctrl'
  w3   -> w1   : 'hello-from-w1'
  w3   -> w2   : 'hello-from-w2'
```

12/12. The full mesh of TCP byte-stream paths works.

## Tradeoffs

- **One ICE conn per pair, multiplexed.** Halves the per-pair NAT-mapping
  cost vs running separate ICE connections for UDP and TCP. yamux adds
  ~12 bytes per frame — negligible in the large-payload (TCP) case;
  meaningful in the small-packet case but still well under MTU.
- **HOL on UDP path.** UDP datagrams ride a single yamux stream, so a
  large in-flight TCP frame can briefly delay a UDP packet. For Consul
  gossip volumes (small, infrequent) this is fine. If we ever need
  jitter-sensitive UDP, splitting into two ICE conns is the easy
  upgrade.
- **TCP MTU/MSS** falls out of yamux's stream behaviour — applications
  see normal stream semantics; mesh-conn doesn't need to know app
  framing.

## Next

Consul on top: server on ctrl, clients on workers, all gossip + RPC over
the overlay.
