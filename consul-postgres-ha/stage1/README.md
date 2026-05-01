# Stage 1 — `mesh-conn` userspace L3 overlay over ICE

Builds on the [phase-0](../phase0/) finding that direct UDP hole-punching
works between two dstack CVMs. Stage 1 turns that into a proper L3
overlay so anything can run on top — Consul, web servers, whatever — and
addresses peers by stable virtual IPs.

## Layout

```
stage1/
├── README.md
├── docker-compose.yaml          two-service compose: mesh-conn + netshoot tester
└── mesh-conn/
    ├── go.mod / go.sum
    ├── main.go                  pion/ice + songgao/water TUN, single-peer MVP
    └── Dockerfile
```

## Components

- **mesh-conn**: per-CVM userspace daemon that
  1. opens a TUN device, assigns a virtual IP from a /24,
  2. establishes one pion/ice connection to its partner peer (signaling +
     STUN/TURN identical to phase-0),
  3. pumps L3 packets between TUN and the ICE socket, 1:1 (no framing —
     ICE rides on UDP, datagram boundaries are preserved).
- **tester** (netshoot sidecar with `network_mode: service:mesh-conn`):
  shares mesh-conn's net namespace so we can `ping`, `nc`, `curl`, and
  `tcpdump` against the virtual subnet without bringing in extra
  containers.

## MVP scope

Exactly two peers. PEER_ID and PARTNER_ID env vars distinguish the two
sides; the lex-smaller side calls `Dial`, the other calls `Accept`. Each
side gets its own `VIRTUAL_IP` (e.g. `10.66.0.1` and `10.66.0.2`). After
the ICE connection is up, `ping <other-virtual-ip>` from inside the
tester container should work.

Multi-peer support (one mesh-conn process holding N ICE links + TUN
routing for the whole subnet) is the next step.

## Required env vars

| var                  | what                                                |
| ---                  | ---                                                 |
| `MESH_CONN_IMAGE`    | published mesh-conn image (e.g. ttl.sh/...)         |
| `PEER_ID`            | this peer's identifier                               |
| `PARTNER_ID`         | the other peer's identifier                          |
| `SIGNALING_URL`      | `http://<coord>:7000` from phase-0                   |
| `TURN_HOST`          | coordinator host running coturn                      |
| `TURN_SHARED_SECRET` | coturn `--static-auth-secret`                       |
| `VIRTUAL_IP`         | this peer's IP on the overlay (e.g. `10.66.0.1`)     |

## Container requirements

- `cap_add: NET_ADMIN` for both `mesh-conn` and `tester` (so each can
  configure routes / interfaces in the shared netns).
- `/dev/net/tun` mounted into mesh-conn so it can open a TUN device.

## Status

- [x] Single-peer MVP compiled.
- [ ] Verified end-to-end on two dstack CVMs.
- [ ] Multi-peer extension.
- [ ] Consul running on top.
