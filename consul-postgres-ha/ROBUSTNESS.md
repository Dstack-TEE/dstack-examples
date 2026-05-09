# Robustness review

We've assembled a tower of clever-ish components: CVMs behind a NAT,
ICE hole-punch, QUIC stream multiplexer, identity-port forwarding, Consul +
Envoy mTLS on top. Each layer earns its keep — but that's exactly
when it's worth being honest about how the whole thing fails.

This doc walks each of the four layers, asks "what breaks, and what
do we do about it?", and lands on a prioritised punch list.

## Mental model

```
  Layer 3   apps         Consul + Envoy + webdemo
                         (HashiCorp / Lyft code, well-trodden)
  Layer 2   forwarder    mesh-conn ~700 LoC: per-peer port plan,
                         source-port preservation
  Layer 1   transport    pion/ice + QUIC: punched UDP path,
                         stream multiplex, flow control, keepalive
  Layer 0   rendezvous   coturn + signalling broker on a public box;
                         dstack CVMs behind a provider NAT
```

The risks fall into three buckets:

- **operational**: things that fail in normal life and want
  watchdogs, retries, healthchecks, runbooks.
- **structural**: SPOFs, capacity ceilings, missing redundancy.
- **boutique-protocol**: bugs we could write into our 330-LoC
  shim that would manifest as hard-to-debug stalls.

The "are we playing too many tricks?" question really resolves to
the third bucket. Most of the stack uses well-trodden libraries; the
clever-and-ours bits are the identity-port plan and the 3-byte
stream header. Both are simple enough to audit, but exactly because
they're ours, they're the parts that *must* be made robust by hand.

## Layer 0 — rendezvous infra

### What's there

- one public-IP host (currently `155.138.146.255`, Vultr) running
  `coturn` (STUN+TURN UDP/TCP) and a Go HTTP signalling broker
- the dstack CVMs themselves, which sit behind Phala's provider NAT

### What can break

| failure                           | impact                                                                | recovery |
| ---                               | ---                                                                   | ---      |
| Coordinator host dies             | New peers can't bootstrap. **Existing ICE pairs keep working** (no data flows through this box once handshake is done). New retries from existing peers fail until it's back. | bring it back; peers reconnect on their own. |
| Coordinator ufw / network change  | Same as above.                                                       | restore ports 3478/udp+tcp, 5349/tcp, 7000/tcp, 49152-49999/udp. |
| TURN shared secret leaks          | Anyone can use the box as an open TURN relay (cost / abuse risk).    | rotate `TURN_SHARED_SECRET` in coordinator + every CVM env, redeploy. |
| Signalling broker is unauthenticated | Any external actor can publish/poll messages, spoof candidates, intercept ICE handshakes. Currently low-impact only because we're solo. | gate `/publish` + `/poll` on attestation-derived identity (Stage 4 work). |
| dstack provider NAT changes type (e.g. cone → symmetric) | ICE picks TURN relay path. ~150 ms RTT instead of ~6 ms. **Functionality unchanged.** | none needed; coturn covers this fallback. |
| Underlying CVM dies               | That peer's services drop out. Consul will mark it `failed` after gossip timeout, Envoy LB removes it within seconds. | redeploy; the rest of the cluster is unaffected. |

### Risk shape

Coordinator host is a **single point of failure for NEW joins** and
a SPOF for the TURN-relay fallback path. It is **NOT a SPOF for
established traffic** — established peers ICE-direct and don't
touch it. So dying coordinator = "no new peers can join, and any pair
whose direct path goes down can't fail over to TURN until it's back".

### Recommended fixes

1. **Run two coordinators in different ASes**, give peers both URLs
   in `SIGNALING_URL` / `TURN_HOST` (pion supports a list). One dies
   → other still serves.
2. **Treat coordinator as untrusted transport.** That's already the
   posture for the data path (Envoy mTLS protects payloads), so
   compromise of a coordinator just leaks metadata. The thing that's
   *not* covered today is signalling-message spoofing — should add
   AppAuth-rooted signatures on `auth` + `candidate` messages so a
   compromised broker can't impersonate a peer.

## Layer 1 — pion/ice + QUIC

### What's there

- one ICE connection per peer-pair (6 in our 4-CVM cluster),
  established via signalling broker + coturn
- one `QUIC.Session` per ICE conn, with `EnableKeepAlive=true`
- the streams flowing inside (one long-lived UDP-per-port,
  on-demand TCP-per-conn)

### What can break

