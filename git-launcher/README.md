# git-launcher

`git-launcher` runs a workload from one exact Git commit inside a dstack
container. You give it a Git repository URL, a full commit SHA, and a checkout
directory. It fetches that commit, verifies that `HEAD` is exactly the commit
you configured, and then hands control to the workload's entry script.

Use it when you want a generic launcher image whose image digest is stable and
auditable, while the workload identity comes from an attested config file.
The launcher does not make arbitrary code trustworthy by itself. It makes the
question "which bytes ran in the TEE?" answerable.

## What it pins

`git-launcher` has two trust inputs:

| Input | What it identifies | How a verifier checks it |
| --- | --- | --- |
| Launcher image digest | The launcher implementation in this directory | Verify the published image digest and its Sigstore build-provenance attestation |
| Launcher config | The workload repo, commit, and selected entry script | Verify the config through dstack `compose_hash` / `config_id`, or through a derived image digest |

The launcher image is generic. The same image digest can run different
workloads if the attested config changes. A production verifier must therefore
check both the image digest and the config.

For the full verifier procedure, see [Verifying a git-launcher deployment](./VERIFY.md).

## When to use it

Use `git-launcher` when:

- You need to deploy a workload from a specific Git commit, not a branch or tag.
- You want the launcher image to stay small enough to audit directly.
- You want workload install, build, and run logic to live in the workload repo.
- You can attest the launcher config with dstack compose measurements or a
  derived image digest.

Do not use it when:

- You want automatic updates from a branch or tag. Use [`launcher/`](../launcher)
  for that pattern.
- The workload cannot tolerate a clean checkout on every boot.
- You need per-response cryptographic identity from the workload. The launcher
  provides deployment-level identity only; the workload must sign its own
  responses if that property is required.

## How it works

On startup, `git-launcher`:

1. Parses a line-oriented config file. The config is parsed, not sourced.
2. Rejects missing required keys, unknown keys, short SHAs, branches, and tags.
3. Creates or reuses `WORK_DIR` if it is a Git checkout for the same `REPO_URL`.
4. Runs `git fetch --tags --prune origin`.
5. Checks out `COMMIT_SHA` in detached mode.
6. Runs `git reset --hard COMMIT_SHA` and `git clean -ffdx`.
7. Verifies `git rev-parse HEAD` equals `COMMIT_SHA`.
8. Runs the workload entry script, or advanced `RUN_CMD` mode if configured.

Missing commits are hard failures. There is no fallback to a branch, tag,
latest commit, or previous checkout.

## Prepare a workload repo

For workloads you control, use default mode: put a Bash entry script in the
workload repository and pin the commit that contains it.

```text
example-workload/
  entrypoint.sh
  scripts/
  src/
```

`entrypoint.sh` is the workload boundary. It should:

- Install or validate the runtime dependencies the workload needs.
- Build or prepare the application from the pinned source tree.
- Be safe to run again after a container restart.
- Exit non-zero when install, build, configuration, or startup fails.
- `exec` the long-running workload process so it becomes PID 1.
- Keep mutable state, databases, uploads, retained request bodies, and build
  caches outside `WORK_DIR`.

A minimal entry script looks like this:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)
cd "$SCRIPT_DIR"

./scripts/build.sh
exec ./bin/server
```

The launcher runs the script with `bash entrypoint.sh`, so the file does not
need the executable bit.

## Write the launcher config

Create an env-file style config:

```conf
REPO_URL=https://github.com/example-org/example-workload.git
COMMIT_SHA=<full-40-or-64-hex-sha>
WORK_DIR=/var/lib/git-launcher/example-workload
```

Rules:

- `COMMIT_SHA` must be a full 40-hex SHA-1 or 64-hex SHA-256 commit hash.
- `WORK_DIR` is a checkout cache, not application state.
- Blank lines and lines starting with `#` are ignored.
- Matching single or double quotes around a value are stripped once.
- Unknown keys are rejected.
- Values are not shell-expanded during parsing.

## Run locally

Local runs require `bash`, `git`, and standard coreutils. After writing a
config file for a real workload commit, run the launcher script directly:

```sh
./bin/git-launcher ./config.conf
```

Expected startup logs include:

