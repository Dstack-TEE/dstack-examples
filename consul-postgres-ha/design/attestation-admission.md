# Design: TEE attestation as the service-mesh identity root

**Status**: exploration brief, not accepted. The verifier path is
resolved, but the admission policy mechanism is still open. Do not
start Phase 1 implementation from this document without first
settling the circularity around app-id based policy.

## Why this is the load-bearing piece

Today the cluster has two layers of authentication:

1. **mesh-conn admission** uses a `TURN_SHARED_SECRET` env passed to
   every CVM via `cluster.tf`. This is acceptable for the current
   "NAT traversal as a VPC" model: the secret gates who can plumb
   packets into the private overlay. It is not intended to be the
   workload identity root.
2. **Consul Connect mTLS** uses Consul's built-in Connect CA to mint
   leaf certs for each sidecar. The CA signs anything that registers
   with a valid Consul ACL token. Today there are no ACL tokens —
   any sidecar can request a cert and get one.

Layered above this, our cluster-wide shared secrets (gossip key,
Patroni superuser + replication passwords) are currently generated
by Terraform and broadcast to CVMs via env. Moving those out of
Terraform remains a separate hardening arc; it should not be mixed
up with the NAT PSK. Passing the NAT PSK through env is fine for
the current VPC-like overlay model.

The remaining question is narrower: **what should authorize a CVM
to obtain a Consul Connect identity?** TEE attestation is the right
primitive, but app-id allowlisting has a deployment-order problem
that this brief now treats as unresolved.

## What changes for end users

If the admission-broker approach survives the policy-design
discussion, an operator who runs `terraform apply`:

- Still sets `TURN_SHARED_SECRET` for NAT traversal. That remains
  the overlay admission key.
- May see a new runtime admission policy source, but it cannot be
  baked into the broker image if it depends on dstack app-ids: the
  app-ids are not known until after Phala has deployed the apps.
- May later stop setting `GOSSIP_KEY`, `PATRONI_SUPERUSER_PW`, and
  `PATRONI_REPLICATION_PW` in `cluster.tf`, but that is a separate
  phase. It is not required to answer the identity-policy question.

A workload's developer experience is unchanged — they bind
`127.0.0.1:5432`, declare the service in `local.services`, get a
sidecar with a Connect cert. The new machinery is invisible.

## Architecture in one paragraph

Candidate shape: each workload's sidecar, at startup, fetches a TDX
quote from its local dstack guest-agent. The quote's `report_data`
binds the sidecar's about-to-be-issued Connect leaf cert pubkey + a
fresh nonce from the cluster's **admission broker**. The sidecar
posts the quote + claimed identity + cert pubkey to the broker. The
broker verifies the quote through `dstack-verifier`, evaluates a
cluster policy predicate, and on success issues a Consul ACL token
bound to a SPIFFE-style identity (e.g., `spiffe://demo/postgres`).
The sidecar uses that token to request a Connect cert from Consul's
stock CA. From that point on, **the cert chain is the workload's
identity** — intentions, mTLS verification, EDS endpoint trust all
flow through the standard Consul Connect machinery.

```
  dstack TEE   ┌──── attestation ──── TDX quote + event log
  per CVM      │                       binding: H(cert pubkey || nonce)
               ▼
  admission-broker (on coordinators)
       │ verifies quote chain
       │ reads verifier fields: app_id, compose_hash, mrtd, ...
       │ checks a policy predicate that is still under design
       │ ✓ → mints Consul ACL token bound to a SPIFFE identity
       │ ✗ → rejects with documented error code
       ▼
  Consul ACL token presented to local Consul agent
       │
       ▼
  Consul Connect CA signs leaf cert → sidecar uses it for mTLS
```

## What we deliberately are *not* doing

- **No SPIRE/SPIFFE control-plane software.** SPIFFE *URIs* in the
  cert SAN field are stock Consul Connect; we're not adding SPIRE
  as a runtime dependency. The user explicitly rejected this as
  over-engineering for the example.
- **No Vault.** Same reasoning — another moving part.
- **No custom Consul Connect CA provider plugin.** Token-gated cert
  issuance (option δ from the design discussion) is the chosen
  shape; the leaf-cert-chain-as-attestation-proof variant (option
  α) is a follow-up if anyone needs deeper integration.
