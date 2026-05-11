# Verifying a trusted-workload-launcher deployment

How a relying party verifies that a dstack CVM is running the
`trusted-workload-launcher` and that the workload commit executed inside the
TEE is the one they audited.

This is a verification guide for the launcher example. It is not a TIP
receipt service. See [Limitations](#limitations) for what the launcher
deliberately does **not** provide.

## Goal (in TIP terms)

A verifier wants to:

1. **Establish workload identity.** Bind a hardware-attested dstack TEE to a
   specific image identity (launcher image digest) and a specific config
   identity (the `REPO_URL` + `COMMIT_SHA` + commands the launcher will
   execute).
2. **Verify evidence of execution.** Confirm the running CVM is a genuine
   dstack TEE (TDX quote, dstack measurements) and that its measured image
   and attested config match the expected identity from step 1.
3. **Link derived work to that identity.** The "derived work" produced by
   this deployment is the workload code at the pinned upstream commit —
   bind that commit to the identity so a reviewer can audit exactly what
   ran.

The launcher does the third step *deterministically*: given the same image
identity and config identity, the same `COMMIT_SHA` always ends up on
`HEAD`, or the launcher refuses to start. Steps 1 and 2 are dstack
attestation; this document explains how to chain them together.

## What is being verified

| Object | Identity is | Attested by |
| --- | --- | --- |
| Launcher implementation | `trusted-workload-launcher` OCI image digest | dstack TEE measurement of the running image |
| Launcher config — `REPO_URL`, `COMMIT_SHA`, `INSTALL_CMD`, `RUN_CMD`, optional `REPO_SUBDIR` / `CHILD_ENV_FILE` / `WORK_DIR` | bytes of the config file the launcher loads at startup | dstack `compose_hash` / `config_id`, **or** the digest of a derived image that bakes the config in |
| Workload code | upstream Git repo at the full SHA `COMMIT_SHA` | the launcher's `git checkout --detach $SHA` + `git rev-parse HEAD` reverification, plus the upstream Git host serving that commit |

Runtime evidence — `HEAD verified: <SHA>` in container logs, workload
self-checks, etc. — is **corroborating only**. The trust anchor is the
launcher image digest + attested config; logs are not signed receipts.

## Two verification paths

The verifier picks the path that matches how the deployment was packaged.

### Path A — generic launcher image + dstack-attested compose

The deployed CVM runs the generic launcher image, with the config carried
in a compose file (e.g. via compose `configs:` content). dstack measures
the compose into the attested app config.

```
dstack attestation ──pins──►  launcher image digest (= trusted-workload-launcher@sha256:...)
                              compose_hash / config_id (= a specific compose, including the config bytes)
                                                                         │
                                                                         └─► REPO_URL, COMMIT_SHA, ...
```

A verifier checks both: the image digest *and* the compose hash. Either
mismatch invalidates the deployment.

### Path B — derived image with config baked in

A small downstream image is built `FROM trusted-workload-launcher@sha256:...`
that `COPY`s the config in. Its image digest covers both the launcher and
the config bytes.

```
dstack attestation ──pins──►  derived image digest
                                ├── FROM trusted-workload-launcher@sha256:... (launcher identity)
                                └── COPY config.conf                           (config identity)
                                                                         │
                                                                         └─► REPO_URL, COMMIT_SHA, ...
```

A verifier needs only the derived image digest; the launcher digest and
the pin both follow from it. (This is the path used in the production
smoke test below.)

## Verifier checklist

The following commands assume the Phala CLI (`phala`) authenticated against
the workspace that owns the deployment. The CVM identifier can be a UUID,
`app_id`, instance ID, or name.

### 1. Get the attestation

```sh
phala cvms attestation --cvm-id <id> --json > attestation.json
```

The JSON contains the dstack/TDX quote and platform evidence the CVM is
willing to expose. A verifier feeds it into a dstack/TDX quote verifier to
confirm the platform identity, signing certs, and TCB.

`phala cvms attestation` (no `--json`) prints a human summary. The exact
raw-quote extraction shape depends on dstack version; use the JSON output
as the authoritative source.

### 2. Verify hardware/platform evidence

Run the dstack-side verifier (or the Phala Cloud trusted endpoint, as the
lite path) against `attestation.json` to confirm:

* The TDX quote signs over dstack's measurement of the running image.
* dstack's measurements (`MRTD`, RTMR0–3, `compose_hash`, `instance_id`,
  app contract) are consistent with the platform identity certificates.

Phala Cloud's dashboard for the app (e.g.
`https://cloud.phala.com/dashboard/cvms/<app_id>`) renders the parsed
attestation for cross-checking.

### 3. Compare the deployed image digest to what you expect

```sh
phala ps --cvm-id <id> --json | jq -r '.containers[] | .image'
```

* **Path A**: the container image should be the generic launcher pinned by
  digest, e.g. `docker.io/<org>/trusted-workload-launcher@sha256:<L>`. Then
  also check the compose hash:
  ```sh
  phala runtime-config <id> --json | jq -r '.compose_hash // .data.compose_hash'
  ```
  and compare it against the hash of the compose file you audited.
* **Path B**: the container image should be the derived image, pinned by
  digest. Single comparison; no separate compose hash needed.

If the running image digest doesn't match, stop — the deployment is not
what you audited.

### 4. Verify launcher source provenance

```sh
git -C <local-dstack-examples> log -1 --format=%H -- trusted-workload-launcher
```

Check out `dstack-examples` at the commit you audited and inspect:

* `trusted-workload-launcher/bin/trusted-workload-launcher` — the audited
  script (no `eval` / `source`, full-SHA only, `git rev-parse` reverify).
* `trusted-workload-launcher/docker/Dockerfile` — base pinned by manifest
  digest.

If the release process is reproducible (e.g. via the
`trusted-workload-launcher-release.yml` workflow that publishes a Sigstore
attestation), rebuild and confirm the resulting digest matches the one
from step 3. Otherwise, treat the published image digest + Sigstore
attestation as the chain of custody from this directory at `L` to the
deployed bytes.

### 5. Verify config provenance and extract `COMMIT_SHA`

* **Path A**: extract the config bytes from the compose file you audited
  (the same one whose hash you checked in step 3). The relevant fields are
  `REPO_URL`, `COMMIT_SHA`, optional `REPO_SUBDIR`, `INSTALL_CMD`,
  `RUN_CMD`. Confirm the compose hash you compared earlier was over
  exactly these bytes.
* **Path B**: re-build the derived image locally from the same
  `Dockerfile`, base launcher digest, and config file you audited, and
  confirm the resulting digest matches the one from step 3. The config
  file in your audit is the same one inside the deployed image.

Either way, you now have the authoritative `COMMIT_SHA`.

### 6. Audit the workload commit

```sh
git -C <workload-checkout> rev-parse --verify <COMMIT_SHA>
```

Confirm the upstream repo at `REPO_URL` contains `COMMIT_SHA`, then review
the workload at that commit. This is the code that actually serves
traffic.

### 7. Use runtime logs as corroboration only

```sh
phala logs --cvm-id <id> -n 200
```

Expected lines:

```
[trusted-workload-launcher] checking out <COMMIT_SHA>
[trusted-workload-launcher] HEAD verified: <COMMIT_SHA>
[trusted-workload-launcher] exec in <WORK_DIR>[/<REPO_SUBDIR>]: <RUN_CMD>
```

These confirm the launcher reached the post-checkout state. They are
**not signed**, so they don't replace steps 1–6 — they corroborate them.
A workload that needs signed runtime evidence should produce its own
attested output (see [Limitations](#limitations)).

## Reference: production smoke transcript

A real verification of this example was exercised against production
Phala on 2026-05-11. Summary:

| Field | Value |
| --- | --- |
| Path | B (derived image with config baked in) |
| Launcher base | `docker.io/h4x3rotab/trusted-workload-launcher-smoke@sha256:a88a1052279f028cc0de7414ddb3ab439df0cad622abf36fed1195cf4fd3c5ad` |
| Derived image | `docker.io/h4x3rotab/trusted-workload-launcher-smoke@sha256:6c508c15c45c8aacbbbfab3754724ef9ef104a67e1c53a9c35b50be47e86433e` |
| Workload repo | `https://github.com/octocat/Hello-World.git` |
| Pinned commit | `7fd1a60b01f91b314f59955a4e4d4e80d8edf11d` (master) |
| CVM name | `twl-smoke-20260511-091916` (deleted post-verification) |
| App ID | `app_2a242c979a76009770a88908df0dc6907aea37b8` |

`phala ps --cvm-id <id>` showed the running container's image was exactly
the expected derived image digest. `phala logs --cvm-id <id>` showed:

```
[trusted-workload-launcher] checking out 7fd1a60b01f91b314f59955a4e4d4e80d8edf11d
[trusted-workload-launcher] HEAD verified: 7fd1a60b01f91b314f59955a4e4d4e80d8edf11d
[trusted-workload-launcher] exec in /var/lib/trusted-workload-launcher/hello: ...
TWL_PINNED_HEAD=7fd1a60b01f91b314f59955a4e4d4e80d8edf11d
TWL_README_BYTES=13
TWL_READY
```

The post-`exec` `TWL_PINNED_HEAD` line is from `git rev-parse HEAD`
evaluated *inside the TEE container* by the workload's `RUN_CMD`, so it
is independent corroboration that the bytes running are the pinned
commit. `TWL_README_BYTES=13` matches Hello-World's README byte count.

(Step 1 — TDX quote verification — was not part of this smoke run; the
CVM was deleted before a full quote was extracted. The shape of step 1 is
documented in the dstack verifier docs; the CLI command in this guide is
the authoritative entry point.)

## Limitations

* **No TIP receipt signing in the launcher.** The launcher fetches and
  execs code; it does not produce signed receipts over its own outputs.
  Workload identity for *individual responses* must be implemented by the
  workload itself (e.g. an in-TEE signing key released by dstack KMS).
* **No workload identity key.** A relying party cannot ask "is this
  response from the workload at `COMMIT_SHA`?" by checking a signature
  the launcher produced. Identity here means "is the CVM measured as
  running this image+config?" — a deployment-level identity, not a
  per-response identity.
* **Runtime logs are not signed.** Logs are useful for forensics and
  smoke testing but cannot be the trust root for a remote verifier.
* **Generic image digest alone does not bind config.** Path A requires a
  separate compose-hash check; Path B folds the config into a single
  image digest. Do not assume a generic launcher image digest implies a
  workload pin.
* **Trust in the upstream Git host.** The launcher verifies the
  `COMMIT_SHA` it actually checked out, but it does not enforce *which*
  Git host serves it. `REPO_URL` is part of the attested config; the
  verifier reviews and trusts that URL together with the rest of the
  config.

For workloads that need TIP receipt signing or a per-response workload
identity, build that on top of this launcher (or alongside it) — the
launcher's job stops at "the bytes running here are the bytes at
`COMMIT_SHA`."