| failure                               | impact                                                                | recovery |
| ---                                   | ---                                                                   | ---      |
| ICE conn drops (NAT timeout, route change, peer reboot) | QUIC session ends. All streams over it break. Pumps return errors. | mesh-conn's `runPeerLink` catches the error and re-runs `dialAndPump` after a 5s sleep. |
| ICE state stalls without dropping (pion bug) | Streams hang. QUIC keep-alive ping eventually fails → session ends → restart loop kicks in. | automatic via keep-alive timeout. |
| `pion/ice` panics                     | Whole mesh-conn process crashes; Docker restart policy `on-failure` brings it back. | automatic; ICE re-handshakes on next start. |
| QUIC session can't be created (handshake mismatch) | mesh-conn errors out, retry loop. | automatic. |
| ICE state goes Failed/Closed without `Dial`/`Accept` returning | Without intervention, `agent.Dial` / `agent.Accept` would block forever — pion doesn't surface terminal states through the dial context. `dialICE` registers an `OnConnectionStateChange` handler that cancels its dialCtx on Failed/Closed, so the dial returns and `runPeerLink` retries. | automatic. |
| Resource exhaustion (many TCP streams) | QUIC per-session limits kick in (256 streams default); new TCP streams to that peer fail. UDP and existing TCP unaffected. | bump `AcceptBacklog` / `MaxIncomingStreams` if it ever hits us at scale. |
| Head-of-line blocking | A big TCP write on one stream briefly delays a UDP datagram or another TCP stream. Imperceptible at Consul scale. | None needed today. If a future workload becomes jitter-sensitive, split into two ICE conns per pair (UDP-only + TCP-only). |

### Recommended fixes

1. **Set a QUIC read deadline on the UDP-stream pumps**, so if a
   stream silently stalls (QUIC keep-alive happens at session
   level, not stream level), the pump returns and `runPeerLink`
   restarts.
2. **Tune QUIC `MaxStreamWindowSize`** if we ever need higher
   throughput; default is 256 KB which is fine for now.

### Already shipped

- **Auth-channel reconnect path is clean.** Each `dialICE` call
  installs a fresh `peerSession{}` (fresh `authCh`) via
  `installSession()` and atomically swaps `sessions[remoteID]`, so
  any auth that was delivered to a prior failed attempt is left
  unreferenced. `pollLoop` does drain-then-push on the auth channel,
  so the channel always holds the *latest* auth and `dialICE`
  can't consume a stale ufrag/pwd from before the peer's last
  bounce. Verified by inspection of `mesh-conn/main.go:817-822` and
  `:1006-1016`; the original bug described in earlier revisions of
  this doc is closed.

## Layer 2 — mesh-conn forwarder

### What's there

- the per-peer port plan (PEERS_JSON)
- the 3-byte stream header (tag, port-uint16-BE)
- the per-stream pumps (UDP length-prefix, TCP raw splice)
- one accept-loop per peer pair to demux incoming streams

### What can break

| failure                          | impact                                                              | recovery |
| ---                              | ---                                                                 | ---      |
| Two peers configured with the same identity port | mesh-conn refuses to start with an explicit `port X claimed by both A and B` error and crashes the container before any link comes up. | already handled — `validatePeers()` runs at startup, see "Already shipped" below. |
| Peer count mismatch in PEERS_JSON | `validatePeers()` rejects with `peer X has N ports, expected M` before any goroutine starts. | already handled. |
| Local app binds same port as mesh-conn forwarder for a peer | EADDRINUSE; whichever started second loses. | enforce in compose / startup ordering. |
| **mesh-conn dies** | All peer-pair links from this CVM drop. QUIC + ICE on every other peer notice via keep-alive within ~30 s and tear down. Consul agent gossip-timeouts (~10 s default) drop this CVM from the catalog. Sidecars on other peers stop sending here. | container `restart: on-failure` brings it back; everyone re-handshakes. |
| **Source-port-preservation breaks** (e.g. someone changes port plan and forgets to update an app) | Receiving Consul agent sees gossip from "wrong" address, labels it as a new node, may try to add it to membership; cluster gets confused. | add an integration test that boots cluster + writes KV from each peer + reads from each peer. |
| 3-byte header parse confusion | Receiver gets a malformed header, currently logs and closes the stream. Other streams unaffected. | already handled defensively. |

### Risk shape

mesh-conn is the smallest piece of code in the stack but also the
one that is **uniquely ours**. Failures here are the hardest to
diagnose because there's no Stack Overflow for our 3-byte header
protocol.

The mitigations are mostly testing discipline:

- a small integration test that brings up 3+ peers in containers
  locally, runs cross-peer UDP echo + TCP echo + QUIC burst, on
  every CI run.
- a fault-injection mode that randomly kills the ICE conn — to
  exercise the reconnect path (which is where the real bug lives).
- explicit logging: the current code logs link-up / link-down /
  selected ICE pair / stream counts. Could add periodic stream
  count + bytes counters to catch slow leaks.