```text
[git-launcher] config:   ./config.conf
[git-launcher] repo:     https://github.com/example-org/example-workload.git
[git-launcher] commit:   <COMMIT_SHA>
[git-launcher] mode:     default (workload repo entry script)
[git-launcher] checking out <COMMIT_SHA>
[git-launcher] scrubbing checkout
[git-launcher] HEAD verified: <COMMIT_SHA>
[git-launcher] exec in /var/lib/git-launcher/example-workload: bash entrypoint.sh
```

Logs are useful for development and smoke tests. They are not signed evidence;
remote verification must use dstack attestation and the image provenance chain
described in [VERIFY.md](./VERIFY.md).

## Deploy with dstack

Always pin the launcher image by OCI digest:

```yaml
image: docker.io/<org>/git-launcher@sha256:<launcher-digest>
```

Do not deploy by mutable tag in production.

### Recommended: attest config through compose

Put the launcher config in the compose file with `configs:`. dstack measures
the compose into the attested app config, so changing either the image digest
or the workload pin changes the attestation.

```yaml
services:
  workload:
    image: docker.io/<org>/git-launcher@sha256:<launcher-digest>
    command: ["/etc/git-launcher/config.conf"]
    configs:
      - source: pin
        target: /etc/git-launcher/config.conf
    environment:
      APP_CONFIG_PATH: /var/lib/example-workload/config.json
    volumes:
      - workload-checkout:/var/lib/git-launcher
      - workload-state:/var/lib/example-workload
      - /var/run/dstack.sock:/var/run/dstack.sock
    restart: unless-stopped

configs:
  pin:
    content: |
      REPO_URL=https://github.com/example-org/example-workload.git
      COMMIT_SHA=<full-40-or-64-hex-sha>
      WORK_DIR=/var/lib/git-launcher/example-workload

volumes:
  workload-checkout:
  workload-state:
```

Use Docker Compose `environment:` for non-secret runtime settings that should
be visible in the attested deployment. Use dstack encrypted secrets, dstack
KMS, or mounted secret files for secrets.

Mount `/var/run/dstack.sock` when the workload uses the dstack SDK for KMS keys
or TDX quotes. The launcher does not use the socket directly.

### Alternative: bake config into a derived image

If you want one image digest to determine both the launcher and the workload
pin, build a small downstream image:

```dockerfile
FROM docker.io/<org>/git-launcher@sha256:<launcher-digest>
COPY web-app.conf /etc/git-launcher/config.conf
CMD ["/etc/git-launcher/config.conf"]
```

Deploy the derived image by its own digest. The derived image digest now binds
the launcher implementation and the config bytes. This is useful when downstream
tooling cannot use compose `configs:`, but it means changing the workload pin
requires rebuilding the derived image.

### Development only: bind-mount config from the host

For local iteration, bind-mounting the config is convenient:

```yaml
services:
  workload:
    image: docker.io/<org>/git-launcher@sha256:<launcher-digest>
    command: ["/etc/git-launcher/config.conf"]
    volumes:
      - ./web-app.conf:/etc/git-launcher/config.conf:ro
      - workload-checkout:/var/lib/git-launcher
      - /var/run/dstack.sock:/var/run/dstack.sock
    restart: unless-stopped

volumes:
  workload-checkout:
```

Do not use this binding as production evidence. The host can replace the file
without changing the dstack attestation.

## Config reference

The launcher accepts these keys only.

| Key | Required | Mode | Meaning |
| --- | --- | --- | --- |
| `REPO_URL` | Yes | All | Git URL of the workload repo. HTTPS and SSH-style Git URLs are accepted by `git clone`. |
| `COMMIT_SHA` | Yes | All | Full 40-hex SHA-1 or 64-hex SHA-256 commit hash. Branches, tags, and short SHAs are rejected. |
| `WORK_DIR` | Yes | All | Local checkout directory. Created if empty. Reused only when it is already a Git checkout whose `origin` exactly matches `REPO_URL`. |
| `REPO_SUBDIR` | No | All | Relative subdirectory to enter before running the entry script or `RUN_CMD`. Must not be absolute or contain `..`. |
| `ENTRYPOINT_SCRIPT` | No | Default | Relative path to the Bash entry script. Defaults to `entrypoint.sh`. Must not be absolute or contain `..`. |
| `RUN_CMD` | No | Advanced | Shell command to exec with `bash -c` instead of the default entry script. Use only when the workload repo cannot contain an entry script. |
| `INSTALL_CMD` | No | Advanced | Shell command to run before `RUN_CMD`. Only valid when `RUN_CMD` is set. |

