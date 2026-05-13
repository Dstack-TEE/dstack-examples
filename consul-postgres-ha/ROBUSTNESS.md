# Robustness review

We've assembled a tower of clever-ish components: CVMs behind a NAT,
ICE hole-punch, QUIC stream multiplexer, peer-VIP forwarding, Consul +
Envoy mTLS on top. Each layer earns its keep — but that's exactly
when it's worth being honest about how the whole thing fails.

This doc walks each of the four layers, asks "what breaks, and what
do we do about it?", and lands on a prioritised punch list.

## Mental model

```
  Layer 3   apps         Consul + Envoy + webdemo + Patroni
                         (HashiCorp / Lyft / Zalando code, well-trodden)
  Layer 2   forwarder    mesh-conn ~600 LoC: peer VIPs (127.50.0.0/24),
                         static infra-port allowlist {21000, 21001,
                         8300, 8301}, 3-byte stream header
  Layer 1   transport    pion/ice + QUIC: punched UDP path,
                         stream multiplex, flow control, keepalive
  Layer 0   rendezvous   coturn + signalling broker on a public box;
                         dstack CVMs behind a provider NAT
```

The risks fall into three buckets:

- **operational**: things that fail in normal life and want
  watchdogs, retries, healthchecks, runbooks.
- **structural**: SPOFs, capacity ceilings, missing redundancy.
- **boutique-protocol**: bugs we could write into the small shim
  that would manifest as hard-to-debug stalls.

The "are we playing too many tricks?" question really resolves to
the third bucket. Most of the stack uses well-trodden libraries; the
clever-and-ours bits are the peer-VIP plane and the 3-byte stream
header. Both are simple enough to audit, but exactly because they're
ours, they're the parts that *must* be made robust by hand.

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
| Signalling broker is unauthenticated | Any external actor can publish/poll messages, spoof candidates, intercept ICE handshakes. Currently low-impact only because we're solo. | gate `/publish` + `/poll` on attestation-derived identity. |
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

