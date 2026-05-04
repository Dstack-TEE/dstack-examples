# Architecture

Three layers stacked, each unaware of the one below it. Plus the apps
running on top of all of it.

## Layer 0 — physical / dstack reality

Six dstack CVMs (3 coordinators + 3 workers), TEE-isolated, sitting
behind Phala's provider NAT. **They cannot reach each other directly**
on any L3 path. Every CVM NATs out to the same public IP, so even a
"direct" peer-to-peer flow is hairpinned by the provider edge. The
only thing the CVMs share is outbound internet egress.

Plus one plain Linux box with a public IP — the **external
coordinator** — running `coturn` (STUN/TURN) and a tiny HTTP
signaling broker. This is rendezvous infrastructure only: once peers
have ICE-handshaked, no data passes through it (TURN is the fallback
when direct ICE candidates can't establish).

```
                      coturn + signaling
                      <external IP>
                              ▲
                outbound      │ STUN binding
                UDP+TCP       │ ICE candidate exchange
                              │
        ┌─────────────────────┼─────────────────────────────────┐
        │                     │                                 │
   [coord-0]  [coord-1]  [coord-2]   [worker-3]  [worker-4]  [worker-5]
                            (no L3 connectivity to each other)
```

## Layer 1 — mesh-conn pair-wise overlay

For every **pair** of peers, mesh-conn establishes one `pion/ice`
connection. ICE punches a direct UDP path through the NAT (in our
deployment NAT-hairpinned via the provider edge) and stays put. The
signaling broker drops out of the picture once each pair is up.

Per pair we then run **one QUIC connection** (quic-go) over the
ICE conn, treating `ice.Conn` as a `net.PacketConn`. QUIC provides
loss recovery, congestion control, and stream multiplexing on top of
the lossy UDP underlay. Streams come in two flavours: some are
long-lived (one per protocol port, carrying length-prefixed UDP
datagrams), the rest are ephemeral (one per accepted TCP connection).

```
              ┌── ICE conn / QUIC ──┐
   coord-0  ◄═│      direct UDP     │═►  worker-3
              └── (NAT hairpin)     ┘
   coord-0  ◄════════════════════════►  worker-4
   coord-0  ◄════════════════════════►  worker-5
   coord-0  ◄════════════════════════►  coord-1
   coord-0  ◄════════════════════════►  coord-2
   ...                                   (full mesh)
```

A 6-peer full mesh has 15 ICE connections (6×5/2). Each peer
maintains five of them.

> Why QUIC and not yamux: yamux assumes a reliable byte-stream
> underlay. `pion/ice.Conn` is UDP, and the path between dstack CVMs
> is lossy enough (~99% one direction on hairpin, ~78% on coturn
> relay) that yamux's keepalive and recv-window invariants trip
> almost immediately under load. QUIC has the loss recovery + flow
> control that yamux is forced to assume from below it.

## Layer 2 — identity-port plane

This is the trick that makes the overlay invisible to the applications
above. Every peer has a unique port for every protocol. mesh-conn
binds the **other** peers' identity ports on `127.0.0.1` and bridges
each one to the right ICE+QUIC peer link, **preserving source ports**
so the destination app sees the packet as coming from
`127.0.0.1:<sender's identity port>` — which is exactly what the app
uses to identify the sender.

So inside any CVM the entire cluster looks like a single loopback
host. Eight protocol ports per peer (serf_lan, server_rpc, http_api,
grpc, webdemo, sidecar_public, postgres, patroni_rest), spread by
`base + ordinal`:

```
                  inside worker-3 CVM (network_mode: host)
   ┌───────────────────────────────────────────────────────────────────┐
   │ local apps bind their OWN identity ports (base + ordinal=3):      │
   │                                                                   │
   │   consul agent      ▶  127.0.0.1:18003 (serf)  18103 (rpc)        │
   │                        18203 (http)   18303 (grpc)                │
   │   webdemo           ▶  127.0.0.1:18503                            │
   │   envoy sidecar     ▶  127.0.0.1:18603 (public mTLS)              │
   │   patroni / pg      ▶  127.0.0.1:18703 (postgres) 18803 (REST)    │
   │                                                                   │
   │ mesh-conn binds OTHER peers' identity ports on 127.0.0.1:         │
   │                                                                   │
   │   ports[0..7] + 0 ◄── coord-0                                     │
   │   ports[0..7] + 1 ◄── coord-1                                     │
   │   ports[0..7] + 2 ◄── coord-2                                     │
   │   ports[0..7] + 4 ◄── worker-4                                    │
   │   ports[0..7] + 5 ◄── worker-5                                    │
   │                                                                   │
   │ all UDP/TCP traffic to those ports is shipped through the         │
   │ matching ICE+QUIC connection to the corresponding peer.           │
   └───────────────────────────────────────────────────────────────────┘
```

Every peer has the symmetric layout — own ports bound by apps, other
peers' ports bound by mesh-conn.

## Layer 3 — apps

Consul agents, Envoy sidecars, webdemo, Patroni, anything else. These
think they're talking to peers on `127.0.0.1`. They never see ICE,
QUIC, TURN, or the public internet. Stock HashiCorp Consul, stock
Envoy, stock Patroni.

## How a single call traverses all four layers

A Connect-style mTLS call from `worker-3`'s webdemo to `worker-4`'s
webdemo:

```
worker-3 webdemo
  GET http://127.0.0.1:19000/hello             ── Layer 3, app on its
  │                                                local sidecar upstream
  ▼
worker-3 envoy sidecar
  picks endpoint via Consul-supplied EDS
  opens mTLS to "127.0.0.1:18604" (worker-4's sidecar via mesh-conn)
  │
  ▼
worker-3 mesh-conn (TCP listener on 127.0.0.1:18604)
  reads bytes off the local TCP listener
  opens a QUIC stream tagged "port=18604"
  writes through the worker-3↔worker-4 QUIC connection      ── Layer 2 → 1
  │     ╱
  │    ╱  here Layer 1 (QUIC frames over the ICE conn)
  │   ╱   meets Layer 0 (UDP packets across the public
  │  ╱    internet, NAT-hairpinned via the provider edge)
  │ ╱
  ▼
worker-4 mesh-conn (QUIC stream accept on the worker-3 ICE conn)
  reads stream header → "port=18604"
  dials TCP to 127.0.0.1:18604 (worker-4's actual sidecar)
  splices stream ↔ TCP conn                                 ── Layer 1 → 2
  │
  ▼
worker-4 envoy sidecar
  validates origin's mTLS cert against Connect CA
  checks intention webdemo → webdemo (allow)
  forwards to local 127.0.0.1:18504 (LocalServicePort)
  │
  ▼
worker-4 webdemo
  serves /hello → "hello from worker-4"                     ── Layer 3
```

Reply takes the same path in reverse.

## mesh-conn × QUIC — how they work together

The bit that's worth being precise about: mesh-conn is built on top
of `pion/ice` and `quic-go`. The wire layout is small enough to write
down completely.

### What mesh-conn has after ICE

After the ICE handshake, mesh-conn has one `*ice.Conn` per peer-pair.
That's a `net.Conn`-shaped object whose underlying wire is a single
UDP socket through pion. mesh-conn wraps it as a `net.PacketConn` and
hands that to `quic-go`, which performs a TLS 1.3 handshake (self-
signed, since peer trust is bootstrapped from the TURN HMAC + dstack
TEE layer, not TLS identity) and gives back a `*quic.Conn`.

### Why QUIC for the mux

We need to carry multiple logical channels over the unreliable UDP
underlay:

- One long-lived stream per identity port (8 of these per peer-pair)
  carrying length-prefixed UDP datagrams.
- One ephemeral stream per accepted local TCP connection, opened and
  closed on demand.

QUIC has all of that built in: streams (`OpenStreamSync` /
`AcceptStream`), per-stream and per-connection flow control, loss
recovery, congestion control, and an idle-timeout-driven liveness
check. Crucially, it does not assume a reliable underlay — *unlike*
yamux, which we tried first and gave up on. The earlier yamux build
sustained ~3 KB on the dstack hairpin path before its keepalive /
recv-window invariants tripped on dropped packets. QUIC sustains
~25 MB/s on the same path.

### Client / server roles

QUIC is asymmetric like yamux: one side `quic.Dial`s, the other
`quic.Listen`s and `Accept`s. Roles are picked from peer IDs in lex
order — same convention as ICE Dial / Accept:

```go
isClient := cfg.SelfID < peer.ID
if isClient {
    qconn, err = quic.Dial(ctx, packetConn, remoteAddr, tls, cfg)
} else {
    ln, _ := quic.Listen(packetConn, tls, cfg)
    qconn, err = ln.Accept(ctx)
}
```

### Stream protocol (mesh-conn's framing on top of QUIC)

When a stream opens, the **first 3 bytes** carry a mesh-conn header:

```
+------+-----------+-----------+
| tag  | port high | port low  |
| 1 B  |   1 B     |   1 B     |
+------+-----------+-----------+
```

- `tag = 0x55` → **streamUDP** — long-lived, length-prefixed UDP
  datagrams.
- `tag = 0x33` → **streamTCP** — per-connection raw TCP byte stream.

The 16-bit `port` is the **receiver's own identity port** for the
protocol slot this stream serves. The receiver looks it up in
`self.Ports`, finds the index, and pairs the stream with the right
local socket / dial target.

UDP-over-stream uses an explicit 2-byte big-endian length prefix per
datagram, since QUIC streams are byte-oriented (like yamux was) and
don't preserve the original UDP datagram boundaries on their own.
TCP forwarding needs no framing — the splice is two `io.Copy`
goroutines and the underlying app already speaks TCP semantics.

### What that gets us

- **Stream multiplexing** — UDP + TCP channels share one ICE conn
  without interference.
- **Loss recovery + congestion control** — provided by QUIC, not us.
  This is the difference between "works under load" and "doesn't".
- **Per-stream + per-connection flow control** — a slow consumer on
  one stream doesn't block others; aggregate windows protect the
  receiver.
- **Half-close + idle timeout** — TCP-style FIN per stream;
  connection-level `MaxIdleTimeout` (60s) tears down the conn
  cleanly when the underlay dies, surfacing errors to our pump
  goroutines rather than letting them hang.

The whole thing is **one ICE conn per peer-pair, one QUIC connection
per ICE conn**, plus a 3-byte header per stream and a 2-byte length
prefix per UDP datagram. That is the entirety of mesh-conn's wire
format.

## Trust boundaries

- **App → Envoy** is plaintext on loopback. Same CVM, same TEE.
- **Envoy → Envoy** is mTLS, certs signed by Consul's Connect CA.
  End-to-end across the overlay; mesh-conn just sees encrypted bytes.
- **mesh-conn → mesh-conn** rides ICE. Direct UDP between CVMs on the
  public internet (or TURN-relayed if hole-punching ever fails).
  pion/ice doesn't add encryption on top of the data path itself, so
  unencrypted traffic between mesh-conn endpoints would be on the wire
  in the clear.
- …all confidential traffic above it is **already encrypted by Envoy
  mTLS** (Layer 3), so the wire is safe even if someone could see the
  UDP datagrams.
- **Consul gossip** is currently unencrypted (we didn't set a gossip
  key); RPC is plaintext. Both are confined to inside the overlay,
  but a full setup would set `-encrypt=...` and TLS for
  RPC. See [ROBUSTNESS.md](ROBUSTNESS.md).

## What's nice about this shape

- **Layer 3 has zero awareness of layers below.** Consul, Envoy,
  webdemo all think they're on a flat loopback. Anything that runs
  against Consul today (Vault, Nomad, Boundary, custom apps) drops in
  unchanged.
- **Layer 1 is a single component (mesh-conn, ~700 LoC Go including
  the QUIC adapter) and has zero awareness of Consul.** It just
  bridges ports. It would equally well move Postgres replication,
  Redis Sentinel, Kafka, etc. — and in fact this example uses it for
  Patroni+Postgres replication.
- **Layer 0 is dumb infra.** Just a public IP running coturn + a tiny
  broker. Fungible and not in the data path once peers are connected.

If we ever run mesh-conn on a network where ICE can't punch through,
Layer 1 silently degrades to TURN relay through the coturn box.
Layer 2 doesn't notice; Layer 3 apps don't notice. They get higher
RTT, that's all.
