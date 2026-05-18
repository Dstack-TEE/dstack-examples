# Design: TEE attestation as the service-mesh identity root

**Status**: design direction accepted for Phase 1. The verifier path
is resolved, and the policy root is a Terraform-defined workload
identity whose allowed revisions are attested `compose_hash` values.
Upgrade governance remains future work and is documented below.

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
primitive. The policy root should be the workload identity defined
by Terraform, while the evidence should include the measured
`compose_hash` from dstack.

## What changes for end users

If the admission-broker approach survives the policy-design
discussion, an operator who runs `terraform apply`:

- Still sets `TURN_SHARED_SECRET` for NAT traversal. That remains
  the overlay admission key.
- May see a generated admission policy manifest. The manifest maps
  Terraform-defined workload identities to allowed `compose_hash`
  revisions obtained from Phala Cloud preflight.
- May later stop setting `GOSSIP_KEY`, `PATRONI_SUPERUSER_PW`, and
  `PATRONI_REPLICATION_PW` in `cluster.tf`, but that is a separate
  phase. It is not required to answer the identity-policy question.

A workload's developer experience is unchanged — they bind
`127.0.0.1:5432`, declare the service in `local.services`, get a
sidecar with a Connect cert. The new machinery is invisible.

## Architecture in one paragraph

Candidate shape: each workload's sidecar, at startup, fetches a TDX
quote from its local dstack guest-agent. The quote's `report_data`
binds a canonical admission statement plus a fresh nonce from the
cluster's **admission broker**. The statement names the claimed
identity and local dstack identity fields. The sidecar posts the
quote + claimed identity + statement to the broker. The broker
verifies the quote through `dstack-verifier`, evaluates a cluster
policy predicate, and on success issues a Consul ACL token bound to a
SPIFFE-style identity (e.g., `spiffe://demo/postgres`). The sidecar
uses that token to request a Connect cert from Consul's stock CA.
From that point on, **the cert chain is the workload's identity** —
intentions, mTLS verification, EDS endpoint trust all flow through
the standard Consul Connect machinery.

```
  dstack TEE   ┌──── attestation ──── TDX quote + event log
  per CVM      │                       binding: H(statement || nonce)
               ▼
  admission-broker (on coordinators)
       │ verifies quote chain
       │ reads verifier fields: app_id, compose_hash, mrtd, ...
       │ checks identity → allowed compose_hash policy
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
  "binding":     "<canonical statement bytes, hex>",
  "nonce":       "<echoed from challenge>", # for replay protection
  "quote":       "<TDX quote, hex>",         # from dstack GetQuote()
  "event_log":   "<RTMR event log, JSON>",  # from dstack GetQuote()
  "vm_config":   "<dstack VM config JSON>"  # from dstack GetQuote()
}
  → 200 { "consul_acl_token": "<UUID>", "workload_id": "...", "compose_hash": "..." }
  | 403 { "code": "ADMISSION_REJECTED", "reason": "<policy failure>" }
  | 400 { "code": "QUOTE_INVALID",     "reason": "<verifier error string>" }
```

The broker validates:

1. **Quote chain**: TDX → Intel PCS root, via a sibling
   `dstack-verifier` HTTP service.
2. **`report_data` binding**: must equal
   `SHA-512(binding_statement || nonce)`. Anything else means the
   quote was generated for a different handshake; reject. The broker
   also verifies that the statement identity equals the claimed
   identity.
3. **Nonce freshness**: must be a nonce the broker issued
   recently and hasn't been consumed.
4. **RTMR replay**: use the Go SDK's `ReplayRTMRs()` helper to
   confirm the event log matches the quote's RTMRs. Otherwise the
   event log could be forged.
5. **Policy check**: evaluate the claimed `identity` against the
   generated admission policy. Phase 1 accepts a quote when the
   identity names a known Terraform workload and the quote's
   `compose_hash` is in that workload's allowed revision set.

On success: mint a Consul ACL token via the local Consul agent's
HTTP API. Every issued token carries the workload's service identity;
Consul-native workloads may also attach generated ACL policies for
declared DCS permissions such as `key_prefix "service/<cluster>"`
and `session_prefix ""`. Return the token + expiry.

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

## Policy source

The policy subject is the workload we define in Terraform, not the
`compose_hash` itself. Multiple workloads may share the same measured
compose content while differing in non-measured deployment arguments,
so `compose_hash` is evidence for an approved revision, not the row
key. Rows may also carry the Terraform-declared `peer_id`; when
present, the broker requires the attested binding statement to name
that same peer before issuing node or service tokens.

A generated manifest can be small and explicit:

```json
{
  "cluster": "demo",
  "policy_epoch": 1,
  "workloads": [
    {
      "workload_id": "demo/coordinator/0",
      "identity": "spiffe://demo/coordinator",
      "allowed_compose_hashes": [
        "1434154969cb663afc5a73393b84cc31a1319ab6c65c9766fadd0c86bb59ef37"
      ],
      "evidence": {
        "app_id": "optional runtime evidence",
        "kms": "phala"
      }
    },
    {
      "workload_id": "demo/worker/0/node",
      "identity": "spiffe://demo/node",
      "peer_id": "worker-0",
      "consul_permissions": {
        "node_identity_self": true
      },
      "allowed_compose_hashes": [
        "9157fe4a3b6da46de49f8e2ce0943dbd43cfb6001eefae6b1bcc2c9d0749c5a4"
      ]
    },
    {
      "workload_id": "demo/worker/0/postgres",
      "identity": "spiffe://demo/postgres",
      "peer_id": "worker-0",
      "consul_service": "demo",
      "consul_permissions": {
        "key_prefixes": ["service/demo"],
        "session_write": true,
        "agent_read_self": true
      },
      "allowed_compose_hashes": [
        "9157fe4a3b6da46de49f8e2ce0943dbd43cfb6001eefae6b1bcc2c9d0749c5a4"
      ]
    }
  ]
}
```

`node_identity_self` is the pre-Consul-admission grant. The worker
sidecar attests as `spiffe://<cluster>/node` before starting its
Consul client agent; the broker uses the attested binding
statement's `peer_id` as the Consul `NodeName` in a Consul
`NodeIdentities` token. That matches Consul's recommended agent-token
shape: node write plus service read for that node.

`agent_read_self` is intentionally not a broad Consul `agent_prefix`
grant. For service tokens, the admission broker derives the Consul
node name from the same attested `peer_id` and emits only `agent
"<peer_id>" { policy = "read" }`, so Envoy bootstrap can read its
local agent without gaining visibility into other agents.

The manifest should be generated from the same Terraform graph that
declares the CVMs. The Phala Terraform provider can call the same
preflight path used before deployment and expose the resulting
`compose_hash` without creating a VM. That keeps deployment to a
single ordinary apply: Terraform already knows the workload
definition, preflight yields the measured revision hash, and the
broker receives a policy document derived from those same inputs.

`app_id`, KMS details, TCB fields, and `app-compose.json` remain
valuable evidence and audit material, but they are not the primary
policy key in Phase 1. In particular, `app-compose.json` is useful
for human review and transparency logs because it is the exact byte
payload dstack measures and it embeds the Docker Compose string.

## Upgradeability policy server

Upgradeability is intentionally not implemented in Phase 1. The hard
problem is preventing a developer or operator from silently replacing
part of the mesh with a vulnerable or backdoored revision while
keeping normal rolling upgrades ergonomic.

The future shape is a policy server that answers whether a workload
identity may admit a particular `compose_hash` under a policy epoch.
The coordinator or admission broker verifies the workload quote as
usual, then asks this policy server for the upgradeability decision.

Possible deployments:

| Deployment | Shape | Use case |
|---|---|---|
| Centralized signed policy server | Operator-controlled server returns signed policy roots / allowed revisions | Simple private clusters and fast iteration |
| TEE policy bridge | A TEE service reads blockchain / DAO policy storage and serves coordinator-readable decisions | Decentralized governance without putting chain clients in every coordinator |
| Transparency-log mode | Policy server publishes all admitted revisions and epochs for audit | Human-visible history even when enforcement remains centralized |

Responsibilities for the future server:

- Maintain a stable workload identity namespace independent of
  `compose_hash`.
- Return the allowed revision set for each workload identity and
  policy epoch.
- Support rollout windows where old and new hashes are both valid.
- Publish or sign the current policy root so users can notice
  unexpected upgrade policy changes.
- Keep an audit trail of admitted revisions and retirements.

Phase 1 should leave a clean integration point for this server but
should not depend on it. The generated Terraform manifest is enough
for static revision allowlisting; dynamic upgrade admission is a
future extension.

## Sidecar flow at startup (worker case)

The worker sidecar has two admission points: first for the Consul
client agent itself, then for each declared service identity.

```
1. Start mesh-conn so the worker can reach coordinator brokers at
   127.50.0.<coordinator>:8787.

2. Render a canonical admission statement for
   spiffe://<cluster>/node with local peer identity, dstack app_id,
   instance_id, and compose_hash.

3. POST /v1/admission/challenge to broker. Receive nonce.

4. report_data = SHA-512(binding_statement || nonce)
   Call dstack GetQuote(report_data). Receive quote, event_log,
   vm_config, and report_data.

5. POST /v1/admission/attest to broker with
   { identity, binding_statement, nonce, quote, event_log,
   vm_config }.

6. On 200: receive a Consul ACL token carrying a Consul node identity
   for the attested peer_id. Start the local Consul client agent with
   that token as acl.tokens.agent.

7. For each service backend, render a canonical admission statement
   with claimed service identity,
   local peer identity, dstack app_id, instance_id, and compose_hash.

8. Repeat the challenge/attest exchange for that service identity.

9. On 200: receive Consul ACL token. Use it via
   CONSUL_HTTP_TOKEN for all subsequent Consul API calls.

10. Register the service. Now Consul will mint a
   Connect leaf cert with the configured ACL token's identity
   binding — happens automatically inside `consul connect envoy
   -sidecar-for=<service>`.

11. Start Envoy with the bootstrap config + the ACL token. Envoy
   refreshes its leaf via xDS using the same token.
```

