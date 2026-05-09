# Design: TEE attestation as the mesh admission credential

**Status**: not started. Largest of the three open architectural
gaps. Worth starting with a design discussion (verify dstack SDK API
shape, confirm policy choice) before writing code. Branch off
`dstack-consul-ha-db`, PR back into it.

## Why

The whole point of running on dstack is that each CVM can produce a
hardware-attested measurement of what's executing inside it. Right
now mesh-conn doesn't *use* that — peer admission is gated by:

- Holding the TURN HMAC secret (same on every peer in the cluster,
  derived from dstack KMS by `bootstrap-secrets`).
- Completing pion/ICE handshake.
- Completing QUIC TLS handshake (self-signed cert, no peer-cert
  verification — `InsecureSkipVerify: true`).

A peer that **exfiltrates the TURN HMAC** can rejoin the mesh from
anywhere. A peer running a **rolled-back or compromised image** can
rejoin too — nobody asks "what are you running?" before admitting
the connection. That's a meaningful gap for a TEE-rooted system.

### Stage-1 workaround that this work replaces

Because each `phala_app` resource has its own `app_id` and dstack
`GetKey` is rooted at `app_id`, per-CVM derivation produces
*different* bytes on each peer for any path. Cluster-wide identical
secrets — gossip key, Patroni superuser/replication passwords —
therefore can't come from `GetKey` in this topology. They are
instead generated in Terraform (`random_bytes` in
`cluster-example/cluster.tf`) and broadcast to every CVM via env.

That sacrifices the "key never leaves the TEE" property: the keys
sit in `terraform.tfstate` and pass through whoever runs `apply`.
Anyone with that file's bytes has the same authority as a cluster
member. This admission redesign is the principled fix —
attestation-rooted material derived inside the TEE, no human in the
trust path.

## Goal

Each peer's mesh-conn admission decision is gated on a fresh dstack
attestation that:

1. **Signs a binding** between the peer's identity (peer-id, ICE
   credentials, QUIC cert public key, …) and the TEE measurement.
2. **Chains to dstack's KMS root**, so we can verify off-chain that
   it really came from a dstack CVM.
3. **Matches a policy** the cluster has agreed on (more on policy
   below).

A peer that can't produce such an attestation is rejected at the
QUIC handshake or first-stream layer, with a clear error.

## Non-goals (for the first pass)

- Replacing Consul Connect's mTLS at Layer 3. Consul intentions
  govern *service-to-service* auth and stay as-is. This work governs
  *peer-to-peer mesh admission* — a layer below. The two are
  orthogonal.
- Replacing the TURN HMAC for *coturn auth*. Coturn still wants its
  shared-secret. We're adding a **second** check at mesh-conn admit
  time, not replacing the first.
- Periodic re-attestation. Phase 1 is "fresh attestation at each new
  link establishment". A peer that rotates mid-session is out of
  scope until phase 2.

## Where attestation flows in the protocol

Two natural insertion points:

| Where | Pros | Cons |
|---|---|---|
| **(a) During ICE auth exchange via signaling broker** | Earliest possible reject. No ICE NAT-mapping wasted on rejected peers. | Signaling broker is *public* — attestation is exposed to anyone polling the broker. May be acceptable if attestations don't reveal sensitive state. |
| **(b) After QUIC handshake, as a "hello" message before the first user stream** | Private (encrypted under QUIC's TLS). Cleaner separation: ICE/QUIC stays oblivious, attestation is an application-layer concern. | A rejected peer wastes one ICE handshake + QUIC handshake. Fine in practice. |

**Recommendation: (b).** The privacy benefit outweighs the
extra-handshake cost. Concrete shape:

1. Both sides establish QUIC (existing flow).
2. Each side immediately opens a dedicated stream tagged
   `streamAttest = 0xAA` (next free tag after `streamUDP=0x55`,
   `streamTCP=0x33`).
3. Each side writes its attestation (a length-prefixed blob) to that
   stream and closes its write half.
4. Each side reads the peer's attestation, verifies it against the
   policy, and either:
   - On accept: starts the existing `runAcceptLoop` /
     `OpenStreamSync` flow.
   - On reject: closes the QUIC connection with a documented error
     code, and `runPeerLink` retries after backoff (no different
     from any other failed handshake).

The 3-byte stream header + tagging convention extends naturally;
nothing else in the wire format changes.

## Policy choice — three candidates

### (1) Per-image-digest allowlist

The cluster admits peers running images whose digests match an
allowlist hardcoded into `bootstrap-secrets` or pulled from Consul KV.

Pro: tightest. A leaked TURN HMAC alone can't get you in.

Con: rolling upgrades require careful sequencing. While CVM-A is on
digest `D1` and CVM-B is on digest `D2`, they need to admit each
other. Either the allowlist always carries N+M digests during the
upgrade window, or the upgrade procedure pauses traffic between
not-yet-upgraded peers — both annoying.

### (2) Per-app-id signature

The cluster admits any peer whose attestation binds to the **same
dstack app-id** as our own. Identity = app-id; image-digest is not
checked.

Pro: rolling upgrades trivial — N+1 image is still under the same
app-id, so peers admit each other unchanged. Simple to implement
(app-id is already in `/run/instance/info.json`).

Con: a malicious image deployed under the same app-id (by whoever
controls the dstack-app deploy keys) can join. The TEE proves
"running in this app" but not "running this *binary*".

### (3) Consul-KV-rooted policy

The admission policy is a signed document stored in Consul KV under
e.g. `cluster/<name>/admission-policy`, signed by a key derived from
dstack KMS at cluster bootstrap. The document lists allowed
image-digests + a signature scheme for rotation.

Pro: most expressive. Supports rolling upgrades (write a new policy
listing both digests, peers re-evaluate, after upgrade the old digest
is removed). Supports revocation (write a deny-list).

Con: most complex. Bootstrapping the signing key safely is tricky
(if an attacker reaches Consul KV they can rewrite the policy).

### Recommendation

**Phase 1: per-app-id (option 2).** It's the smallest delta from
where we are, gives a meaningful security improvement (compromise of
TURN HMAC alone no longer admits arbitrary outsiders — they'd have
to also be inside *this* dstack-app), and doesn't fight rolling
upgrades. Document explicitly that this is "trust the deploy key,
not the image".

**Phase 2: layer in image-digest verification with a policy doc in
Consul KV** (option 3) once we have someone driving the
deploy-time-signing story.

Do **not** start with per-image-digest hardcoding (option 1) — the
upgrade pain bites immediately and there's no path forward.

## Implementation phases

### Phase 0 — plumbing (no enforcement)

- Each peer fetches its attestation at startup via the dstack SDK.
- Add the attest-stream exchange (`streamAttest=0xAA` + length-prefix).
- Both sides log "got peer attestation, would accept" but admit
  unconditionally.
- Adds an observability foothold without breaking anything.

### Phase 1 — per-app-id enforcement

- Each peer's attestation includes its app-id.
- Verify: signature chains to dstack KMS root, app-id matches our
  own.
- Reject + log on mismatch. Add a regression test that constructs a
  fake attestation with a wrong app-id and asserts rejection.

### Phase 2 — Consul-KV admission policy

- Coordinator-side: a small tool that signs a policy doc and writes
  it to Consul KV.
- Peer-side: pull the policy doc on link admission, verify
  signature, check peer's image-digest against the allowed list.
- Rolling-upgrade story: operator writes a new policy listing both
  digests, applies cluster-wide image bump, then writes a policy
  removing the old digest.

### Phase 3 — re-attestation on link redial

- The stream-of-attestation exchange runs every time `dialAndPump`
  re-establishes a link, not just once at peer-id discovery.
- Already implicit in phase 1 (the exchange is per-handshake), but
  worth listing because it means revocation propagates within
  ~minute timescales, not "until this connection drops naturally".

## Open questions for the design discussion

1. **What's the actual dstack SDK API for fetching an attestation /
   quote?** The user has worked with `dstack.NewDstackClient().Info()`
   and `client.GetKey()` — assume there's an analogous
   `client.GetQuote()` or `client.Attest()` but verify against the
   SDK source. Determines the binding shape (what the attestation
   commits to: nonce, peer-id, public key, …).

2. **Attestation size + verification cost.** Dstack quotes are
   typically a few KB and Verify is a few ms. If both are larger than
   that, the attest exchange becomes a noticeable handshake-latency
   tax. Worth measuring early.

3. **What does the attestation actually bind to?** Possible
   bindings:
   - peer-id (our string, e.g. `worker-3`) — easy to spoof on its own
   - QUIC cert public key — ties the attestation to *this* TLS
     handshake. Best.
   - Nonce from the peer — prevents replay across handshakes. Add to
     the dialer's auth blob and have the dialee bind to it.
   The right answer is probably "QUIC cert pubkey + a per-handshake
   nonce", binding both the identity and the freshness.

4. **Bootstrap chicken-and-egg.** First peer to come up has nobody
   to attest to. How does the cluster bootstrap when *every* peer
   needs every other peer's attestation? Two answers:
   - Coordinators come up first; admit only if peer's
     attestation is valid; coordinators admit each other via a
     genesis attestation whose policy is "any peer in our app-id".
   - Or: same code, no special-case — just per-app-id from the
     start.

5. **Failure observability.** What's the log shape when admission
   fails? Operators need to see "rejected peer X because
   app_id=Y didn't match expected=Z" — not just "link failed".
   New error type + structured log line.

6. **Interaction with the planned single-sidecar consolidation
   (Gap 2).** Attestation lookup happens inside mesh-conn, so it
   stays with mesh-conn whether mesh-conn is a separate container or
   one process inside the consolidated sidecar. Gap 2 should land
   first; Gap 3 is easier when the platform plumbing lives in one
   place.

## Success criteria

- [ ] Each peer fetches a valid dstack attestation at startup.
- [ ] Peer-pair handshake includes attest-stream exchange.
- [ ] Verify signature chains to dstack KMS root.
- [ ] Reject peer with mismatched app-id; admit peer with matching
      app-id.
- [ ] Log shape clearly distinguishes admission-reject from other
      handshake errors.
- [ ] Failover demos (FAILOVER.md) still pass — RTO unchanged within
      noise.
- [ ] A new doc, `consul-postgres-ha/ATTESTATION.md`, explains the
      threat model + policy + how to inspect attestations on a
      running cluster.

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| Attestation API not available on the dstack SDK we're using | Verify in the design-discussion phase before writing code. If missing, the right path is "land Gap 2 first, then file an SDK feature request, then revisit". |
| Verification is slow enough to become a handshake bottleneck | Cache valid peer-attestations for the lifetime of the QUIC connection (don't re-verify on each stream). Measure once before deciding mitigation is needed. |
| Per-app-id is too loose for the user's threat model | Document the limitation in `ATTESTATION.md` and ship Phase 2 (Consul-KV policy) as the next iteration. Don't perfect-is-the-enemy-of-good Phase 1. |
| Bootstrap deadlock — every peer waits for every other | Per-app-id avoids this entirely (no shared trust root needed beyond dstack KMS, which every CVM has). Phase 2 needs explicit thought; not a Phase 1 concern. |

## Hand-off

Worth at least a design discussion before writing code (the user
flagged this as "a large topic, breakout session"). Specifically:
verify dstack SDK API, confirm per-app-id is the right Phase 1
policy, decide on (a) ICE-auth vs (b) post-QUIC stream as the
exchange point. Then implementation is a focused ~300-LoC change in
mesh-conn plus a new doc.