Default mode is recommended. In default mode, the trust-bearing config is
`REPO_URL`, `COMMIT_SHA`, and whichever of `REPO_SUBDIR` or
`ENTRYPOINT_SCRIPT` you set, because those fields select the code that runs.
`WORK_DIR` is local storage plumbing.

Advanced mode is for third-party repos that you cannot modify. In advanced
mode, `RUN_CMD` and `INSTALL_CMD` are also trust-bearing config because the
launcher executes those strings with `bash -c`.

## Persistent volume behavior

`WORK_DIR` should usually live on a persistent Docker volume, such as
`/var/lib/git-launcher/<workload>`.

On first boot, the launcher clones `REPO_URL` into `WORK_DIR`. On later boots,
it reuses the directory only if it is already a Git checkout whose `origin`
matches `REPO_URL`. Every boot still fetches, checks out `COMMIT_SHA`, resets
tracked files, removes untracked files, and verifies `HEAD`.

Treat `WORK_DIR` as a source cache. Do not store application state, SQLite
databases, uploads, retained bodies, or build artifacts there if the workload
expects them to survive a restart. Use a separate workload-owned volume.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `COMMIT_SHA must be a full... hash` | The config uses a branch, tag, short SHA, uppercase hex, or non-hex text | Use the full lowercase commit hash from the workload repo |
| `git checkout failed for commit...` | The repo at `REPO_URL` does not contain the configured commit, or the launcher cannot fetch it | Check the repo URL, network access, credentials, and commit hash |
| `existing checkout... origin ... but config wants...` | `WORK_DIR` already contains a clone of a different repo | Use a new `WORK_DIR`, or remove the old checkout intentionally |
| `WORK_DIR ... is not empty and is not a git checkout` | The checkout directory contains unrelated files | Point `WORK_DIR` at an empty directory or a valid clone of `REPO_URL` |
| `entry script ... not found` | Default mode is selected, but the pinned commit lacks the configured entry script | Add the script to the workload repo, set `ENTRYPOINT_SCRIPT`, or use advanced `RUN_CMD` mode |
| `INSTALL_CMD requires RUN_CMD` | The config sets install logic without selecting advanced mode | Add `RUN_CMD`, or move install logic into the workload repo entry script |

## Tests

Run the integration test suite from this directory:

```sh
./tests/run-tests.sh
```

The tests create a local Git fixture and verify that the launcher:

- Runs default-mode `entrypoint.sh` and advanced-mode `RUN_CMD`.
- Rejects branches, tags, short SHAs, missing required keys, and unknown keys.
- Refuses path traversal in `REPO_SUBDIR` and `ENTRYPOINT_SCRIPT`.
- Refuses a non-empty non-Git `WORK_DIR`.
- Refuses a reused checkout whose `origin` differs from `REPO_URL`.
- Scrubs dirty tracked files and untracked files before launch.
- Preserves normal process environment variables for the workload.
- Checks that the release workflow publishes image build provenance.

## Release image provenance

The release workflow at
[.github/workflows/git-launcher-release.yml](../.github/workflows/git-launcher-release.yml)
runs the launcher tests, builds and pushes
`docker.io/${DOCKERHUB_ORG}/git-launcher:<tag>`, and publishes a GitHub
artifact attestation for the pushed OCI digest.

The attestation is a signed chain of custody from the GitHub Actions workflow
to the image digest. It is not a bit-for-bit reproducibility claim. A verifier
should compare the deployed digest with the attested digest and audit the
`git-launcher/` source at the commit named by that provenance.

## Audit surface

Before relying on a deployment, audit:

1. `bin/git-launcher`, especially config parsing, SHA validation, checkout,
   cleanup, `HEAD` verification, and the final exec path.
2. The attested launcher config: `REPO_URL`, `COMMIT_SHA`, and any
   `REPO_SUBDIR`, `ENTRYPOINT_SCRIPT`, `RUN_CMD`, or `INSTALL_CMD`.
3. The workload repo at the pinned `COMMIT_SHA`, including the selected entry
   script and all code it starts.

If those three surfaces match the values in the dstack attestation and the
launcher image provenance, the deployment identifies one exact workload commit.
