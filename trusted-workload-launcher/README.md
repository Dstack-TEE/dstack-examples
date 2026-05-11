# trusted-workload-launcher

A minimal, auditable launcher image for dstack. Given a config file that
names an upstream Git repo and a full commit SHA, the launcher fetches that
exact commit, verifies `HEAD` after checkout, and runs the workload's own
entry point script — with no fallback to branches, tags, or short SHAs.

"Trusted" in the name refers to what a dstack deployment using this image
can produce — a *trusted workload deployment* — not to any intrinsic
property of the workload code. The launcher's job is to make the identity
of what runs in the TEE checkable: it combines TEE attestation with an
auditable image digest and an attested config that names the workload
commit. Whether the workload at that commit is itself trustworthy is up to
the auditor.

By convention, **the workload repo provides its own bash entry point at the
fixed path `tee-launch.sh`** (default mode). This keeps install/build/run
logic inside the workload repo, where it is covered by source provenance of
the pinned `COMMIT_SHA` and is **not** a trust-bearing field in the
launcher config. A verifier therefore only audits two things: the launcher
image's identity, and the `REPO_URL` + `COMMIT_SHA` pair in the attested
config.

The launcher image is **generic**: its digest attests the launcher's
implementation, not the workload. The workload identity comes from the
config file, which must be attested separately (see [Trust model](#trust-model)).

This is a separate example from [`launcher/`](../launcher), which is a
Docker Compose auto-update pattern. This launcher does the opposite — it
*prevents* auto-update by pinning to one full commit SHA per deploy.

## What this is — and what it is not

The launcher is **not** the workload. It is intentionally tiny so the contents
of this directory at a given commit can be read end-to-end before trusting it
to bootstrap anything else.

| Layer | Lives in | Job |
| --- | --- | --- |
| Launcher | this directory | Fetch and run *one* program from *one* pinned upstream commit. |
| Workload | a separate upstream Git repo | The actual application — business logic, secrets handling, network surface. |

The launcher's only job is to make sure that, given a config, the bytes that
end up running inside the dstack VM are exactly the bytes at a specific commit
in a specific upstream Git repo. Everything else lives in that upstream repo.

## Trust model

The launcher image and the config file are two separate trust inputs, and a
verifier must attest both. The launcher image alone does **not** determine
which workload commit runs.

For a step-by-step verifier checklist that chains dstack attestation to the
pinned workload commit, see [`VERIFY.md`](./VERIFY.md).

```
launcher image digest ──►  launcher implementation identity
                           (this directory at commit L; the release
                            workflow publishes a Sigstore build-provenance
                            attestation that binds the image digest to a
                            specific GitHub workflow run / repo / ref /
                            SHA. This is a signed chain of custody, not a
                            claim of bit-for-bit reproducibility.)

launcher config file  ──►  workload pin
                           (REPO_URL + full COMMIT_SHA U; selects which
                            upstream commit gets fetched and run)

                       ──►  workload running inside the TEE
                           = workload repo at commit U,
                             starting from its tee-launch.sh
```

The published launcher image is a **generic** runner: the same image digest
can drive any pinned workload, depending on which config it is started with.
The config is therefore part of the deployment's trust surface and must be
attested separately. dstack provides a few standard ways to do that — pick
the one that matches how strictly you want to bind the workload pin to the
attestation:

| Binding | What attests the config | When to use |
| --- | --- | --- |
| **dstack app config / `compose_hash` / `config_id`** | dstack measures the compose file (and any files it references that participate in compose-hash) into the TEE's attested config; a verifier compares against an expected hash | Default for production. The config travels with the deployment and is covered by the existing dstack attestation chain. |
| **Baked into a derived image** | Build a small downstream image `FROM <launcher>@sha256:…` that `COPY`s the config in; deploy that derived image. The derived image digest then implies both the launcher and the pin | When you want image-digest-only binding (one digest fully determines the workload). |
| **Runtime bind-mount from the host** | Nothing — the host can swap the file | Local development only. Do not use for production trust. |

Once the config is attested by one of the first two options, a relying party
verifies in four steps:

1. The launcher image digest in the dstack attestation matches the digest
   published by the release workflow for this directory at commit `L`
   (verified via the Sigstore build-provenance attestation, which binds
   the digest to a specific GitHub Actions workflow run / repo / ref /
   SHA — see [`VERIFY.md`](./VERIFY.md) for the exact check).
2. The launcher script at commit `L` is the audited script — small, parses
   (does not source) its config, refuses anything but a full commit SHA, and
   verifies `HEAD` after checkout.
3. The launcher config the runtime actually loaded is the attested config
   (via `compose_hash` / `config_id`, or by deriving it from the derived
   image's digest).
4. The `COMMIT_SHA` in that config is the workload commit the relying party
   expected.

Because the launcher does no fallback — missing or invalid commit is a hard
failure — there is exactly one workload commit that can ever boot from a
given (launcher image digest, attested config) pair.

## CLI

```
trusted-workload-launcher <config-file>
```

The launcher is a single bash script (`bin/trusted-workload-launcher`). It
depends only on `bash`, `git`, and POSIX coreutils. It is **not** sourced
and **does not source** the config. In default mode, the only bytes it
executes are those of the workload repo's `tee-launch.sh` at the pinned
`COMMIT_SHA`. In advanced mode (see below), it additionally executes the
configured `INSTALL_CMD` / `RUN_CMD` via `bash -c`.

## Config contract

An env-file with `KEY=VALUE` lines. Comments start with `#`. Surrounding
matching single or double quotes are stripped (one layer). Unknown keys are
rejected. The config is parsed, not sourced — no command substitution and
no shell expansion in the parse step.

### Required

| Key | Meaning |
| --- | --- |
| `REPO_URL` | Git URL of the upstream workload repo (`https://…` or `git@…`). |
| `COMMIT_SHA` | **Full** 40-hex SHA-1 or 64-hex SHA-256. Branches, tags, and short SHAs are rejected. |
| `WORK_DIR` | Local directory used as the checkout. Created if missing. Reused on subsequent runs as long as the existing clone's `origin` URL matches `REPO_URL`. |

### Optional

| Key | Meaning |
| --- | --- |
| `REPO_SUBDIR` | Relative directory inside the repo to `cd` into before running the entry point or `RUN_CMD`. Must not be absolute and must not contain `..`. |
| `CHILD_ENV_FILE` | Path to a separate env file. Each `KEY=VALUE` line is `export`ed into the environment seen by `tee-launch.sh` / `INSTALL_CMD` / `RUN_CMD`. The file is parsed line-by-line just like the main config (not sourced). |
| `RUN_CMD` | **Advanced.** Shell command to exec instead of the default `tee-launch.sh`. Use only when the workload repo cannot host its own entry script. |
| `INSTALL_CMD` | **Advanced.** Shell command to run before `RUN_CMD`. Only valid alongside `RUN_CMD`. |

### Default mode: `tee-launch.sh` in the workload repo

Recommended for every workload you control. The workload repo provides a
bash script at the fixed path `tee-launch.sh` (at the repo root, or at
`REPO_SUBDIR/tee-launch.sh` if `REPO_SUBDIR` is set). The launcher runs it
with `bash tee-launch.sh` after checkout — **no executable bit is
required**. All install/build/run logic lives in that script; the launcher
config carries only `REPO_URL` + `COMMIT_SHA` (+ local `WORK_DIR`).

Because the script's bytes are pinned by `COMMIT_SHA` and stored in the
workload repo, they are covered by source provenance of the pinned commit.
The verifier does not need to extract or audit any command string out of
the launcher config.

### Advanced mode: explicit `RUN_CMD` / `INSTALL_CMD`

Use this when the workload repo cannot be modified to add a
`tee-launch.sh` (e.g. you are pinning a third-party repo unchanged).
Setting `RUN_CMD` switches the launcher into advanced mode; if you need
more than one command, set `INSTALL_CMD` to run before `RUN_CMD`. Each is
a single-line shell string and the launcher does not implement multi-line
parsing. In this mode both values are trust-bearing config and must be
audited alongside `COMMIT_SHA`.

### What the launcher will and will not do

* Will: clone fresh if `WORK_DIR` is empty; reuse the existing clone otherwise
  (after asserting that its `origin` URL matches `REPO_URL`).
* Will: `git fetch --tags --prune origin`, then `git checkout --detach $SHA`,
  then `git rev-parse HEAD` and assert it equals `COMMIT_SHA`.
* Will not: fall back to a branch, tag, or `HEAD` if the commit is missing.
  A missing commit is a hard failure.
* Will not: accept short SHAs. A truncated SHA could resolve ambiguously if
  the upstream history changes.
* Will not: source the config or `eval` config values. In default mode the
  launcher executes `bash tee-launch.sh` from the pinned commit; in advanced
  mode it executes `INSTALL_CMD` / `RUN_CMD` via `bash -c`. Nothing else
  from the config reaches a shell.

## Example

See [`examples/web-app.conf`](./examples/web-app.conf). Adapt `REPO_URL`,
`COMMIT_SHA`, and (if you need it) `REPO_SUBDIR` for your workload, and
make sure the workload repo has a `tee-launch.sh` at the pinned commit.

```sh
./bin/trusted-workload-launcher ./examples/web-app.conf
```

The launcher logs the resolved repo, commit, workdir, and selected mode at
startup, then logs the verified `HEAD` after checkout, before handing
control to `tee-launch.sh` (or `INSTALL_CMD` / `RUN_CMD` in advanced mode).

## Deploying with dstack

Always pin the launcher image by its OCI digest (`@sha256:…`) — not by tag —
so the dstack attestation binds to the exact launcher bytes you audited.
How the config gets in front of the launcher depends on which binding from
the trust model above you chose.

### Local development (host bind-mount)

Convenient for iterating on the config. **Not for production**: the host can
swap the mounted file at any time and nothing about that swap is reflected
in the dstack attestation.

```yaml
services:
  workload:
    image: docker.io/<org>/trusted-workload-launcher@sha256:<launcher-digest>
    command: ["/etc/trusted-workload-launcher/config.conf"]
    volumes:
      - ./web-app.conf:/etc/trusted-workload-launcher/config.conf:ro
      - workload-checkout:/var/lib/trusted-workload-launcher
    restart: unless-stopped

volumes:
  workload-checkout:
```

### Production option A: attest the config via dstack compose

Inline the config inside the compose file (or reference a sibling file that
participates in the compose hash). dstack measures the compose into the
attested app config, so a verifier can compare the deployed compose against
the one they audited:

```yaml
services:
  workload:
    image: docker.io/<org>/trusted-workload-launcher@sha256:<launcher-digest>
    command: ["/etc/trusted-workload-launcher/config.conf"]
    configs:
      - source: pin
        target: /etc/trusted-workload-launcher/config.conf
    volumes:
      - workload-checkout:/var/lib/trusted-workload-launcher
    restart: unless-stopped

configs:
  pin:
    content: |
      REPO_URL=https://github.com/example-org/example-web-app.git
      COMMIT_SHA=<full-40-or-64-hex-sha>
      WORK_DIR=/var/lib/trusted-workload-launcher/example-web-app

volumes:
  workload-checkout:
```

A verifier compares the deployed `compose_hash` / `config_id` against the
one they audited; that binds the launcher image **and** the pinned
`COMMIT_SHA` to the attestation.

### Production option B: bake the config into a derived image

If you want a single digest to fully determine the workload, build a small
downstream image that copies the config in:

```dockerfile
FROM docker.io/<org>/trusted-workload-launcher@sha256:<launcher-digest>
COPY web-app.conf /etc/trusted-workload-launcher/config.conf
CMD ["/etc/trusted-workload-launcher/config.conf"]
```

Deploy that derived image (pinned by its own `@sha256:…`). The derived
image digest now implies both the launcher and the workload pin, and the
dstack attestation over the image digest is sufficient.

## Tests

`tests/run-tests.sh` builds a throwaway local git repo, points the launcher
at specific commits, and asserts:

* Happy path: launcher checks out the pinned commit and `exec`s the run
  command from inside the requested subdirectory.
* Re-running with a different `COMMIT_SHA` advances the pin in-place.
* Bogus commit SHA aborts before running anything.
* Branch names and short SHAs are rejected during validation.
* Missing required keys are rejected.
* Unknown keys are rejected.
* `REPO_SUBDIR` containing `..` is rejected.
* Pre-existing `WORK_DIR` whose `origin` differs from `REPO_URL` is rejected.
* `CHILD_ENV_FILE` values reach the child process.
* `INSTALL_CMD` runs before `RUN_CMD`.
* `--help` exits zero.
* The release workflow runs launcher tests before building the image and
  generates a GitHub artifact attestation bound to the pushed image digest.
* The Dockerfile uses a small runtime base and exposes the launcher as
  the entrypoint.

Run with:

```sh
./tests/run-tests.sh
```

The tests only require `bash`, `git`, and standard coreutils, so they run
unprivileged in CI or on a developer laptop.

## Release image provenance

The release workflow (`.github/workflows/trusted-workload-launcher-release.yml`
in this repository's root `.github/`) follows the dstack-examples pattern:

1. run `./tests/run-tests.sh`;
2. build and push `docker.io/${DOCKERHUB_ORG}/trusted-workload-launcher:<tag>`;
3. call `actions/attest-build-provenance@v1` with the Docker build digest;
4. write the digest and a Sigstore search link into both the GitHub Actions
   step summary and the GitHub release body.

The attestation subject is the immutable OCI digest emitted by
`docker/build-push-action`, not the mutable tag. A verifier should pin and
compare that digest before trusting the launcher image.

## Audit checklist

If you are reviewing this directory at commit `L` before signing off on a
launcher image, the relevant audit surface is:

1. `bin/trusted-workload-launcher` — every line. Confirm:
   * No `eval`, no `source`/`.`, no command substitution applied to config
     values during parsing.
   * `git checkout` always uses the verbatim `COMMIT_SHA` and the result is
     reverified with `git rev-parse`.
   * `INSTALL_CMD` / `RUN_CMD` are executed exactly once each, via a fresh
     `bash -c`, with no implicit fallbacks.
2. The config the launcher will load at deploy time (`REPO_URL`,
   `COMMIT_SHA`, etc.). This pins which workload code runs, and is **not**
   covered by the launcher image digest — verify it via the dstack attested
   `compose_hash` / `config_id`, or via the digest of a derived image that
   bakes the config in. See [Trust model](#trust-model).
3. The contents of the upstream workload repo at the pinned `COMMIT_SHA` —
   that is the surface that actually serves traffic.
