# Architecture

Three layers stacked, each unaware of the one below it. Plus the apps
running on top of all of it.

## Layer 0 — physical / dstack reality

Four dstack CVMs (`ctrl`, `w1`, `w2`, `w3`), TEE-isolated, sitting
behind Phala's provider NAT. **They cannot reach each other directly**
on any L3 path. The only thing they share is outbound internet
egress.

Plus one plain Linux box with a public IP (`155.138.146.255`) running
`coturn` (STUN/TURN) and a tiny HTTP signalling broker. This is
rendezvous infrastructure only — once peers have ICE-handshaked, no
data passes through it (in our deployment ICE always picks the direct
hole-punched path; TURN is the available fallback).

```
                      coturn + signalling
                      155.138.146.255
                              ▲
                outbound      │ STUN binding
                UDP+TCP       │ ICE candidate exchange
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
   [ctrl CVM]            [w1 CVM]              [w2 CVM]    [w3 CVM]
                          (no L3 connectivity to each other)
```

## Layer 1 — mesh-conn pair-wise overlay

For every **pair** of peers, mesh-conn establishes one `pion/ice`
connection. ICE punches a direct UDP path through the NAT (in our
deployment NAT-hairpinned to `66.220.6.105`, see
[deploy/phase0-results.md](deploy/phase0-results.md)) and stays put.
The signalling broker drops out of the picture once each pair is up.

Per pair we then run **one yamux session** over the ICE conn. Yamux
multiplexes streams; some are long-lived (one per protocol port,
carrying length-prefixed UDP datagrams), the rest are ephemeral (one
per accepted TCP connection).

```
            ┌── ICE conn / yamux ──┐
   ctrl ◄══►│      direct UDP      │◄══►  w1
            └── (NAT hairpin)      ┘
   ctrl ◄══►━━━━━━━━━━━━━━━━━━━━━━━◄══►  w2
   ctrl ◄══►━━━━━━━━━━━━━━━━━━━━━━━◄══►  w3
   w1   ◄══►━━━━━━━━━━━━━━━━━━━━━━━◄══►  w2
   w1   ◄══►━━━━━━━━━━━━━━━━━━━━━━━◄══►  w3
   w2   ◄══►━━━━━━━━━━━━━━━━━━━━━━━◄══►  w3
```

Six ICE connections in a 4-peer full mesh (4×3/2). Each peer maintains
three of them.

## Layer 2 — identity-port plane

This is the trick that makes the overlay invisible to the applications
above. Every peer has a unique port for every protocol. mesh-conn
binds the **other** peers' identity ports on `127.0.0.1` and bridges
each one to the right ICE+yamux peer link, **preserving source ports**
so the destination app sees the packet as coming from
`127.0.0.1:<sender's identity port>` — which is exactly what the app
uses to identify the sender.

So inside any CVM the entire cluster looks like a single loopback
host:

```
                       inside w1 CVM (network_mode: host)
   ┌───────────────────────────────────────────────────────────────────┐
   │ local apps bind their OWN ports:                                  │
   │                                                                   │
   │   consul agent      ▶  127.0.0.1:18001 (serf)  18101 (rpc)        │
   │                        18201 (http)   18301 (grpc)                │
   │   webdemo           ▶  127.0.0.1:18501                            │
   │   envoy sidecar     ▶  127.0.0.1:18601 (public mTLS)              │
   │                        127.0.0.1:19000 (upstream → "webdemo")     │
   │                                                                   │
   │ mesh-conn binds OTHER peers' identity ports on 127.0.0.1:         │
   │                                                                   │
   │   18000, 18100, 18200, 18300, 18500, 18600  ◄── ctrl              │
   │   18002, 18102, 18202, 18302, 18502, 18602  ◄── w2                │
   │   18003, 18103, 18203, 18303, 18503, 18603  ◄── w3                │
   │                                                                   │
   │ all UDP/TCP traffic to those ports is shipped through the         │
   │ matching ICE+yamux session to the corresponding peer.             │
   └───────────────────────────────────────────────────────────────────┘
```

Every peer has the symmetric layout — own ports bound by apps, other
peers' ports bound by mesh-conn.

## Layer 3 — apps

Consul agents, Envoy sidecars, webdemo, anything else. These think
they're talking to peers on `127.0.0.1`. They never see ICE, yamux,
TURN, or the public internet. Stock HashiCorp Consul, stock Envoy.

## How a single call traverses all four layers

A Connect-style mTLS call from w1's webdemo to w3's webdemo:

```
w1 webdemo
  GET http://127.0.0.1:19000/hello             ── Layer 3, app on its
  │                                                local sidecar upstream
  ▼
w1 envoy sidecar
  picks endpoint via Consul-supplied EDS
  opens mTLS to "127.0.0.1:18603" (w3's sidecar — really mesh-conn's listener)
  │
  ▼
w1 mesh-conn (port 18603 TCP listener)
  reads bytes off the local TCP listener
  opens a yamux TCP-stream tagged "port=18603"
  writes through the w1↔w3 ICE session                      ── Layer 2 → 1
  │     ╱
  │    ╱  here is where Layer 1 (raw bytes over the
  │   ╱   ICE conn / yamux mux) meets Layer 0 (UDP
  │  ╱    packets across the public internet, NAT-
  │ ╱     hairpinned to 66.220.6.105)
  ▼
w3 mesh-conn (yamux stream accept on the w1 ICE conn)
  reads stream header → "port=18603"
  dials TCP to 127.0.0.1:18603 (w3's actual sidecar)
  splices stream ↔ TCP conn                                 ── Layer 1 → 2
  │
  ▼
w3 envoy sidecar
  validates origin's mTLS cert against Connect CA
  checks intention webdemo → webdemo (allow)
  forwards to local 127.0.0.1:18503 (LocalServicePort)
  │
  ▼
w3 webdemo
  serves /hello → "hello from w3"                           ── Layer 3
```

Reply takes the same path in reverse.

## mesh-conn × yamux — how they work together

The bit that's worth being precise about: mesh-conn is built on top
of pion/ice and HashiCorp's yamux. The wire layout is small enough to
write down completely.

### What mesh-conn has after ICE

After the ICE handshake, mesh-conn has one thing per peer-pair:

```go
conn *ice.Conn   // duplex byte stream over the punched UDP path
```

`ice.Conn` is a `net.Conn`-shaped object. The wire underneath is one
UDP socket, but pion/ice already deals with retransmits and ordering —
from mesh-conn's perspective, it's a reliable bidirectional byte
stream. We never write raw datagrams; we use it like a TCP-ish conn.

### Why yamux

We need to carry **multiple logical channels** over that one byte
stream:

- one long-lived "UDP pipe" per identity port (4 of these for stage
  2, 6 for stage 3b — one per protocol)
- one TCP stream per accepted local TCP connection (open and close
  on demand, dozens at a time during normal Consul + Connect
  operation)

Yamux is HashiCorp's stream-multiplexer in pure Go. Takes a `net.Conn`
and gives back a `Session` that can `OpenStream()` and
`AcceptStream()`, where each `Stream` is itself a `net.Conn`. Frames
(12-byte header) interleave on the wire; flow control is per-stream.

### Client / server roles

Yamux is asymmetric: one side runs `yamux.Client(conn, cfg)`, the
other runs `yamux.Server(conn, cfg)`. The protocol works in both
directions equally — either side can `OpenStream()` — but they need
to disagree on the role.

mesh-conn picks the role from peer IDs in lex-order, the same
convention used for ICE Dial vs Accept:

```go
isClient := cfg.SelfID < peer.ID
if isClient {
    sess, err = yamux.Client(conn, ycfg)
} else {
    sess, err = yamux.Server(conn, ycfg)
}
```

### Stream protocol (mesh-conn's framing on top of yamux)

When a yamux stream opens, the **first 3 bytes** carry a tiny
mesh-conn-level header that tells the receiver what to do with the
stream:

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

### What happens at session boot

```
client side                                server side
─────────────                              ─────────────
yamux.Client(iceConn)                      yamux.Server(iceConn)
   │                                          │
   │  for each port in peer.Ports:            │  acceptLoop():
   │     OpenStream()                         │     stream := AcceptStream()
   │     write [0x55, port_hi, port_lo]    ──►│     read 3-byte header
   │     keep stream as udpStreams[i]         │     match port → self.Ports[idx]
   │                                          │     udpStreams[idx] = stream
   │                                          │
   │  bind UDP+TCP listeners on               │  bind UDP+TCP listeners on
   │  127.0.0.1:<each peer.Ports[i]>          │  127.0.0.1:<each peer.Ports[i]>
   │                                          │
   ▼                                          ▼
        ─── start the four pumps (next) ───
```

The server's accept loop keeps running for the lifetime of the
session. After the initial UDP streams are registered, every later
incoming stream tagged `0x33` is treated as a TCP forward.

### The four pumps (per protocol port, on each side)

For every protocol port both sides bind a UDP socket, and four
goroutines run continuously to shuttle bytes:

```
  app  ──UDP──► [sock]  ─pump1─►  [udpStream] ─yamux─►  [udpStream]  ─pump2─►  [sock] ──UDP──►  app
                                       ICE conn
  app  ◄──UDP── [sock]  ◄─pump2─  [udpStream] ◄─yamux─  [udpStream]  ◄─pump1─  [sock] ◄──UDP──  app
```

