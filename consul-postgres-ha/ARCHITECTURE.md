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
long-lived (one per UDP-bearing infra port, carrying length-prefixed
UDP datagrams), the rest are ephemeral (one per accepted TCP
connection).

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

## Layer 2 — peer-VIP / service-VIP plane

This is the trick that makes the overlay invisible to the applications
above. Two carved-out loopback `/24`s, allocated cluster-wide:

- **Peer VIPs** in `127.50.0.0/24` — one per peer (the peer's
  ordinal+1 in the example template). Identifies *who* a piece of
  infrastructure traffic is for.
- **Service VIPs** in `127.10.0.0/24` — one per Connect upstream a
  worker consumes (e.g. webdemo, postgres-master, postgres-replica).
  Identifies *what service* an app is calling.

mesh-conn binds a small **platform-supplied allowlist** on every
*other* peer's VIP and forwards each accepted connection to the right
remote peer over the QUIC link. With the 3-service example
(webdemo + postgres-master/-replica) the allowlist is:

| Port  | Used by                                               | Proto       |
|-------|-------------------------------------------------------|-------------|
| 21000 | Envoy Connect public mTLS — webdemo sidecar           | TCP         |
| 21001 | Envoy Connect public mTLS — postgres sidecar          | TCP         |
| 8300  | Consul server RPC (server-to-server, client-to-server)| TCP         |
| 8301  | Consul serf-LAN gossip                                | UDP + TCP   |

The allowlist is intentionally minimal — mesh-conn knows **peers,
not services**. Apps never dial peer VIPs; only Envoy and Consul-agent
do, and both speak well-known platform ports.

The allowlist is **platform-generated, not Go-const**: per-service
Connect-sidecar ports come from `local.services` in `cluster.tf`, get
collapsed into per-backend `sidecar_port`s, and the platform sidecar
emits `MESH_CONN_ALLOWLIST` env (JSON `[{port, udp}, …]`) at startup.
mesh-conn reads it once and binds accordingly. Adding a service is an
HCL edit in `cluster.tf`; mesh-conn never has to be rebuilt.

```
                  inside worker-3 CVM (network_mode: host)
   ┌───────────────────────────────────────────────────────────────────┐
   │ local apps + platform processes bind canonical ports on lo:       │
   │                                                                   │
   │   patroni / pg     ▶  127.0.0.1:5432  (postgres)                  │
   │                       127.0.0.1:8008  (patroni REST)              │
   │   webdemo          ▶  127.0.0.1:8080                              │
   │   envoy-webdemo    ▶  127.0.0.1:21000 (sidecar public mTLS)       │
   │   envoy-postgres   ▶  127.0.0.1:21001 (sidecar public mTLS)       │
   │   consul agent     ▶  127.0.0.1:8500  (HTTP)                      │
   │                       127.0.0.1:8502  (gRPC, Envoy xDS)           │
   │                       127.0.0.1:8301  (serf gossip)               │
   │                       127.0.0.1:8300  (server RPC; coords only)   │
   │                                                                   │
   │ loopback aliases (provisioned once at sidecar entrypoint):        │
   │                                                                   │
   │   127.50.0.<vip>/32  for every peer — peer VIPs                   │
   │   127.10.0.<vip>/32  per declared upstream — service VIPs         │
   │                                                                   │
   │ mesh-conn binds the allowlist on OTHER peers' VIPs, e.g. on       │
   │ worker-3:                                                         │
   │                                                                   │
   │   127.50.0.1:8301,8300,21000,21001  ◄── coord-0                   │
   │   127.50.0.2:8301,8300,21000,21001  ◄── coord-1                   │
   │   127.50.0.3:8301,8300,21000,21001  ◄── coord-2                   │
   │   127.50.0.5:8301,8300,21000,21001  ◄── worker-4                  │
   │   127.50.0.6:8301,8300,21000,21001  ◄── worker-5                  │
   │                                                                   │
   │ Envoy listens on the service VIPs for declared upstreams:         │
   │                                                                   │
   │   127.10.0.10:8080   →  cluster `webdemo`                         │
   │   127.10.0.20:5432   →  cluster `postgres-master`                 │
   │   127.10.0.21:5432   →  cluster `postgres-replica`                │
   │                                                                   │
   │ /etc/hosts maps service names → service VIPs, so apps just call   │
   │ `postgres-master:5432`.                                           │
   └───────────────────────────────────────────────────────────────────┘
```

Every peer has a symmetric layout: own ports bound by apps + Envoy +
Consul, other peers' VIP+allowlist bound by mesh-conn. Self's VIP is
also aliased on `lo` (local short-circuit: dialing
`127.50.0.<self-vip>:21000` routes through the kernel directly to
the local Envoy, no mesh-conn hop).

## Layer 3 — apps

Consul agents, Envoy sidecars, webdemo, Patroni, anything else. These
think they're talking to peers on `127.0.0.1` and to services by
name. They never see ICE, QUIC, TURN, or the public internet. Stock
HashiCorp Consul, stock Envoy, stock Patroni.

## How a single call traverses all four layers

A Connect-mTLS call from `worker-3`'s webdemo to whichever peer's
webdemo Envoy load-balances onto:

