# Stage 2 — Setting up Consul on the mesh-conn overlay

This walks through exactly how the 4-node Consul cluster (1 server +
3 clients) is configured to run across dstack CVMs that have **no
direct network connectivity** to each other. Everything Consul does
— gossip, RPC, HTTP API — flows through the userspace mesh-conn
overlay built in stage 1.

The non-obvious work is in the port plan and how Consul is told about
it. Once the ports are right, Consul itself doesn't know anything
unusual is happening.

## 0. The core trick: identity-port preservation

Each peer in the cluster owns a *unique port number per protocol*. On
every host, the local app binds its own ports; mesh-conn binds the
*other* peers' ports and forwards them through the ICE+yamux mesh.
mesh-conn preserves the source port so the receiving Consul agent
sees the packet as coming from `127.0.0.1:<sender's identity port>`,
which is exactly the address Consul uses to identify the sender.

So from inside any CVM, every peer (including yourself) is just
`127.0.0.1:<that-peer's-port>`. There is no virtual IP, no L3 overlay,
no awareness of remote vs local.

## 1. Allocate the port plan

Consul uses several distinct ports — pick them up front so each peer
can have its own value per protocol:

| index `i` | protocol     | transport | port formula |
| ---       | ---          | ---       | ---          |
| 0         | serf-LAN     | UDP+TCP   | `18000 + peer_index` |
| 1         | server-RPC   | TCP       | `18100 + peer_index` |
| 2         | HTTP API     | TCP       | `18200 + peer_index` |
| 3         | gRPC / xDS   | TCP       | `18300 + peer_index` |

Concretely for a 4-peer cluster:

| peer  | serf  | RPC   | HTTP  | gRPC  |
| ---   | ---:  | ---:  | ---:  | ---:  |
| ctrl  | 18000 | 18100 | 18200 | 18300 |
| w1    | 18001 | 18101 | 18201 | 18301 |
| w2    | 18002 | 18102 | 18202 | 18302 |
| w3    | 18003 | 18103 | 18203 | 18303 |

`PEERS_JSON` (passed to every CVM at deploy time, identical on every
peer):

```json
[
  {"id":"ctrl","ports":[18000,18100,18200,18300]},
  {"id":"w1","ports":[18001,18101,18201,18301]},
  {"id":"w2","ports":[18002,18102,18202,18302]},
  {"id":"w3","ports":[18003,18103,18203,18303]}
]
```

mesh-conn reads this, opens UDP+TCP listeners for every other peer's
port set on `127.0.0.1`, and runs one ICE+yamux session per peer-pair
that bridges all four protocol slots simultaneously.

## 2. Compose layout (per peer)

The same `docker-compose.yaml` runs on every CVM; the peer's role and
ports come in through env vars. Three services, all in
`network_mode: host`:

```yaml
services:
  mesh-conn:
    image: ${MESH_CONN_IMAGE}
    network_mode: host
    environment:
      - PEER_ID=${PEER_ID}
      - PEERS_JSON=${PEERS_JSON}
      - SIGNALING_URL=${SIGNALING_URL}
      - TURN_HOST=${TURN_HOST}
      - TURN_SHARED_SECRET=${TURN_SHARED_SECRET}

  consul:
    image: hashicorp/consul:1.19
    network_mode: host
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        if [ "$$ROLE" = "server" ]; then
          MODE_FLAGS="-server -bootstrap-expect=1 -ui"
        else
          MODE_FLAGS="-retry-join=127.0.0.1:$$CTRL_SERF_LAN_PORT"
        fi
        exec consul agent \
          -node=$$PEER_ID \
          -datacenter=dstack-mesh \
          -bind=127.0.0.1 \
          -advertise=127.0.0.1 \
          -client=127.0.0.1 \
          -serf-lan-port=$$SERF_LAN_PORT \
          -server-port=$$SERVER_PORT \
          -http-port=$$HTTP_PORT \
          -grpc-port=$$GRPC_PORT \
          -dns-port=-1 \
          -data-dir=/consul/data \
          -log-level=INFO \
          $$MODE_FLAGS
    environment:
      - PEER_ID=${PEER_ID}
      - ROLE=${ROLE}
      - SERF_LAN_PORT=${SERF_LAN_PORT}
      - SERVER_PORT=${SERVER_PORT}
      - HTTP_PORT=${HTTP_PORT}
      - GRPC_PORT=${GRPC_PORT}
      - CTRL_SERF_LAN_PORT=${CTRL_SERF_LAN_PORT}
    depends_on: [mesh-conn]

  tester:
    image: nicolaka/netshoot:latest
    network_mode: host
    command: ["sleep", "infinity"]
    depends_on: [mesh-conn, consul]
```

Why each detail matters:

- **`network_mode: host` everywhere.** With docker-bridge networking,
  STUN-discovered srflx mappings can't be reached back through the
  bridge NAT and ICE silently degrades to TURN-relay (we saw 163 ms
  RTT). Host networking puts the ICE socket directly on the CVM's
  outbound NAT mapping. Confirmed earlier in `stage1-mvp-results.md`.
- **`-bind=127.0.0.1`, `-advertise=127.0.0.1`.** The bind is
  loopback because mesh-conn lives there too. `advertise` is the
  address gossiped to peers; `127.0.0.1` is correct because each
  peer's mesh-conn translates `127.0.0.1:<port>` → that peer.
- **`-client=127.0.0.1`.** Restricts who can hit the local agent's
  HTTP/RPC/gRPC. Local apps and the netshoot tester can; nobody
  off-host can (which is fine — peers reach this agent via mesh-conn).
- **`-serf-lan-port` / `-server-port` / `-http-port` / `-grpc-port`.**
  Per-peer port overrides. Each agent advertises *its own* port set
  via gossip, so when peer A wants to RPC to peer B, A's Consul
  knows B's RPC port from gossip and dials `127.0.0.1:<B's RPC port>`
  on its own host — which mesh-conn forwards to B.
- **`-dns-port=-1`.** Disabled; nothing on this CVM needs Consul DNS
  in the demo, and turning it off avoids needing yet another port
  forwarded.
- **`-bootstrap-expect=1` only on ctrl.** Our setup has a single
  Consul server (acceptable for an experiment; for HA we'd run 3
  servers and bump this to 3).

## 3. Per-peer env at deploy time

For each `phala deploy` call, set:

```
PEER_ID            ctrl   |  w1   |  w2   |  w3
ROLE               server | client| client| client
SERF_LAN_PORT      18000  | 18001 | 18002 | 18003
SERVER_PORT        18100  | 18101 | 18102 | 18103
HTTP_PORT          18200  | 18201 | 18202 | 18203
GRPC_PORT          18300  | 18301 | 18302 | 18303
CTRL_SERF_LAN_PORT 18000  (same on every peer; workers retry_join here)
PEERS_JSON         (same JSON on every peer — see §1)
```

Plus the overlay-level env that's the same everywhere
(`MESH_CONN_IMAGE`, `SIGNALING_URL`, `TURN_HOST`, `TURN_SHARED_SECRET`).

The deploy is just four `phala deploy --compose stage2/docker-compose.yaml`
calls with these env permutations.

## 4. What happens when the CVMs come up

1. Each CVM boots, pulls images.
2. mesh-conn starts on every peer. Each instance:
   - registers with the signalling broker on the public coordinator
     host;
   - establishes 3 ICE connections (one per other peer), each direct
     hole-punched (logged as `selected pair: host <-> {prflx,srflx}`);
   - wraps each ICE conn in a yamux session;
   - opens 4 long-lived UDP streams per session (one per protocol
     port) and 4 corresponding TCP listeners on `127.0.0.1`;
   - reports `link up — 4 ports forwarded (udp+tcp), peer reachable
     via ICE`.
3. Consul starts on every peer. ctrl runs as server,
   `bootstrap-expect=1` so it elects itself leader immediately. Each
   worker's `-retry-join=127.0.0.1:$CTRL_SERF_LAN_PORT` causes it to
   join via the overlay; gossip propagates membership to the other
   workers within seconds.

The `ctrl` log shows the exact moment each worker joins:

```
[INFO] agent.server: member joined, marking health alive: member=w1
[INFO] agent.server: member joined, marking health alive: member=w2
[INFO] agent.server: member joined, marking health alive: member=w3
```

## 5. How to verify

From any CVM, via the netshoot sidecar:

```bash
# Membership — should show all 4
curl -s http://127.0.0.1:$HTTP_PORT/v1/agent/members \
  | jq -r '.[].Name'
# ctrl
# w1
# w2
# w3

# Leader — every peer should agree
curl -s http://127.0.0.1:$HTTP_PORT/v1/status/leader
# "127.0.0.1:18100"     <- ctrl's RPC port via the overlay

# Cross-peer KV write/read
# on w1:
curl -X PUT --data 'hello' http://127.0.0.1:18201/v1/kv/demo/key
# on w3:
curl http://127.0.0.1:18203/v1/kv/demo/key
# [{"Key":"demo/key","Value":"aGVsbG8=", ...}]   (Value base64-decodes to "hello")
```

## 6. Mental model

Consul never sees the overlay. It thinks every peer is on the same
loopback. The whole "this cluster spans four TEE-isolated CVMs that
can't reach each other" story lives entirely in mesh-conn's
identity-port-preserving forwarding plus the per-peer port overrides
in the Consul config. Two ideas glued together; everything else is
stock Consul.