- **No re-attestation on every leaf-cert rotation in Phase 1.** The
  broker-issued ACL token has a TTL; the sidecar re-attests when
  the token approaches expiry. Cert rotation within a single token
  lifetime doesn't require a fresh quote.
- **No baked app-id policy.** App-ids are assigned after deployment,
  while the broker image must already exist before deployment. Any
  app-id based policy must be delivered at runtime or avoided.
- **No signed signaling layer as part of this arc.** For the
  VPC-like NAT traversal model, the shared PSK is the intended
  overlay admission mechanism. Signing signaling messages can be a
  separate hardening item if the threat model changes.

## The admission broker

A small Go service. Runs as one more supervised process inside
`mesh-sidecar` on coordinator CVMs (alongside the Consul server
agent). One broker instance per coordinator; clients try each in
turn — same shape as the existing `COORDINATOR_VIPS` retry pattern
for Consul itself.

### HTTP API

```
POST /v1/admission/challenge
  → { "nonce": "<32 random bytes, hex>" }
    Short-lived (60 s); broker remembers issued nonces to prevent
    reuse.

POST /v1/admission/attest
Body: {
  "identity":    "spiffe://demo/postgres",  # claimed identity
  "cert_pubkey": "<X.509 SPKI DER, hex>",   # the Connect cert to be issued
  "nonce":       "<echoed from challenge>", # for replay protection
  "quote":       "<TDX quote, hex>",         # from dstack GetQuote()
  "event_log":   "<RTMR event log, JSON>"   # from dstack GetQuote()
}
  → 200 { "consul_acl_token": "<UUID>", "expires_at": "<RFC3339>" }
  | 403 { "code": "ADMISSION_REJECTED", "reason": "<policy failure>" }
  | 400 { "code": "QUOTE_INVALID",     "reason": "<verifier error string>" }
```

The broker validates:

1. **Quote chain**: TDX → Intel PCS root, via a sibling
   `dstack-verifier` HTTP service.
2. **`report_data` binding**: must equal
   `SHA-512(cert_pubkey || nonce)`. Anything else means the quote
   was generated for a different handshake; reject.
3. **Nonce freshness**: must be a nonce the broker issued
   recently and hasn't been consumed.
4. **RTMR replay**: use the Go SDK's `ReplayRTMRs()` helper to
   confirm the event log matches the quote's RTMRs. Otherwise the
   event log could be forged.
5. **Policy check**: evaluate the claimed `identity` against the
   chosen policy predicate. `app_id ∈ allowed_app_ids` is one
   candidate, but not yet accepted because of the Terraform
   deployment-order problem.

On success: mint a Consul ACL token via the local Consul agent's
HTTP API, with a policy that grants the right service-identity
binding (e.g., `service "postgres" { policy = "write" }`). Return
the token + expiry.

### Genesis & state

The broker is **stateless** for admission decisions — every check
is against the chosen policy source + the quote. The only state is the
issued-nonce set (memory, 60 s TTL).

Secret genesis is intentionally out of the immediate identity
policy decision:

- The NAT traversal PSK (`TURN_SHARED_SECRET`) stays an env var in
  Terraform. No CAS is needed for it because Terraform already
  distributes the same value to every CVM.
- If a later phase moves gossip key / Patroni passwords from
  Terraform env into Consul KV, then that phase needs Consul KV CAS
  on `cluster/<name>/secrets/initialized` so exactly one coordinator
  generates the values and losers re-read what the winner wrote.
  That is a separate secret-distribution design, not a reason to
  block or complicate NAT traversal.

## Policy source and circularity problem

The original candidate was a small HCL document in
`cluster-example/admission-policy.hcl`:

```hcl
# Each identity is granted only to workloads whose dstack app_id
# is in the listed set. App-ids come from cluster.tf's
# `phala_app.{coordinator,worker}` outputs, populated at
# `terraform apply` time.

identity "spiffe://demo/coordinator" {
  allowed_app_ids = var.coordinator_app_ids   # set of 3
}

identity "spiffe://demo/postgres" {
  allowed_app_ids = var.worker_app_ids        # set of 3
}

identity "spiffe://demo/webdemo" {
  allowed_app_ids = var.worker_app_ids
}
```