```
worker-3 webdemo
  GET http://webdemo:8080/hello                ── Layer 3, app dialing
  │   /etc/hosts → 127.10.0.10                    a service name
  ▼
worker-3 envoy-webdemo
  listener on 127.10.0.10:8080 (cluster `webdemo`)
  EDS endpoint pick → e.g. 127.50.0.5:21000 (worker-4's webdemo sidecar)
  opens mTLS to "127.50.0.5:21000"
  │
  ▼
worker-3 mesh-conn (TCP listener on 127.50.0.5:21000)
  reads bytes off the local TCP listener
  opens a QUIC stream tagged "port=21000"
  writes through the worker-3↔worker-4 QUIC connection      ── Layer 2 → 1
  │     ╱
  │    ╱  here Layer 1 (QUIC frames over the ICE conn)
  │   ╱   meets Layer 0 (UDP packets across the public
  │  ╱    internet, NAT-hairpinned via the provider edge)
  │ ╱
  ▼
worker-4 mesh-conn (QUIC stream accept on the worker-3 ICE conn)
  reads stream header → "port=21000" (allowlist-validated)
  dials TCP to 127.0.0.1:21000 (worker-4's webdemo sidecar)
  splices stream ↔ TCP conn                                 ── Layer 1 → 2
  │
  ▼
worker-4 envoy-webdemo
  validates origin's mTLS cert against Connect CA
  checks intention webdemo → webdemo (allow)
  forwards to local 127.0.0.1:8080 (LocalServicePort)
  │
  ▼
worker-4 webdemo
  serves /hello → "hello from worker-4"                     ── Layer 3
```

Reply takes the same path in reverse.

## Patroni replication uses the same path

A Patroni replica following the leader is just another consumer of
the `postgres-master` Connect upstream — no special case. The
replica's `primary_conninfo` carries `host=postgres-master port=5432`
(the same constant string registered as `postgresql.connect_address`
on every Patroni instance). The local Envoy at `127.10.0.20:5432`
proxies to the leader's `127.50.0.<leader-vip>:21001`, which lands
on the leader's postgres-sidecar Envoy and gets forwarded to local
`127.0.0.1:5432`. The Connect mesh stays in the data path for
streaming WAL + `pg_basebackup` — the 2× Envoy hop tax is the cost
of keeping mesh-conn workload-agnostic.

Service-resolver subsets pick the right peer:

```hcl
Kind = "service-resolver"
Name = "postgres"
Subsets = {
  master  = { Filter = "Service.Tags contains \"master\"" }
  replica = { Filter = "Service.Tags contains \"replica\"" }
}
```

Patroni auto-registers the parent `postgres` service with the
current role as a tag (`master` on the leader, `replica` on
followers). The subset filter strips down EDS endpoints to the right
peer's sidecar, and the `postgres-master` / `postgres-replica`
service-resolvers redirect to the right subset of `postgres`.

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

- One long-lived stream per UDP-bearing allowlist port (currently
  one: 8301 for serf gossip), carrying length-prefixed UDP
  datagrams.
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

The 16-bit `port` is the **receiver's local port to dial / write
into**. The receiver validates it against the static allowlist
(`{21000, 21001, 8300, 8301}`); anything else is rejected. There is
no per-peer port-list lookup — ports are platform-level constants
the same on every CVM.

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
- **Envoy → Envoy** is mTLS, certs signed by Consul's Connect CA
  (built-in CA provider; root in Raft, no external derivation).
  End-to-end across the overlay; mesh-conn just sees encrypted bytes.
- **mesh-conn → mesh-conn** rides ICE. Direct UDP between CVMs on the
  public internet (or TURN-relayed if hole-punching ever fails).
  pion/ice doesn't add encryption on top of the data path itself, so
  unencrypted traffic between mesh-conn endpoints would be on the wire
  in the clear.
- …all confidential traffic above it is **already encrypted by Envoy
  mTLS** (Layer 3), so the wire is safe even if someone could see the
  UDP datagrams.
- **Consul gossip** is encrypted via `-encrypt` (workaround: key
  generated in Terraform and broadcast via env; attestation-rooted
  admission will replace this with TEE-derived material). RPC is
  plaintext. Both are confined to inside the overlay, but a full
  setup would also configure TLS for RPC. See [ROBUSTNESS.md](ROBUSTNESS.md).

## What's nice about this shape

- **Layer 3 has zero awareness of layers below.** Consul, Envoy,
  webdemo, Patroni all think they're on a flat loopback talking to
  services by name. Anything that runs against Consul today (Vault,
  Nomad, Boundary, custom apps) drops in unchanged.
- **Layer 1 + 2 are a single component (mesh-conn, ~600 LoC Go
  including the QUIC adapter) and have zero awareness of services.**
  mesh-conn forwards bytes between peer VIPs on a static infra-port
  allowlist; it does not know what Consul, Patroni, or Envoy are.
  It would equally well move Postgres replication, Redis Sentinel,
  Kafka, etc. — and in fact this example uses it for both Consul
  cluster gossip and Patroni-replication-via-Envoy.
- **Layer 0 is dumb infra.** Just a public IP running coturn + a tiny
  broker. Fungible and not in the data path once peers are connected.

If we ever run mesh-conn on a network where ICE can't punch through,
Layer 1 silently degrades to TURN relay through the coturn box.
Layer 2 doesn't notice; Layer 3 apps don't notice. They get higher
RTT, that's all.