- **ICE auth-race convergence.** When two peers handshake in near-
  simultaneous restart (the normal startup case on a fresh cluster
  or after a redeploy), the supersession check in `pollLoop` —
  "fresh peer auth aborts the in-flight dial against a now-stale
  consumed value" — used to fire symmetrically on both sides, and
  every aborted attempt's retry rebuilt the `ice.Agent` (mandatory
  because pion's `Restart()` doesn't support re-`Dial`; see
  `peerSession` docstring), which republished a fresh auth, which
  re-superseded the peer's next attempt, ad infinitum. Observed on
  2026-05-13 as worker↔coordinator and worker↔worker pairs flapping
  for 7+ minutes per pair, blocking Patroni replica `pg_basebackup`
  (replicas' local Envoys had no endpoint for `postgres-master`).

  Fixed with two coupled changes in `runPeerLink` and `pollLoop`:
  asymmetric retry back-off (lex-smaller peer waits 2 s, larger
  waits 5 s — see `retryBackoff` in `mesh-conn/main.go`) and a
  3-second grace window on the supersession check (`supersedeGrace`)
  so an in-flight handshake gets a fair chance to converge before a
  peer-side credential roll can abort it. The pair composes: the
  back-off asymmetry guarantees one side's retry is the
  authoritative auth publisher per cycle; the grace window absorbs
  early-race noise that otherwise re-enters the supersede loop
  before either retry can settle.

  Regression net: `mesh-conn/main_test.go::TestAuthRaceConvergence`
  is a deterministic in-process loopback harness that forges a
  fresh-auth from the peer while a real handshake is in flight.
  Before the fix, the test fails 32/33 of 33 trials (the survivor
  was a "link came up before forge arrived" race in the original
  single-shot variant). After the fix it passes 50/50 with the
  sustained-forge variant gated on the `onAttemptStarted` hook,
  which guarantees the forge lands inside the in-flight window.

## Layer 2 — mesh-conn forwarder

### What's there

- peer VIPs `127.50.0.<vip>` (one per peer, in PEERS_JSON)
- the static infra-port allowlist `{21000, 21001, 8300, 8301}`
  (in `mesh-conn/main.go`, deliberately small — see ARCHITECTURE.md)
- the 3-byte stream header (tag, port-uint16-BE)
- the per-stream pumps (UDP length-prefix, TCP raw splice)
- one accept-loop per peer pair to demux incoming streams

### What can break

| failure                          | impact                                                              | recovery |
| ---                              | ---                                                                 | ---      |
| Two peers configured with the same VIP | mesh-conn refuses to start with an explicit `vip N claimed by both A and B` error before any goroutine starts. | already handled — `validatePeers()` runs at startup, see "Already shipped" below. |
| VIP out of range (0 or > 254) | `validatePeers()` rejects with `vip out of range`. | already handled. |
| Loopback alias for a peer's VIP not provisioned | mesh-conn fails at `net.ListenTCP/UDP` on the missing address; container crashes; compose restart re-runs entrypoint which re-provisions aliases. | automatic via `restart: on-failure`. |
| **mesh-conn dies** | All peer-pair links from this CVM drop. QUIC + ICE on every other peer notice via keep-alive within ~30 s and tear down. Consul agent gossip-timeouts (~10 s default) drop this CVM from the catalog. Sidecars on other peers stop sending here. | container `restart: on-failure` brings it back; everyone re-handshakes. |
| Receiver gets a stream tagged for a port outside the allowlist | mesh-conn logs and closes the stream defensively (no dial). | already handled. |
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

1. **Periodic metrics** — counters for streams open/closed, bytes
   in/out per port. A `/metrics` endpoint or even just stderr every
   30 s.

### Already shipped

- **Loopback integration test for mesh-conn** — `mesh-conn/main_test.go`
  boots two `Mesh` instances against an inlined `/publish` + `/poll`
  broker on `httptest.NewServer`, drives a real pion/ice handshake on
  host loopback candidates, and asserts `link up` within a 30 s
  deadline. Three cases: green-path single handshake, the auth-race
  regression test (forges fresh peer auth mid-handshake), and a real
  Mesh-restart convergence test. Catches both the auth-race
  convergence regression and any future protocol-level break in the
  3-byte stream header or per-port plumbing.
- **PEERS_JSON validation at startup** — `validatePeers()` in
  `mesh-conn/main.go` runs before any goroutine starts and fails
  fast on duplicate IDs, missing self, VIP collisions, or
  out-of-range VIPs. A canonicalised `peersDigest()` is logged at
  startup so `grep` across all peers' logs immediately surfaces
  config drift. Unit tests in `validate_test.go` cover the cases
  plus an `allowedPort` check pinning the static allowlist.

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
| **RPC TLS not set** | RPC is plaintext on the overlay. Threat is bounded by the QUIC overlay below it (peer ⇄ peer end-to-end encrypted), so on-the-wire taps don't see it; in-CVM containers that bind `127.0.0.1` to the agent's RPC port would. | Derive a small CA from attestation-rooted material and configure Consul TLS using it — design lives in `design/attestation-admission.md`. |
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
- **Gossip key wired in (workaround)** — `cluster.tf`
  generates a `random_bytes` and broadcasts it to every CVM via
  env; `mesh-sidecar/entrypoint.sh` passes it as
  `consul agent -encrypt=…`. Same shape used for the Patroni
  superuser + replication passwords. The keys live in
  `terraform.tfstate`; eliminating that exposure is part of the
  attestation-admission work
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

PEERS_JSON is duplicated across every CVM's deploy env. Today
Terraform builds it once from `local.peers` and passes the same
string to every `phala_app`, so within a single `terraform apply`
they agree. A divergence (e.g. a partial apply that updates some
CVMs but not others) would mean two peers disagree on which VIP
identifies which peer — silently, until something tries to dial that
peer.

Mitigation: mesh-conn logs a `peersDigest` at startup; `grep` across
all peers' logs and confirm they agree. The digest is stable under
peer-list reorder so different orderings of the same set hash to the
same thing.

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
2. **Periodic metrics on mesh-conn** (Layer 2). Cheap, dramatic
   improvement in operability.

Item 1 is what stands between "fun experiment that demos
correctly" and "leave it running and forget about it"; item 2 is
the next plateau.

The deeper open question — **anyone with `terraform.tfstate` can
read the cluster's gossip key and Patroni passwords** — is
deliberately deferred to the attestation-admission work, where
peers prove TEE residency and shared cluster material is rooted
in attestation rather than handed in by the deployer.

### Closed since the previous revision

- **ICE auth-race convergence flap** — fixed via asymmetric retry
  back-off + 3 s grace window on the supersession check. See Layer 1
  "Already shipped" for the failure analysis and the regression test.
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
  (workaround)** — generated in Terraform and broadcast to every
  phala_app via env. Attestation-rooted admission will replace
  this with TEE-derived material.

## "Are we playing too many tricks?"

Honest answer: not really. Each layer earns its place.

- The **CVM constraint** (no L3 between peers) forces an overlay.
- The **NAT constraint** forces ICE / hole-punching.
- **Consul's UDP-and-TCP-on-the-same-port** forces a multiplexer
  over the punched path.
- QUIC is the obvious multiplexer over a lossy UDP underlay (yamux
  was tried and discarded — see ARCHITECTURE.md).
- **Per-peer loopback VIPs** are the *one* clever-and-ours
  technique, and they exist because Consul's own protocol assumes
  every peer can be reached at a stable address. The peer-VIP plane
  gives us that stable address without modifying Consul; the static
  infra-port allowlist on top keeps mesh-conn workload-agnostic.

The risk concentration isn't in the count of layers; it's in the
**single piece of code we wrote ourselves** (mesh-conn). That's
exactly the file that needs the attention from the punch list above.

The other risk concentration is **operational**: SPOFs at the
coordinator. Easy fix (run two coordinators) and just needs to be
done before treating any of this as production.
