# Phala Terraform provider shakedown — results

**Date:** 2026-05-02
**Provider:** `phala-network/phala 0.2.0-beta.2`
**Terraform:** 1.9.8

## Why we ran this

Stage 4's dev-experience plan is now centred on this provider. Before
locking the design in, we wanted empirical confirmation of:

- basic create / destroy works through the Phala API
- in-place updates preserve `app_id` and the underlying CVM disk
- `replicas` actually scales out under one app_id
- the gotchas worth flagging in the stage-4 docs

## Results

### ✅ Create

```
phala_app.shakedown: Creation complete after 1m57s
  app_id         = "app_778f5393f97ac0e98180b768f1dc3bb63a85c766"
  primary_cvm_id = "05053901-1751-4572-8985-423dcb3b21db"
  endpoint       = "https://778f5393...-8080.dstack-pha-prod5.phala.network"
  status         = "running"
```

`curl https://<app-id>-8080.<gw>` reached the nginx in the CVM
immediately. Plain `phala cvms list` shows the CVM under its app name.

### ✅ In-place compose + env update

Bumped a `compose_version` variable that flips both the
`docker-compose` body and the `EXAMPLE_ENV` value. Plan reported
`0 to add, 1 to change, 0 to destroy` and apply finished in **3m39s**
with the **same `app_id` and `primary_cvm_id`**:

```
phala_app.shakedown: Modifications complete after 3m39s
  [id=app_778f5393...]   <- unchanged
```

So compose / env changes flow through Phala's CVM-update path; disk
volumes survive. This is exactly what stage 4's "in-place updates that
preserve data" requirement needs.

### ✅ Replicas

`replicas: 1 -> 2` planned in-place (`0 to add, 1 to change, 0 to
destroy`), apply took 1m53s, **both CVMs landed under the same
`app_id`**:

```
cvm_ids = [
  "05053901-1751-4572-8985-423dcb3b21db",  # original
  "16d247ca-23f5-4ffa-b590-7f732eddbf51",  # newly added
]
```

(Note: `phala cvms list` only displays one entry per app — the primary.
Use `terraform state show phala_app.<name>` or hit the API directly to
see all replicas.)

This is significant for stage 4: **a single `phala_app` with
`replicas: N` gives us N CVMs sharing the same app_id**, so
`getKey()` returns identical bytes on every replica without any
out-of-band coordination. That makes the TEE-derived gossip/TURN/CA
secret bootstrap clean.

### ✅ Destroy

`terraform destroy` removed the app cleanly (verified by background
task completion). Both CVMs went away.

## Gotchas to bake into stage-4 docs

### `storage_fs` triggers ForceNew if not pinned

Provider reads `storage_fs` back as `"zfs"` post-create, but if the
.tf doesn't declare it, the diff goes `"zfs" -> (known after apply)`,
which Terraform treats as `# forces replacement`. Result: the next
`terraform apply` would **destroy and recreate** the app, losing
disk volumes.

**Fix:** always pin `storage_fs = "zfs"` (or whichever value) in the
resource block. Stage-4 templates must do this.

### Pre-release version pinning

Provider is at `0.2.0-beta.2`. Terraform's `>= 0.2.0-beta.1` excludes
pre-release by default — must pin exactly. Stage-4 templates use
`version = "0.2.0-beta.2"` explicitly.

### Field name shape

The provider uses **positive** booleans (`listed`, `public_logs`,
`public_sysinfo`), unlike the `phala` CLI's `--no-listed` /
`--no-public-logs` / `--no-public-sysinfo` flags. Don't blindly
mirror CLI flag names in HCL.

### `replicas` semantics not surfaced in CLI

`phala cvms list` collapses to one entry per app. Operators looking
for "all CVMs" should use `terraform state show ...` or
`/api/v1/apps/<id>` directly. Not a problem, just worth knowing.

## Verdict

The provider is **good enough** to commit stage 4 to. All four
functional requirements (create, in-place update preserving identity,
in-place update preserving disk, replicas with shared app_id) are
met. The two real gotchas (`storage_fs` ForceNew, pre-release pin)
are easy to bake into the stage-4 templates.

## Open items (still to test before full stage-4 commit)

- **`encrypted_env`** behaviour — does the provider encrypt env values
  before sending them to the Phala API? Important if any non-secret
  config we pass via env is sensitive enough to want at-rest
  encryption (most stage-4 env is plain config, but worth
  confirming).
- **`custom_app_id` + `nonce`** — can we deterministically predict
  app_id BEFORE deploy? Useful for cross-resource references that
  need to be known at plan time (e.g., an external DNS record).
  Today we rely on `phala_app.ctrl.app_id` being available
  post-apply, which is fine for our use case.
- **Failure modes** — what does the provider do when `wait_for_ready`
  times out? When the CVM goes unhealthy mid-apply? Will check during
  stage-4 build.
- **Two `phala_app` resources sharing identity** — for the "AppAuth
  contract pattern" we used in manual deploys. Most likely needs
  `kms = "ethereum"` or `"base"` and on-chain config; out of scope
  for this shakedown.
