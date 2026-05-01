# Phase 0 — ICE feasibility on dstack

Goal: answer a single question before building anything else — **can a
dstack CVM hole-punch UDP to another dstack CVM?**

We don't yet know what dstack CVMs look like to the public network: do
they have outbound UDP egress at all, is the NAT cone or symmetric, is
the external port stable per source… Without this we can't tell whether
Consul gossip will run on a direct path, a TURN relay, or only over TCP.

## What this runs

A single Go binary (`icetest`) with two modes:

- `signaling`: tiny HTTP broker (~120 LoC) that ferries ICE candidates
  and `ufrag:pwd` pairs between two peers. Runs on the public coordinator
  host alongside coturn.
- `peer`: runs `pion/ice` against coturn (STUN+TURN, UDP+TCP), exchanges
  candidates with its partner via signaling, completes connectivity
  checks, and prints the winning candidate-pair type plus 20 RTT samples.

Two `peer` instances run on two throwaway dstack CVMs. The pair logs
tell us which transport ICE picked:

| Local type    | Remote type   | What it means                            |
| ---           | ---           | ---                                      |
| `host`        | `host`        | CVMs share an L2 (unlikely on dstack)    |
| `srflx`       | `srflx`       | Direct hole-punch worked. Best case.     |
| `srflx`/`prflx` mix | mix     | Asymmetric punching, still direct UDP.   |
| `relay`       | `*`           | Forced through TURN. Functional but slow.|

## Layout

```
phase0/
├── README.md                  (this file)
├── icetest/
│   ├── go.mod
│   ├── main.go                signaling + peer in one binary
│   └── Dockerfile
└── docker-compose.yaml        runs the peer in a CVM
```

The signaling service is run from `../coordinator/docker-compose.yaml`
on the public coordinator host (alongside coturn), via volume-mounted
`go run` so the public host doesn't need a separate image build.

## Running it

### 1. On the public coordinator host

```bash
export TURN_SHARED_SECRET=$(openssl rand -hex 32)
cd consul-postgres-ha/coordinator
docker compose up -d
# coturn on UDP/TCP 3478, TLS 5349; signaling on TCP 7000.
```

Confirm the host's public IP and that 3478/UDP+TCP, 5349/TCP, 7000/TCP
are reachable from the internet.

### 2. Deploy two dstack CVMs

For each of the two peers, set `PEER_ID`, `PARTNER_ID`,
`SIGNALING_URL=http://<coord>:7000`, `TURN_HOST=<coord>`, and the same
`TURN_SHARED_SECRET` chosen above. Then:

```bash
cd consul-postgres-ha/phase0
PEER_ID=peer-a PARTNER_ID=peer-b \
  SIGNALING_URL=http://<coord>:7000 \
  TURN_HOST=<coord> \
  TURN_SHARED_SECRET=<secret> \
  phala deploy -n phase0-peer-a -c docker-compose.yaml --node-id <node>

PEER_ID=peer-b PARTNER_ID=peer-a \
  SIGNALING_URL=http://<coord>:7000 \
  TURN_HOST=<coord> \
  TURN_SHARED_SECRET=<secret> \
  phala deploy -n phase0-peer-b -c docker-compose.yaml --node-id <node>
```

### 3. Read the result

```bash
phala cvm logs phase0-peer-a | tail -60
phala cvm logs phase0-peer-b | tail -60
```

Both peers should log a line like

```
CONNECTED via srflx <-> srflx
```

followed by `rtt=...` samples. Record the result (winning candidate
type, RTT min/median/max) in `../deploy/phase0-results.md`.

## Interpreting the result

- **direct (host/srflx/prflx)**: `mesh-conn` for stage 1 builds the
  fast path; `relay` becomes a fallback only.
- **relay only**: `mesh-conn` skips ICE candidate gathering and goes
  straight to TURN. Stage 1 still works, just with extra RTT and one
  more thing in the data path.