### Recommended fixes

1. **Add a loopback integration test** that runs mesh-conn ↔
   mesh-conn locally with a real signalling broker on `127.0.0.1`.
   Catches protocol-level regressions (3-byte header, port plan)
   without burning CVMs. The unit tests in `validate_test.go` cover
   config-time bugs but not the wire format.
2. **Periodic metrics** — counters for streams open/closed, bytes
   in/out per port. A `/metrics` endpoint or even just stderr every
   30 s.

### Already shipped

- **PEERS_JSON validation at startup** — `validatePeers()` in
  `mesh-conn/main.go:182` runs before any goroutine starts and
  fails fast on duplicate IDs, missing self, mismatched port-list
  lengths, port collisions, empty port lists, or out-of-range
  ports. A canonicalised `peersDigest()` is logged at startup so
  `grep` across all peers' logs immediately surfaces config
  drift. Nine unit tests in `validate_test.go` cover the cases.

## Layer 3 — Consul + Envoy + apps

### What's there

- three Consul servers (Raft quorum) on the coordinator CVMs, three
  clients on the worker CVMs
- Connect enabled, default CA, allow intention webdemo→webdemo
- Envoy sidecars front-running each webdemo and Patroni
- gossip key NOT set; RPC TLS NOT set

### What can break

| failure                          | impact                                                              | recovery |
| ---                              | ---                                                                 | ---      |
| One Consul server CVM dies       | Quorum survives (2 of 3). All cluster ops continue. | dstack recreates the CVM on next `terraform apply`; Consul rejoins, Raft re-replicates. |
| **Two Consul server CVMs die at once** | No quorum. Workers can still gossip, but: cannot register/deregister services, cannot mint Connect leaf certs, cannot change intentions. Existing Envoy sidecars keep running on cached config; new sidecars block on cert issuance. | bring at least one server back. |
| Worker's Consul agent dies       | That worker drops out of the catalog. Existing sidecar keeps running on cached config but new connections to it fail. | container `restart: unless-stopped` brings it back; rejoins automatically. |
| Envoy sidecar dies               | All in-flight mTLS connections through it drop. App's calls to `127.0.0.1:19000` get connection refused. | container restart. ~5 s downtime per peer. |
| Connect CA root expiry           | All sidecar leaf certs go invalid; whole mesh stops. | `consul connect ca set-config` to rotate root, or default 5-year root won't bite us in this experiment. |
| Connect intention misconfigured (e.g. accidental deny) | Some traffic blocked silently. Sidecar denies are reported as `RBAC: access denied` in Envoy logs. | rotate intention; xDS picks it up in seconds (already demoed). |
| **RPC TLS not set** | RPC is plaintext on the overlay. Threat is bounded by the QUIC overlay below it (peer ⇄ peer end-to-end encrypted), so on-the-wire taps don't see it; in-CVM containers that bind `127.0.0.1` to the agent's RPC port would. | Stage-2 work: derive a small CA from attestation-rooted material and configure Consul TLS using it. |
| ttl.sh image expiry | After 24h, a CVM restart can't pull our images. New deploys silently fail to pull. | move to a real registry (GHCR, Phala internal, local registry on the public box). |

### Risk shape

The Consul server tier is now redundant (3 servers, Raft, single-CVM
loss survivable). The remaining structural risk is **all three
coordinator CVMs failing simultaneously** — same dstack edge, same
provider — which is rare but not impossible.

The crypto omissions (gossip key, RPC TLS) are **technically wrong
posture** but practically masked because Layer 3 mTLS already
protects everything that matters. Still want to fix for defence in
depth.

### Recommended fixes (still open)

1. **Cluster health endpoint** outside Consul — a separate tiny
   service that polls `/v1/status/leader` and `/v1/health/state/any`
   on each peer and emits red/green. Avoids "we don't know what's
   wrong with the cluster" mode.

### Already shipped

- **Three Consul servers** — landed in commit `17f4642`. The
  coordinator app deploys with `replicas = 3` and Consul agents on
  those CVMs run as servers with `bootstrap_expect = 3`. Workers
  retry-join through every coordinator's serf port via mesh-conn,
  so the single-coordinator-failure scenario stays operational.
- **Real registry** — Sigstore-attested GHCR images via
  `.github/workflows/consul-postgres-ha-publish.yml`. See
  `PUBLISHING.md`.
- **Gossip key wired in (Stage-1 workaround)** — `cluster.tf`
  generates a `random_bytes` and broadcasts it to every CVM via
  env; `mesh-sidecar/entrypoint.sh` passes it as
  `consul agent -encrypt=…`. Same shape used for the Patroni
  superuser + replication passwords. The keys live in
  `terraform.tfstate`; eliminating that exposure is part of the
  Stage-2 attestation-admission work
  (`design/attestation-admission.md`).