Broker-issued Consul tokens do not expire by default in Phase 1.
`ADMISSION_TOKEN_TTL` can still be set for experiments, but enabling
a TTL in production requires a real renewal path for the Consul
agent token, Patroni's DCS token, and Envoy bootstrap/xDS token.

## How this closes ROBUSTNESS gaps

| Current open item in ROBUSTNESS.md | Closed by this work |
|---|---|
| Cluster shared secrets live in `terraform.tfstate` | Separate follow-up: generate non-NAT secrets inside the TEE and store them in attestation-gated Consul KV. Not part of this identity-policy decision. |
| RPC TLS not set on Consul | Broker mints agent-level ACL tokens for Consul itself; can enable `verify_incoming=true` on RPC. |
| Signaling broker is unauthenticated | Out of scope here. The NAT layer follows the VPC-like PSK model; signed signaling is a separate hardening discussion. |

## Non-goals (Phase 1)

- Replacing Consul Connect's CA. Built-in CA still mints leaves;
  the broker just gates the *token* that authorizes cert issuance.
- App-id-only enforcement. App-id remains optional evidence, not the
  identity root.
- Dynamic upgrade policy. Phase 1 uses static generated revision
  allowlists; a policy server is future work.
- Direct Connect leaf-cert public-key binding. Stock Consul Connect
  does not expose the final leaf key before admission; Phase 1 binds
  the quote to the admission statement and then lets the broker-issued
  ACL token gate stock cert issuance.
- Periodic re-attestation independent of token TTL.
- Cross-cluster federation. Single dstack cluster only.

## Phase 0 findings (verified 2026-05-14, updated 2026-05-18)

- **Verification path: `dstack-verifier` HTTP sidecar.** Terraform
  passes the coordinator verifier image as `dstack_verifier_image`;
  production should pin this by digest. Live validation should use a
  versioned image tag such as `dstacktee/dstack-verifier:0.5.9`.
  The Docker Hub `latest` tag observed on 2026-05-18 was stale and
  rejected the current guest-agent event-log schema; the release
  workflow publishes version tags and does not move `latest`.
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
- **`GetQuote` is the live evidence source.** The sidecar binds
  `report_data` to the admission statement, calls dstack
  `GetQuote(report_data)`, verifies the returned `report_data`
  locally, and sends `{quote, event_log, vm_config}` to the broker.
  The broker forwards those fields to `dstack-verifier` and avoids
  parsing raw quote/event-log internals itself.
- **Image binding depends on the composed source of truth.** The
  measured `compose_hash` is derived from `app-compose.json`, which
  embeds the Docker Compose string. Environment variable values are
  not a reliable image-binding mechanism for this policy; serious
  attestation should hard-code image digests in the Compose source.

The verifier integration shrinks to HTTP-pass-through. The policy
predicate is identity plus allowed `compose_hash`: app-id
allowlisting remains easy to implement, but it is not the Phase 1
root because it introduces deployment circularity.

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

### Phase 1 — generate static revision policy, then broker enforces

The Phase 1 predicate is settled enough to implement:

- Terraform/provider preflight computes the expected `compose_hash`
  from the same app definition used to deploy the CVM.
- Terraform emits an admission policy manifest keyed by workload
  identity, with `allowed_compose_hashes` as revision evidence.
- Broker implements full quote verification + verifier-field
  extraction + identity / compose_hash policy check.
- Sidecar startup flow inserts the challenge → attest → token →
  register sequence.
- Consul ACL `default_policy = "deny"`; tokens carry service
  identities plus explicit structured permissions for workloads that
  also use Consul as DCS.
- Worker Consul client agents no longer receive the Consul management
  token. They attest first and receive a Consul node-identity token
  scoped to their attested peer_id.
- The Connect CA stays stock; cert issuance just becomes
  ACL-gated.
- Upgradeability beyond static allowlists is left for the future
  policy server described above.

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

1. **Phase 1 policy predicate settled.** Use Terraform-defined
   workload identity plus allowed `compose_hash` revisions. Baked
   app-id policy is rejected for Phase 1; app-id remains optional
   evidence.

