# Stage 1 — `mesh-conn` UDP port-forwarder over ICE

Builds on the [phase-0](../phase0/) finding that direct UDP hole-punching
works between dstack CVMs. Stage 1 turns that into a tiny userspace
agent that bridges localhost UDP sockets across CVMs through one
pion/ice connection per peer-pair. No TUN device, no kernel routing,
no virtual L3 — apps just bind localhost and address peers by their
identity port on `127.0.0.1`.

## Naming convention

Every peer in the cluster has a unique 16-bit "identity port". On every
peer's host:

- the local app binds `127.0.0.1:<own_port>` (its own identity)
- `mesh-conn` binds `127.0.0.1:<other_peer_port>` for every OTHER peer
- to reach peer X, the app sends UDP to `127.0.0.1:<X_port>`

`mesh-conn` ships those packets through one ICE connection per peer-pair
(direct-when-possible, TURN-relay-when-not — pion/ice picks the best
candidate transparently). Replies use the same socket so the peer sees
the source as `127.0.0.1:<X_port>`, matching what its app expects.

## Layout

```
stage1/
├── README.md
├── docker-compose.yaml          mesh-conn + netshoot tester (host net)
└── mesh-conn/
    ├── go.mod / go.sum
    ├── main.go                  ~280 LoC; pion/ice + per-peer UDP socket
    └── Dockerfile
```

## Required env vars

| var                  | what                                                              |
| ---                  | ---                                                               |
| `MESH_CONN_IMAGE`    | published image (e.g. `ttl.sh/...`)                               |
| `PEER_ID`            | this peer's identifier                                             |
| `PEERS_JSON`         | JSON list of all peers, e.g. `[{"id":"a","port":18001},{"id":"b","port":18002}]` |
| `SIGNALING_URL`      | `http://<coord>:7000` from phase-0                                 |
| `TURN_HOST`          | coordinator host running coturn                                    |
| `TURN_SHARED_SECRET` | coturn `--static-auth-secret`                                     |

## Container requirements

- `network_mode: host` — without this, ICE picks the TURN-relay path
  because docker-bridge NAT prevents srflx replies from reaching back
  through the bridge. Result: ~163 ms RTT instead of ~6 ms (see
  `../deploy/stage1-mvp-results.md`).

## Status

- [x] Phase-0 confirmed direct UDP hole-punch between CVMs.
- [x] TUN-based MVP confirmed arbitrary IP traffic flows over the ICE
      pipe (committed earlier; later replaced by the port-forwarder).
- [x] Port-forwarder rewrite (this version).
- [ ] Verified end-to-end on two CVMs.
- [ ] Multi-peer (N > 2) verification.
- [ ] Consul running on top.