## Cross-layer concerns

### Boot ordering

Compose's `depends_on` is start-order only, not health-order.
Currently:

- mesh-conn must reach link-up before Consul tries to gossip with
  peers (otherwise gossip targets won't be reachable, and Consul
  will spam `No known Consul servers` for a few seconds).
- Consul must be ready to register services before webdemo tries.
- Sidecar must wait for Consul to have its sidecar definition
  registered (already handled — sidecar's entrypoint loops
  `consul connect envoy -bootstrap` until it succeeds).

The transient errors clear up on retry. Adding `healthcheck:` blocks
to each service + `depends_on: { service: { condition:
service_healthy } }` would silence them entirely.

### Time drift

TURN credentials are time-bound (1-hour TTL in our derivation). If a
CVM clock drifts more than ~minutes from the coordinator's, TURN auth
fails. dstack CVMs run NTP so this isn't a real concern, but worth
noting for the runbook.

### Configuration drift / inconsistency

PEERS_JSON is duplicated across every CVM's deploy env. Keeping them
in sync is a deploy-script discipline today (`deploy_one()` builds it
once, passes the same string to every `phala deploy`). A single
broken character on one CVM and that peer's port plan disagrees with
the others — silently, until something tries to talk to that port.

Mitigation: keep the deploy logic in a single shell script (already
the pattern), and have mesh-conn validate the JSON at startup —
include a hash in the log so you can `grep` across all peers and
confirm they agree.

### Restart cascades

If mesh-conn restarts mid-flight, every peer-pair tears down + re-
handshakes. Consul's RPC + gossip go quiet for ~5–15 s. Envoy
sidecars' upstream watch fires, in-flight RPCs error out, app code
needs to retry. **Most apps retry, so this is mostly fine, but
intermittent restarts can amplify into "everything is flapping".**
Mitigation: Consul + Envoy already have built-in retry / connection
pooling, so the blast radius is bounded. Keep mesh-conn's reconnect
backoff aggressive enough that flapping doesn't compound (5 s is
fine).

## Prioritised punch list

In order of worst-impact-per-fix-cost:

1. **Two coordinators** + signed signalling messages (Layer 0).
   Removes the new-join SPOF and closes the metadata-spoof gap.
2. **Local loopback integration test for mesh-conn** (Layer 2).
   Unit tests cover the config layer; the wire protocol still has
   no regression net.
3. **Periodic metrics on mesh-conn** (Layer 2). Cheap, dramatic
   improvement in operability.

Item 1 is what stands between "fun experiment that demos
correctly" and "leave it running and forget about it"; items 2–3
are the next plateau.

The deeper open question — **anyone with `terraform.tfstate` can
read the cluster's gossip key and Patroni passwords** — is
deliberately deferred to Stage 2 (attestation admission), where
peers prove TEE residency and shared cluster material is rooted
in attestation rather than handed in by the deployer.

### Closed since the previous revision

- **Auth-channel reconnect deadlock** — fixed via fresh
  `peerSession{}` per `dialICE` + drain-then-push on `authCh`.
- **Three-server Consul** — coordinator deploys with
  `replicas = 3`; Consul agents run as servers with
  `bootstrap_expect = 3`.
- **PEERS_JSON validation** — `validatePeers()` runs at startup
  with nine-case unit-test coverage.
- **Real registry** — Sigstore-attested GHCR images via
  `.github/workflows/consul-postgres-ha-publish.yml`.
- **Gossip key + Patroni passwords are now cluster-wide identical
  (Stage-1 workaround)** — generated in Terraform and broadcast
  to every phala_app via env. Stage-2 attestation will replace
  this with TEE-rooted material.

## "Are we playing too many tricks?"

Honest answer: not really. Each layer earns its place.

- The **CVM constraint** (no L3 between peers) forces an overlay.
- The **NAT constraint** forces ICE / hole-punching.
- **Consul's UDP-and-TCP-on-the-same-port** forces a multiplexer
  over the punched path.
- Yamux is the obvious multiplexer (HashiCorp uses it inside Consul,
  Nomad, and Vault — it's not exotic).
- **Identity-port preservation** is the *one* clever-and-ours
  technique, and it's there because Consul's own protocol assumes
  every peer can be addressed at the same well-known port set.

The risk concentration isn't in the count of layers; it's in the
**single piece of code we wrote ourselves** (mesh-conn). That's
exactly the file that needs the attention from the punch list above.

The other risk concentration is **operational**: SPOFs at the
coordinator and the Consul server. Those are easy fixes and just
need to be done before treating any of this as production.