The original draft treated this as a small rendering detail. It is
not: if the policy depends on app-ids, runtime delivery becomes a
real part of the deployment architecture.

This has a real circularity:

1. Docker images must be built and referenced before `terraform
   apply`.
2. Phala assigns dstack app-ids during deployment.
3. A broker image with app-ids baked in would need app-ids that do
   not exist yet.

Runtime rendering can break the cycle, but it introduces deployment
ordering and longer full applies. Pre-allocating app-ids through a
Phala API might also break the cycle, but relying on preallocation
would be a platform-specific workaround unless it is a first-class
API contract.

Policy candidates to keep exploring:

| Candidate | What it proves | Deployment shape | Concern |
|---|---|---|---|
| Runtime app-id allowlist | Quote belongs to one of the deployed Phala apps | Terraform deploys apps, collects app-ids, writes broker-readable runtime policy | Staged apply / policy update cycle |
| Preallocated app-id allowlist | Same as above | Reserve app-ids before image build / apply | Depends on Phala API semantics; may slow large deploys |
| Compose hash / MRTD predicate | Workload measured content matches a pre-deployable value | Compute or derive expected measurement before apply, then broker checks `compose_hash` / `mrtd` | Need to verify whether values are deterministic and locally computable |
| Terraform-issued node enrollment token + quote binding | Node was provisioned by this Terraform deployment and is running in a verified TDX environment | Terraform passes per-node token via env; quote binds token-derived key in `report_data` | Weaker than content identity unless combined with measurement checks |
| KMS/certificate based identity | Workload identity comes from a Phala/dstack-issued cert chain rather than raw app-id | Broker verifies the cert chain and binds it to the quote | Need to inspect exact KMS cert semantics |

Current direction: do **not** bake policy into the broker image. The
most promising next investigation is whether `compose_hash` or
`mrtd` can be computed before deployment and used as the primary
predicate. That would avoid the app-id circular dependency while
staying faithful to measured workload identity.

## Sidecar flow at startup (worker case)

The sidecar entrypoint already does roughly: register service →
get Connect cert → start Envoy. The new flow inserts attestation
before "get Connect cert":

```
1. Generate an ephemeral keypair for the sidecar's Connect cert.

2. POST /v1/admission/challenge to broker. Receive nonce.

3. report_data = SHA-512(cert_pubkey || nonce)
   Call dstack GetQuote(report_data). Receive quote + event_log.

4. POST /v1/admission/attest to broker with
   { identity, cert_pubkey, nonce, quote, event_log }.

5. On 200: receive Consul ACL token. Use it via
   CONSUL_HTTP_TOKEN for all subsequent Consul API calls.

6. Register the service (existing flow). Now Consul will mint a
   Connect leaf cert with the configured ACL token's identity
   binding — happens automatically inside `consul connect envoy
   -sidecar-for=<service>`.

7. Start Envoy with the bootstrap config + the ACL token. Envoy
   refreshes its leaf via xDS using the same token.

8. Before token expiry (broker default: 1 h, leaf cert TTL 72 h),
   the sidecar restarts the entire flow from step 2. This is the
   re-attestation path — Phase 1 supports it implicitly because
   the broker reissues tokens against fresh quotes.
```

## How this closes ROBUSTNESS gaps

| Current open item in ROBUSTNESS.md | Closed by this work |
|---|---|
| Cluster shared secrets live in `terraform.tfstate` | Separate follow-up: generate non-NAT secrets inside the TEE and store them in attestation-gated Consul KV. Not part of this identity-policy decision. |
| RPC TLS not set on Consul | Broker mints agent-level ACL tokens for Consul itself; can enable `verify_incoming=true` on RPC. |
| Signaling broker is unauthenticated | Out of scope here. The NAT layer follows the VPC-like PSK model; signed signaling is a separate hardening discussion. |

## Non-goals (Phase 1)

- Replacing Consul Connect's CA. Built-in CA still mints leaves;
  the broker just gates the *token* that authorizes cert issuance.
- Committing to app-id-only enforcement before resolving the policy
  circularity.
- Periodic re-attestation independent of token TTL.
- Cross-cluster federation. Single dstack cluster only.

## Phase 0 findings (verified 2026-05-14)

