# Attestation Admission

This example can gate Consul client-agent join and Consul Connect
service registration on dstack TEE attestation.

Enable it in `cluster-example/terraform.tfvars`:

```hcl
enable_attestation_admission = true
consul_management_token      = "<consul-acl-management-token>"
dstack_verifier_image        = "dstacktee/dstack-verifier:0.5.9"
```

Use a versioned verifier tag and pin it by digest for production.
Do not rely on `dstacktee/dstack-verifier:latest`; the current
release workflow publishes version tags and does not move `latest`.
The verifier must support the `GetQuote` evidence shape used by
current dstack guest agents: `quote`, `event_log`, and `vm_config`.

## Trust Flow

1. Terraform calls Phala preflight for the same app definitions it
   deploys and reads each expected `compose_hash`.
2. Terraform renders `ADMISSION_POLICY_JSON` for coordinators. Policy
   rows are keyed by workload identity and optional `peer_id`;
   `compose_hash` is revision evidence, not the workload key.
3. A worker starts `mesh-conn`, then requests a nonce from a
   coordinator admission broker.
4. The worker builds a binding statement containing the claimed
   identity, peer id, dstack app id, instance id, and compose hash.
5. The worker calls dstack `GetQuote(SHA-512(binding || nonce))` and
   sends `{identity, binding, nonce, quote, event_log, vm_config}` to
   the broker.
6. The broker verifies the quote through `dstack-verifier`, checks
   report-data binding and nonce freshness, then matches identity,
   peer id, and compose hash against the Terraform policy.
7. On success the broker mints a scoped Consul ACL token. Worker
   agents receive a node-identity token; service workloads receive
   service-identity tokens plus any declared Consul permissions.

## Runtime Checks

From a coordinator CVM, inspect Consul membership:

```sh
docker exec dstack-sidecar-1 sh -lc \
  'CONSUL_HTTP_ADDR=http://127.0.0.1:8500 consul members -token "$CONSUL_MANAGEMENT_TOKEN"'
```

Check Raft health:

```sh
docker exec dstack-sidecar-1 sh -lc \
  'CONSUL_HTTP_ADDR=http://127.0.0.1:8500 consul operator raft list-peers -token "$CONSUL_MANAGEMENT_TOKEN"'
```

Look for successful node and service admission in worker sidecar logs:

```sh
phala logs --cvm-id <worker-app-id> dstack-sidecar-1 -n 700 |
  rg 'admission-client-(node|demo|webdemo).*admission accepted'
```

Look for hard attestation failures:

```sh
phala logs --cvm-id <worker-app-id> dstack-sidecar-1 -n 700 |
  rg 'QUOTE_INVALID|VERIFIER_FAILED|REPORT_DATA_MISMATCH|ADMISSION_REJECTED'
```

No output from the failure grep is expected.

## Current Limits

- The low-level mesh rendezvous path still uses TURN HMAC admission.
  Attestation admission gates Consul/Connect identity, not rendezvous.
- Broker-issued Consul tokens do not expire by default. Setting
  `ADMISSION_TOKEN_TTL` requires a renewal path for the Consul agent,
  Patroni DCS token, and Envoy xDS token.
- The verifier downloads OS-image inputs and computes reference
  measurements on cache miss. Coordinators mount
  `/tmp/dstack-runtime/verifier-cache` into the verifier so image and
  measurement caches survive verifier container restarts on the same
  CVM.
- The measured `compose_hash` comes from Phala's `app-compose.json`.
  Image binding should use digest-pinned image references in the
  Compose source. Environment variable values are not a sufficient
  image-binding policy.
- Dynamic upgrade policy is future work. Phase 1 uses the static
  Terraform-generated allowlist; a future policy server can admit new
  compose hashes under a signed policy epoch.

## Verification Cost

Measured on 2026-05-18 with a live `tdx.small` worker quote and
`dstacktee/dstack-verifier:0.5.9`:

| Mode | Time |
|---|---:|
| Oneshot, empty verifier cache | 2.1s |
| Oneshot, image and measurement cache already populated | 1.5s |
| Long-running HTTP server, warm cache | 1.1-1.2s |

The cold run downloaded a 20 MB OS-image bundle and computed the
reference measurements. Larger OS images or slow network paths will
increase the first request cost; the verifier download timeout is
300s by default. After that, the verifier reuses the cached image and
cached measurements for the same VM config. Quote verification still
costs about one second, so the broker should treat verification as a
startup/admission cost, not something to repeat for every leaf-cert
rotation.