Concretely the pump bodies (UDP path):

```go
// pump1: take a UDP datagram off the local socket, write it
// length-prefixed to the udpStream, where yamux frames and ships it.
func pumpUDPSockToStream(sock *net.UDPConn, s *yamux.Stream) error {
    buf, frame := make([]byte, 1500), make([]byte, 2+1500)
    for {
        n, _, err := sock.ReadFromUDP(buf)
        if err != nil { return err }
        binary.BigEndian.PutUint16(frame[:2], uint16(n))
        copy(frame[2:], buf[:n])
        s.Write(frame[:2+n])              // yamux Stream.Write
    }
}

// pump2: read length-prefixed datagrams off the stream, deliver them
// to the local socket with `dst` = 127.0.0.1:<self port>.
// The receiving app sees the packet land on its own identity port,
// with source = the socket's bound port (= sender's identity port).
func pumpUDPStreamToSock(s *yamux.Stream, sock *net.UDPConn, dst *net.UDPAddr) error {
    hdr, buf := make([]byte, 2), make([]byte, 65536)
    for {
        if _, err := io.ReadFull(s, hdr); err != nil { return err }
        n := int(binary.BigEndian.Uint16(hdr))
        if _, err := io.ReadFull(s, buf[:n]); err != nil { return err }
        sock.WriteToUDP(buf[:n], dst)
    }
}
```

Important bit: `yamux.Stream` is stream-oriented (like TCP), so we
**must** length-prefix our UDP datagrams ourselves — otherwise we'd
lose datagram boundaries. This is the only place mesh-conn does
explicit framing.

### TCP streams are simpler — no framing needed

```go
// Local TCP listener: each Accept opens a fresh yamux stream.
func acceptLocalTCP(lis *net.TCPListener, sess *yamux.Session, dstPeerPort int) error {
    for {
        c, _ := lis.AcceptTCP()
        go func(c *net.TCPConn) {
            defer c.Close()
            s, _ := sess.OpenStream()
            defer s.Close()
            s.Write([]byte{streamTCP, byte(dstPeerPort >> 8), byte(dstPeerPort)})
            spliceBoth(s, c)            // io.Copy in both directions
        }(c)
    }
}

// On the receiving side: when a stream opens with streamTCP tag,
// dial the matching local TCP service and splice.
func handleIncomingTCP(s *yamux.Stream, dst *net.TCPAddr) {
    defer s.Close()
    c, _ := net.DialTCP("tcp", nil, dst)
    defer c.Close()
    spliceBoth(s, c)
}
```

`spliceBoth` is two `io.Copy` goroutines, exits when either side
finishes. The TCP path needs no length prefix because both ends are
stream-oriented — yamux preserves order, the app underneath doesn't
care about packet boundaries.

### Why this gives us everything we need

Yamux's **flow control + ordered delivery** are exactly the right
primitives for both kinds of traffic:

- TCP forwarding gets a transparent byte conduit. Envoy's mTLS and
  Consul's RPC don't even know they're running on yamux instead of a
  real TCP socket.
- UDP forwarding: yamux's order-preservation means our length-prefixed
  datagrams never get torn or reordered between the two pumps. It
  does add **head-of-line blocking** — a long TCP send can briefly
  delay a UDP datagram — but for Consul-volume traffic that's
  invisible.

The whole thing is **one ICE conn per peer-pair, one yamux session per
ICE conn**, plus a 3-byte header per stream and a 2-byte length prefix
per UDP datagram. That is the entirety of mesh-conn's wire format.

### What yamux gives us for free

- **Stream multiplexing** — both kinds of traffic and the per-port
  channels share one ICE conn without interference.
- **Per-stream flow control** — a slow consumer on one stream doesn't
  block other streams.
- **Half-close semantics** — TCP-style FIN on the stream. `io.Copy`
  exits cleanly when the app on the other side closes its socket.
- **Keep-alive pings** — `EnableKeepAlive: true` makes yamux send
  pings; if the ICE conn dies, the session detects it and the pumps
  return errors instead of hanging.

If we hadn't picked yamux, we'd have written all of those by hand.

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
- **Layer 1 is a single component (mesh-conn, ~330 LoC Go) and has
  zero awareness of Consul.** It just bridges ports. It would equally
  well move Postgres replication, Redis Sentinel, Kafka, etc.
- **Layer 0 is dumb infra.** Just a public IP running coturn + a tiny
  broker. Fungible and not in the data path once peers are connected.

If we ever run mesh-conn on a network where ICE can't punch through,
Layer 1 silently degrades to TURN relay through the coturn box.
Layer 2 doesn't notice; Layer 3 apps don't notice. They get higher
RTT, that's all.