- **Verification path: `dstack-verifier` HTTP sidecar.** Image
  `dstacktee/dstack-verifier@sha256:3f36162ca8dd2d4207601a6302881de6b497e610eb44050bb0874776fc8ded07`
  (digest of `latest` as inspected locally on 2026-05-15; published,
  ~30 MB pulled).
  Single `POST /verify` returns structured `is_valid`,
  `quote_verified`, `event_log_verified`, `os_image_hash_verified`,
  `tcb_status`, and `app_info.{app_id, compose_hash, instance_id,
  mrtd, rtmr0..3, key_provider_info, ...}`. App_id arrives extracted —
  the broker doesn't parse RTMR3 event_log entries itself.
- **No Rust/C dependency in the broker.** We considered `dcap-qvl`
  Go bindings; the sidecar approach is dramatically simpler.
- **Verification cost: ~800 ms – 1 s per call** (5 trials against
  the dstack repo's fixture quote, first run includes one PCCS
  cache miss). Within budget for a sidecar-startup-time cost.
  Cache-worthy for re-attest cycles within token TTL.
- **Payload sizes**: quote 5 KB hex, event_log ~3.4 KB JSON, total
  POST body ~17 KB, response 1.5 KB. All easy HTTP.
- **`GetQuoteResponse` already carries `Quote`, `EventLog`,
  `ReportData`, `VmConfig`** — every field `dstack-verifier`
  wants. The sidecar passes the entire response through to the
  broker, which forwards to dstack-verifier as-is.

The verifier integration shrinks to HTTP-pass-through. The policy
predicate remains open: app-id allowlisting is easy to implement but
has the deployment circularity described above.

## Implementation phases

### Phase 0 — investigation (DONE)

Findings above. The remaining Phase 0 tasks are operational:

- Build a tiny attest-and-dump program; run on one fresh
  `tdx.small` CVM; confirm a live quote with our own
  `app_id` extracts cleanly. ~30 min wall clock.
- Run `dstack-verifier` co-located with `mesh-sidecar` on
  coordinators. Decide: same container (one more supervised
  process in `entrypoint.sh`) or sibling docker-compose service.
  Lean toward sibling — it has its own image and lifecycle.

### Phase 1 — settle policy predicate, then broker enforces

Do not start with implementation. First answer which predicate the
broker should enforce without forcing a slow staged Terraform flow:

- Can `compose_hash` or `mrtd` be computed before deployment from
  the compose/image inputs?
- Does the Phala/dstack KMS expose a certificate or identity claim
  that is more appropriate than raw app-id?
- If app-id remains the best identifier, is runtime policy rendering
  acceptable for this example, and what is the exact Terraform
  sequence?

Only after that:

- Broker implements full quote verification + RTMR3 app_id
  extraction / verifier-field extraction + policy check.
- Sidecar startup flow inserts the challenge → attest → token →
  register sequence.
- Consul ACL `default_policy = "deny"`; tokens carry per-service
  policies.
- The Connect CA stays stock; cert issuance just becomes
  ACL-gated.

### Phase 2 — broker writes & rotates non-NAT cluster secrets (~half week)

- Broker generates gossip key, Patroni superuser, Patroni
  replication on genesis; writes to Consul KV.
- `bootstrap-secrets` container fetches them from Consul KV
  (gated by its own attestation-issued token) instead of reading
  env.
- `cluster.tf`'s `random_bytes` resources for those three are
  removed. README's "Workaround" section gets deleted.
- `TURN_SHARED_SECRET` remains Terraform-distributed unless the
  NAT-layer threat model changes.

### Phase 3 — observability + ops (~half week)

- Structured log line on every accept/reject.
- Rejected quotes dumped to a per-peer file for post-hoc
  inspection.
- Metrics: `attest_total`, `attest_rejected_total` per identity.
- Doc: `consul-postgres-ha/ATTESTATION.md` — threat model, policy
  format, how to inspect attestations on a running cluster.

## Open questions

Phase 0 resolved verifier path + cost. Current state:

1. **Policy predicate unresolved.** Baked app-id policy is rejected:
   app-id is only known after deployment. Explore runtime app-id
   policy, preallocation, compose_hash / MRTD, KMS cert identity, or
   Terraform-issued node enrollment tokens.

2. **Token lifetime settled for now.** Default broker-issued Consul
   ACL token TTL: 1 h.

