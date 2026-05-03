# Stage 4 — pickup notes

Read this first if you're returning to stage 4 after a break. It captures
the live cluster's address book, exactly what reproduces the open bug,
what was already tried (so we don't re-walk the same paths), and the
hypotheses worth fresh eyes — **without** committing to a fix direction.

## TL;DR

* Cluster is **alive and partially-working**. Consul Raft (3 servers)
  + 6 members + Patroni leader election all good. Leader accepts SQL
  writes. Replicas can't `pg_basebackup` because the worker↔worker
  mesh-conn link drops mid-transfer (~268 KB in).
* Three real mesh-conn bugs were found and fixed (instrumentation
  trace pinpointed them). The remaining drop is **not** a yamux
  framing issue and **not** a stale-state race — those classes are
  closed.
* Two debug switches exist (`MESH_CONN_RELAY_ONLY=1`,
  `MESH_CONN_TCP_ONLY=1`) — neither helps with the current bug, but
  they're useful for ruling more things out.

> **State note (2026-05-03):** the working tree under
> `stage4/mesh-conn/main.go` has been edited to swap yamux for
> QUIC (`github.com/quic-go/quic-go`) on top of the same pion/ice
> packet conn — see lines 350-420 for the new transport. There is
> also a sibling experimental directory `stage4/quic-on-ice/` with
> its own `go.mod` / `main.go`. Neither is committed and neither
> binary has been rebuilt + rolled, so the live cluster still runs
> the yamux build (image `ttl.sh/dstack-mesh-conn-1777773892:24h`).
> When picking back up: first decide whether to (a) ship the QUIC
> version (rebuild + roll), (b) keep yamux and chase one of the open
> hypotheses below, or (c) explore via the standalone
> `stage4/quic-on-ice/` testbed first.

## Live cluster (left running)

Phala dstack-pha-prod5, region US-WEST-1, all `tdx.small`. SSH gateway
domain: `dstack-pha-prod5.phala.network`. Each CVM is reachable via
the standard `openssl s_client` proxy:

```bash
ssh -o "ProxyCommand=openssl s_client -quiet -connect ${app_id}-22.dstack-pha-prod5.phala.network:443 2>/dev/null" \
    root@${app_id}-22.dstack-pha-prod5.phala.network "<cmd>"
```

| role | ordinal | app_id |
|------|---------|--------|
| coordinator-0 | 0 | `860ae2502cf1950c96fa51777b0e822ffe2466a2` |
| coordinator-1 | 1 | `a56f5b22e88264d446a15c96a7c2e80f4ec1e117` |
| coordinator-2 | 2 | `2c30e64fa15cdef27825e5857ecfc725c5b5df7c` |
| worker-3      | 3 | `eb94f7cd4f726ea3e90380e9043ed15c1f9e67e9` (Patroni leader) |
| worker-4      | 4 | `0e51c005457fbe994b55480aab06dfaf6c7f89b1` |
| worker-5      | 5 | `0889166bf09d84ea06e132c4b3cc7e2e7db586e0` |

Vultr coordinator host (coturn + signaling): `root@155.138.146.255`,
SSH key already authorized. signaling code is bind-mounted at
`/opt/dstack-mesh-coord/phase0/icetest/main.go` so live edits +
container restart picks up new code.

Per-port plan (`stage4-coord-0` ordinal 0 → port = base + 0):

| protocol | base |
|----------|------|
| serf_lan | 18000 |
| server_rpc | 18100 |
| http_api | 18200 |
| grpc | 18300 |
| webdemo | 18500 |
| sidecar_public | 18600 |
| postgres | 18700 |
| patroni_rest | 18800 |

## Currently deployed images (in `terraform.tfvars`)

```
bootstrap_secrets_image = ttl.sh/dstack-bootstrap-secrets-1777761148:24h
mesh_conn_image         = ttl.sh/dstack-mesh-conn-1777773892:24h   # latest with packetizing + TCP-only flag
signaling_image         = ttl.sh/dstack-signaling-1777761359:24h   # currently overridden by bind-mount on Vultr; live source is /opt/dstack-mesh-coord/phase0/icetest
webdemo_image           = ttl.sh/dstack-webdemo3b-1777715099:24h
sidecar_image           = ttl.sh/dstack-consul-sidecar-1777715113:24h
patroni_image           = ttl.sh/dstack-patroni-1777751805:24h
```

`ttl.sh` images live 24h. If you come back later than that, rebuild
from sources in `stage4/{mesh-conn,bootstrap-secrets,patroni}` and
`phase0/icetest`.

`PHALA_CLOUD_API_KEY` extraction (terraform needs it):

```bash
export PHALA_CLOUD_API_KEY=$(python3 -c "
import json; d=json.load(open('$HOME/.phala-cloud/credentials.json'))
print(d['profiles'][d['current_profile']]['token'])")
```

## The reproducer (60 seconds)

From any worker, the open bug shows up automatically — Patroni keeps
retrying `pg_basebackup` from the leader and failing in the same way.

```bash
W2=0e51c005457fbe994b55480aab06dfaf6c7f89b1   # any non-leader worker
GW=dstack-pha-prod5.phala.network
ssh ... root@${W2}-22.${GW} "
  docker logs --tail 50 dstack-mesh-conn-1 2>&1 | grep -E 'worker-3|yamux\\[worker-3' | tail -n 25
  echo
  docker logs --tail 15 dstack-patroni-1 2>&1 | tail -n 15
"
```

What you should see (from the trace at 02:02:39):

```
[worker-3] ice state: Connected
[worker-3] selected pair: relay 155.138.146.255:49160 <-> relay 155.138.146.255:49266 (proto=udp)
[worker-3] link up — 8 ports forwarded (udp+tcp), peer reachable via ICE
[worker-3] link: in=3628 (+3628 B/10s) out=3680 (+3680 B/10s)  reads=32 writes=50 streams=8
[worker-3] link: in=4183 (+555 B/10s)  out=266692 (+263012 B/10s) reads=51 writes=109 streams=11
[worker-3] link: in=4183 (+0 B/10s)    out=267142 (+450 B/10s)    reads=51 writes=125 streams=13
[worker-3] link: in=4183 (+0 B/10s)    out=268009 (+867 B/10s)    reads=51 writes=149 streams=15
[worker-3] final stats: in=4183 out=268009 reads=51 writes=149 streams=15
[worker-3] conn.Read err after 4183 bytes total / 52 reads: EOF
[worker-3] link failed: yamux accept: keepalive timeout — retrying in 5s
[worker-3] ice state: Closed
```

Pattern: link establishes via `relay <-> relay`, transfers ~268 KB
of pg_basebackup data in one burst, then the link dies with
`yamux accept: keepalive timeout` and ICE goes `Closed`. The
counterparty (worker-4) sees the same in mirror.

## What was already tried (don't re-do)

| Attempt | Result | Why kept / removed |
|---|---|---|
| `dialICE` cancels stuck `agent.Dial` on ICE Failed/Closed (commit `e2401fb`) | Fixed: peer slot no longer wedges forever after one ICE failure | Kept — required correctness |
| pollLoop drains buffered auth before pushing latest (commit `4c36c76`) | Fixed: stale auth from previous attempt no longer wins | Kept — required correctness |
| signaling broker drops sender's queue on new auth (commit `6e198c1`) | Fixed: epoch-style stale-message handling | Kept — required correctness |
| 65 535-byte packetizing adapter wrapping `ice.Conn` for yamux (commit `5c51dfa`) | Fixed: `ice.Conn.Read returns ErrShortBuffer` no longer corrupts yamux's stream | Kept — required correctness |
| `KeepAliveInterval=5s, ConnectionWriteTimeout=5s` | **Made it worse** — keepalive packet delayed by burst → 5 s timeout fires → link dies sooner | Reverted to defaults in `5c51dfa` |
| `MESH_CONN_RELAY_ONLY=1` | **Made it worse** — pion can't reliably establish relay-relay candidate pairs in our NAT (TURN allocation churn observable on coturn) | Kept as escape hatch, default off |
| `MESH_CONN_TCP_ONLY=1` (NetworkTypes filter only) | No change — pion still picks `relay (proto=udp)` | Kept as flag |
| `MESH_CONN_TCP_ONLY=1` *plus* URL filter to `Proto=TCP` | Still picks `relay (proto=udp)` — relay candidate's network is the *relayed* leg (always UDP unless RFC 6062 TCP-allocation requested), not the client→TURN leg | Kept as flag |

## Open hypotheses worth fresh eyes (no commitment to any)

These are angles I didn't have time/clarity to chase. Each one is a
*question to investigate*, not a fix to ship.

1. **Is yamux's "keepalive timeout" actually a keepalive issue, or
   is something else closing the conn and yamux is reporting that
   as the user-visible error?** The trace shows `conn.Read err: EOF`
   one line *before* the yamux timeout — meaning the underlying
   `ice.Conn` already returned EOF. yamux's keepalive then fails
   because the conn is gone, not because a keepalive packet was
   lost. **Investigate**: who closes `ice.Conn` and why? Is pion
   noticing connectivity loss and closing the agent?

2. **What does pion's `OnConnectionStateChange` actually fire
   between Connected and Closed?** Earlier traces showed
   `Disconnected` once, but our fix cancels dial on Failed/Closed
   only. If pion goes through `Disconnected → Failed` because the
   ICE keepalive fails (separate from yamux's keepalive), maybe
   there's a recovery path.

3. **What does coturn log on the relay between link-up and the
   drop?** The trace tells us *our* side closed; coturn might know
   why. Look at coturn debug log for the specific relay session
   (`5XXXX:...` allocation IDs in `docker logs ... coturn`) during
   a drop window.

4. **Asymmetric byte counts.** Worker-3 (leader) sends 268 KB OUT,
   receives 4 KB IN. That's pg_basebackup data going one way and
   the replication-protocol ACKs the other. If only the OUT path
   is busy and the IN path is idle, NAT mappings on the IN path
   may time out — and pion would lose the inbound STUN binding.
   **Investigate**: does pion's connectivity-check ping refresh
   both directions, or only the active one?

5. **Is yamux closing for a flow-control reason, not keepalive?**
   yamux has a `MaxStreamWindowSize` (default 256 KB). 268 KB
   transferred is suspiciously close. Maybe yamux's
   `RecvWindowUpdate` packets are being lost (small UDP packets
   particularly likely to be dropped after a burst). **Investigate**:
   does yamux's session log show window-update issues before the
   timeout?

6. **Coord links survive indefinitely under similar load.** Same
   binary, same TURN server. What's *different* about coord↔worker
   pairs vs worker↔worker pairs at the network level? Possibly:
   different NAT type on the coord CVMs.  **Investigate**: capture
   the selected ICE pair for a stable coord↔worker link and
   compare to a worker↔worker drop.

## Files to read first when starting

* `consul-postgres-ha/stage4/mesh-conn/main.go` — all the
  instrumentation + the `countingConn` packetizing adapter live here
* `consul-postgres-ha/stage4/README.md` — architecture context +
  "Known limitation" section pointing here
* `consul-postgres-ha/phase0/icetest/main.go` — signaling broker
  source, currently deployed via bind-mount on Vultr

## Recent commits worth reviewing

```
5c51dfa  fix: mesh-conn instrumentation + packetizing adapter (THIS PASS)
9bbc086  feat: relay-only escape hatch + document worker↔worker instability
6e198c1  fix: signaling broker drops sender's stale messages on new auth
4c36c76  fix: mesh-conn pollLoop must keep the LATEST auth, not the first
e2401fb  fix: full mesh + Connect mTLS demo working — three smoke fixes
2f96edc  feat: bring Patroni + Postgres back
17f4642  feat: multi-server Consul HA
```

## Useful one-liners

Snapshot Consul cluster state from coord-0:

```bash
C0=860ae2502cf1950c96fa51777b0e822ffe2466a2
ssh ... root@${C0}-22.${GW} "
  docker exec dstack-tester-1 sh -c '
    echo MEMBERS:
    curl -s http://127.0.0.1:18200/v1/agent/members | jq -r .[].Name | sort
    echo RAFT:
    curl -s http://127.0.0.1:18200/v1/status/peers
    echo LEADER:
    curl -s http://127.0.0.1:18200/v1/status/leader
  '"
```

Snapshot Patroni topology from any worker (needs leader's HTTP port):

```bash
W1=eb94f7cd4f726ea3e90380e9043ed15c1f9e67e9
ssh ... root@${W1}-22.${GW} "
  docker exec dstack-tester-1 sh -c 'curl -s http://127.0.0.1:18803/cluster | jq .'"
```

Write/read on leader (recovers superuser pw from TEE-derived secret):

```bash
W1=eb94f7cd4f726ea3e90380e9043ed15c1f9e67e9
PW=$(ssh ... root@${W1}-22.${GW} "cat /tmp/dstack-runtime/secrets/patroni-superuser")
ssh ... root@${W1}-22.${GW} "PGPASSWORD='$PW' docker exec -e PGPASSWORD dstack-patroni-1 \
  psql -h 127.0.0.1 -p 18703 -U postgres -d postgres -c 'SELECT * FROM demo;'"
```
