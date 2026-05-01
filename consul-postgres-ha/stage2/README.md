# Stage 2 — Consul cluster over the mesh-conn overlay

Builds on stage-1's multi-port port-forwarder. Each peer now also runs a
Consul agent. The control CVM is a single-node Consul server; the three
workers are Consul clients that gossip + RPC to the server through the
overlay.

## Why each peer needs four ports

Consul advertises one bind address per agent and uses several different
ports for distinct protocols. We have to give each peer its own
identity-port for *each* protocol so the source-port-preservation trick
stays correct everywhere:

| index | protocol      | transport | port = 18`000` + 100·i + peer-index |
| ---   | ---           | ---       | ---                                |
| 0     | serf-LAN      | UDP+TCP   | 18000–18003                        |
| 1     | server-RPC    | TCP       | 18100–18103                        |
| 2     | HTTP API      | TCP       | 18200–18203                        |
| 3     | gRPC / xDS    | TCP       | 18300–18303                        |

So `ctrl`'s Consul binds `serf=18000, rpc=18100, http=18200, grpc=18300`
and worker `w1`'s binds `serf=18001, rpc=18101, http=18201, grpc=18301`,
and so on. From w1's perspective, ctrl is reachable at
`127.0.0.1:18000` (mesh-conn forwards), and ctrl's RPC at
`127.0.0.1:18100`. Symmetric on every peer.

## How Consul gossips peer ports

Each Consul agent gossips its own per-protocol port numbers as part of
the serf member-info. So once any peer A learns peer B exists (via
`retry_join` or via gossip transitively), A's Consul knows B's bind
address (`127.0.0.1`) and ports — and dials `127.0.0.1:<B's RPC port>`
when it needs to RPC to B. mesh-conn-A binds that port locally and
forwards the connection to B.

## Run

Image build / signalling host etc. exactly as in stage-1. Per-CVM env
vars:

```
PEER_ID=ctrl|w1|w2|w3
PEERS_JSON=[{"id":"ctrl","ports":[18000,18100,18200,18300]},
            {"id":"w1","ports":[18001,18101,18201,18301]},
            {"id":"w2","ports":[18002,18102,18202,18302]},
            {"id":"w3","ports":[18003,18103,18203,18303]}]
ROLE=server  (ctrl) | client  (workers)
SERF_LAN_PORT, SERVER_PORT, HTTP_PORT, GRPC_PORT — peer's own ports
CTRL_SERF_LAN_PORT=18000   # workers retry_join here
SIGNALING_URL, TURN_HOST, TURN_SHARED_SECRET   # same as phase-0
```

Verify after deploy: from any peer

```
docker exec dstack-tester-1 sh -c 'curl -s http://127.0.0.1:$$HTTP_PORT/v1/status/peers'
docker exec dstack-tester-1 sh -c 'curl -s http://127.0.0.1:$$HTTP_PORT/v1/agent/members | jq ".[].Name"'
```

should show all four nodes.