3. **CAS narrowed.** CAS is not needed for the NAT PSK. It only
   applies if a later phase moves gossip key / Patroni passwords to
   broker-generated Consul KV secrets.

4. **Broker HA accepted.** One broker per coordinator. If a worker
   cannot reach any broker, new attestations fail; existing tokens
   keep working until expiry. This is acceptable for the current
   coordinator failure model.

5. **Signaling auth deferred.** For "NAT traversal as VPC", a PSK is
   good enough. Signed signaling is not part of the current design.

6. **Verifier pinning settled.** Pin
   `dstacktee/dstack-verifier@sha256:3f36162ca8dd2d4207601a6302881de6b497e610eb44050bb0874776fc8ded07`.
   Upstream image provenance / signature verification remains a
   later supply-chain hardening item.

## Success criteria

- [ ] The policy predicate is chosen and documented without an
      unresolved Terraform/app-id circular dependency.
- [ ] Every workload's Consul Connect leaf cert chains back, via
      a Consul ACL token, to a TDX quote from a CVM satisfying that
      predicate.
- [ ] `cluster.tf` no longer declares `random_bytes` for gossip
      key or Patroni passwords. (Separate Phase 2 success; not
      required for the Phase 1 identity predicate.)
- [ ] A workload with a forged quote (e.g., wrong report_data
      binding) is rejected with a structured log line and a
      documented HTTP error code.
- [ ] Failover demo (`FAILOVER.md`) RTO unchanged within noise.
- [ ] A live cluster running for ≥ 1 hour shows zero ACL
      authorization failures and zero attestation rejections.
- [ ] `consul-postgres-ha/ATTESTATION.md` exists and walks through
      the threat model + how to inspect a running cluster's
      attestation state.

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| App-id policy creates a circular deployment dependency | Do not bake app-ids into the broker image. Prefer a pre-deployable measurement predicate if `compose_hash` / `mrtd` can be computed locally; otherwise explicitly model runtime policy rendering in Terraform. |
| `dcap-qvl` Go binding doesn't exist / is unstable | Resolved: use a `dstack-verifier` sidecar over HTTP. The broker speaks JSON to it; isolation makes future swaps trivial. |
| Quote verification cost dominates startup latency | Cache verified attestations in-broker (per-quote-hash) so a sidecar that restarts within the token TTL doesn't re-verify the full chain. |
| Sidecar can't reach any broker on startup | Broker runs on all coordinators; clients try each. Worker failure mode is "Envoy never starts," which is a hard fail at sidecar startup — operator notices immediately. |
| Replay attack across nonces | Nonces are single-use; broker tracks consumed-nonces in memory with 60 s TTL. Cross-broker replay needs a shared nonce store (TBD — Phase 1 may accept the per-broker isolation as good enough). |
| Genesis race produces split non-NAT secrets | Separate Phase 2 only: Consul KV CAS on `initialized`. Losers re-read. Verify the read sees the winner's writes (Consul reads are linearizable on the leader). |
| Policy source out of sync with deployed app-ids | Avoid app-id policy if a pre-deployable measurement predicate works. If app-id policy remains, render policy from Terraform state / outputs and make the staged sequence explicit. |

## Hand-off

Implementing agent should:

1. Read this brief end-to-end.
2. Read `mesh-sidecar/entrypoint.sh` for the existing service-
   registration flow; the attestation step inserts before
   "register service."
3. Read `bootstrap-secrets/main.go` for the existing
   secret-fetching pattern; Phase 2 replaces TF env reads with
   Consul KV reads.
4. Start with policy investigation, not broker implementation:
   determine whether `compose_hash` / `mrtd` can be computed before
   deployment, inspect KMS certificate semantics, and only then pick
   app-id policy if the runtime-rendering cost is acceptable.
5. Phase 1: enforce, end-to-end. Live-verify with the existing
   FAILOVER.md recipes — the whole point of this work is that
   nothing observable changes for normal cluster operation; only
   the trust model underneath is real.
6. Phase 2: non-NAT secret distribution. ROBUSTNESS.md's
   "Workaround"-tagged items get demoted to "Closed."
7. Phase 3: observability + docs.

After this lands, this doc gets deleted. Surviving artifacts: the
broker source, the policy source, the `ATTESTATION.md` doc.