2. **Upgrade governance deferred.** Static allowlists are enough for
   initial enforcement. Dynamic upgrade admission should be handled
   by a future policy server that exposes policy epochs / roots and
   allowed revision windows.

3. **Token lifetime settled for now.** Broker-issued Consul ACL
   tokens do not expire by default because Phase 1 has no safe reload
   path for Patroni or Envoy tokens. `ADMISSION_TOKEN_TTL` remains
   available for experiments and should only be used with a renewal
   implementation.

4. **CAS narrowed.** CAS is not needed for the NAT PSK. It only
   applies if a later phase moves gossip key / Patroni passwords to
   broker-generated Consul KV secrets.

5. **Broker HA accepted.** One broker per coordinator. If a worker
   cannot reach any broker, new attestations fail; existing tokens
   keep working until expiry. This is acceptable for the current
   coordinator failure model.

6. **Signaling auth deferred.** For "NAT traversal as VPC", a PSK is
   good enough. Signed signaling is not part of the current design.

7. **Verifier image selection settled.** `cluster.tf` exposes
   `dstack_verifier_image`; use a versioned verifier tag, and pin the
   exact digest in production. Upstream image provenance / signature
   verification remains a later supply-chain hardening item.

## Success criteria

- [x] Terraform generates a broker-readable admission policy whose
      rows are keyed by workload identity and whose allowed revisions
      are preflight-derived `compose_hash` values.
- [x] Every workload's Consul Connect leaf cert chains back, via
      a Consul ACL token, to a TDX quote from a CVM satisfying that
      predicate.
- [ ] `cluster.tf` no longer declares `random_bytes` for gossip
      key or Patroni passwords. (Separate Phase 2 success; not
      required for the Phase 1 identity predicate.)
- [ ] A workload with a forged quote (e.g., wrong report_data
      binding) is rejected with a structured log line and a
      documented HTTP error code.
- [ ] Failover demo (`FAILOVER.md`) RTO unchanged within noise.
- [ ] A live cluster running for >= 1 hour shows zero ACL
      authorization failures and zero attestation rejections.
- [ ] `consul-postgres-ha/ATTESTATION.md` exists and walks through
      the threat model + how to inspect a running cluster's
      attestation state.

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| App-id policy creates a circular deployment dependency | Do not use app-id as the Phase 1 identity root. Key policy by Terraform-defined workload identity and verify attested `compose_hash` revisions instead. |
| Silent vulnerable or backdoored upgrade | Phase 1 requires explicit allowed hashes in the generated manifest. Future work adds a policy server with signed policy roots, epochs, rollout windows, and audit history. |
| `dcap-qvl` Go binding doesn't exist / is unstable | Resolved: use a `dstack-verifier` sidecar over HTTP. The broker speaks JSON to it; isolation makes future swaps trivial. |
| Quote verification cost dominates startup latency | Cache verified attestations in-broker (per-quote-hash) so a sidecar that restarts within the token TTL doesn't re-verify the full chain. |
| Sidecar can't reach any broker on startup | Broker runs on all coordinators; clients try each. Worker failure mode is "Envoy never starts," which is a hard fail at sidecar startup — operator notices immediately. |
| Replay attack across nonces | Nonces are single-use; broker tracks consumed-nonces in memory with 60 s TTL. Cross-broker replay needs a shared nonce store (TBD — Phase 1 may accept the per-broker isolation as good enough). |
| Genesis race produces split non-NAT secrets | Separate Phase 2 only: Consul KV CAS on `initialized`. Losers re-read. Verify the read sees the winner's writes (Consul reads are linearizable on the leader). |
| Policy source out of sync with deployed workload | Generate policy from the same Terraform graph and Phala preflight response used for deployment. The broker rejects quotes whose measured `compose_hash` is absent from that manifest. |

## Hand-off

Implementing agent should:

1. Read this brief end-to-end.
2. Read `mesh-sidecar/entrypoint.sh` for the existing service-
   registration flow; the attestation step inserts before
   "register service."
3. Read `bootstrap-secrets/main.go` for the existing
   secret-fetching pattern; Phase 2 replaces TF env reads with
   Consul KV reads.
4. Start with Terraform-generated static policy: use provider
   preflight output for `compose_hash`, key rows by workload
   identity, and treat app-id/KMS/TCB fields as additional evidence.
5. Phase 1: enforce, end-to-end. Live-verify with the existing
   FAILOVER.md recipes — the whole point of this work is that
   nothing observable changes for normal cluster operation; only
   the trust model underneath is real.
6. Phase 2: non-NAT secret distribution. ROBUSTNESS.md's
   "Workaround"-tagged items get demoted to "Closed."
7. Phase 3: observability + docs.

After this lands, this doc gets deleted. Surviving artifacts: the
broker source, the policy source, the `ATTESTATION.md` doc.
