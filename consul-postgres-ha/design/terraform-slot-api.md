# Design: Terraform Slot API Integration

## Status

Handoff in progress.

- Paseo agent: `5219012b-97d5-4d2c-bcbb-a24120e0ac30`
- Agent worktree:
  `/home/h4x/.paseo/worktrees/1izuidyu/brawny-seahorse`
- Target repo for provider work: `Phala-Network/phala-cloud`
- Local consumer repo: `consul-postgres-ha`

This note exists so we can recover the slot-management context even if
the Paseo logs are not immediately available.

## Why This Matters

The service mesh needs stable logical members such as `coordinator-1`
and `worker-4`. Today, a concrete CVM can be replaced during upgrades,
failures, or re-provisioning, and the platform-level VM identifier can
change. The mesh, Consul node namespace, Patroni topology, and
attestation policy need a stable Terraform-declared member identity
that survives that replacement.

The Phala Cloud slot API is the platform primitive for this:

- `app_id` identifies the application or replica set.
- `slot` identifies a stable logical member inside the app.
- `vm_uuid` identifies the current concrete CVM occupying the slot.
- `instance_id` identifies the runtime, network, or workload instance
  where applicable.

For this repo, the slot should become the bridge between Terraform
intent and the runtime member. Compose hash remains revision evidence;
it should not be the workload key.

## Source Context

The original feature request is:

- https://github.com/Phala-Network/phala-cloud/issues/243

The issue describes the desired Terraform direction:

- model `phala_app` as the replica set or application;
- model `phala_app_instance` as a stable logical member;
- let replacement create a new concrete CVM while preserving the slot;
- keep slot names user chosen, immutable after creation, and unique
  under one app.

The issue also sketched these API operations:

- `GET /apps/{app_id}/instances`
- `GET /apps/{app_id}/instances/{slot}`
- `POST /apps/{app_id}/instances`
- `PATCH /apps/{app_id}/instances/{slot}`
- `DELETE /apps/{app_id}/instances/{slot}`
- `POST /apps/{app_id}/instances/{slot}/replace`

The implementing agent must verify the actual just-implemented API in
the current `phala-cloud` tree instead of assuming the issue text is
still exact.

## Desired Provider Behavior

The provider should expose stable slot management in a way Terraform can
reason about directly.

Preferred shape, if it matches the platform API cleanly:

```hcl
resource "phala_app" "mesh" {
  # app-level definition
}

resource "phala_app_instance" "worker_1" {
  app_id = phala_app.mesh.id
  slot   = "worker-1"

  # instance launch/update fields, if these belong at slot scope
}
```

An alternate shape may be acceptable if the platform API strongly
pushes instance management under `phala_app`, but the result must still
let Terraform address one stable logical member without depending on the
current `vm_uuid`.

Provider semantics to preserve:

- `slot` is stable identity and should force replacement if changed.
- Read must distinguish the stable slot from the current concrete CVM.
- Replacement should intentionally move the slot to a new CVM without
  losing the logical member identity.
- Existing public provider behavior must not regress.
- Import should be possible using an address that includes `app_id` and
  `slot`, if the API supports it.

## Service Mesh Integration Plan

Once provider support lands and is released or locally pinned for
testing, update this repo so the real cluster uses slots explicitly.

Expected mapping:

- `coordinator-1`, `coordinator-2`, `coordinator-3` are stable slots.
- `worker-1`, `worker-2`, `worker-3` are stable slots.
- The Consul node name and mesh `peer_id` should be derived from the
  Terraform slot, not from a generated VM identifier.
- Admission policy should continue to verify compose hash as revision
  evidence and should later bind the quoted identity to the
  platform-stable slot or instance evidence exposed by Phala Cloud.

This is a prerequisite for deterministic rolling replacement and for a
cleaner future upgrade policy. It also avoids treating compose hash as a
workload key, since multiple logical workloads may legitimately share
the same compose hash.

## Agent Handoff

The following task was sent to agent
`5219012b-97d5-4d2c-bcbb-a24120e0ac30`:

- discover the current slot API implementation in `phala-cloud`;
- implement Terraform provider support for stable slot management;
- keep the work scoped to slot management, not KMS, OS, or attestation;
- do not revert unrelated changes in its worktree;
- add focused tests for read/create/update/delete/replace/import where
  the API makes those behaviors meaningful;
- report changed files, tests run, and the recommended Terraform shape.

Reason given to the agent: this repo needs stable logical members for
HA mesh operation, deterministic rolling replacement, and future
attestation binding to a Terraform-declared member rather than the
current concrete CVM.

## Success Criteria

- Terraform provider can manage Phala app slots as first-class stable
  logical members or an equivalently addressable structure.
- Provider state exposes both the stable slot and current concrete CVM
  identity when available.
- Existing provider tests still pass.
- New slot tests cover the intended lifecycle.
- `consul-postgres-ha/cluster-example` can be updated without copying
  app or instance configuration between unrelated Terraform resources.
- A real apply/destroy can create the 3-coordinator / 3-worker cluster
  using public or explicitly pinned provider artifacts.

## Open Questions

- Does the released API expose slot replacement as a separate operation
  or as an update/create behavior?
- Which fields belong to `phala_app` versus an instance or slot
  resource?
- Can import be stable on `app_id/slot`, or does the API require an
  internal ID?
- Does the API expose enough stable evidence to bind future attestation
  admission to the slot directly?
- What is the migration path from the current deployment state to
  slot-managed state without destroying healthy clusters unexpectedly?

## Next Local Steps After Agent Callback

- Review the provider patch and Terraform shape.
- Update this repo's provider version or local override for testing.
- Wire `cluster-example` coordinator and worker definitions to slots.
- Run public-provider or pinned-provider real cluster apply/destroy.
- Update `PROGRESS.md` with the tested status and delete this design
  note once the work lands.
