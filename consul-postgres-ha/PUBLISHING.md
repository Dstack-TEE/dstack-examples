# Stage 4 — image publishing & verification

The stage-4 example needs four container images deployed in lockstep:
`mesh-sidecar`, `patroni`, `webdemo`, `signaling`. CI publishes them to
GHCR with Sigstore-backed GitHub Build Provenance; consumers pin by
tag (or, better, by digest) and verify provenance with
`gh attestation verify`.

`mesh-sidecar` is the consolidated platform-plumbing image — a single
container that runs bootstrap-secrets, mesh-conn, consul, and (on
workers) envoy. It's the heaviest by a wide margin because it
inherits from envoyproxy/envoy and bundles three more binaries on top.

This doc covers the three paths you'll actually use:

1. **CI publish** (the steady-state)
2. **Manual one-off publish** (dev iteration / breaking glass)
3. **Hot-patch on a live cluster** (debugging without a redeploy)

## 1. CI publish — the steady-state

`.github/workflows/consul-postgres-ha-publish.yml` runs on push to `main`
when any of the four image build contexts (or the workflow itself)
change, and on PRs touching the same paths. Each run:

- Builds all four images via a matrix job. The `mesh-sidecar` build
  uses `consul-postgres-ha/` as its docker context (instead of
  `consul-postgres-ha/mesh-sidecar/`) so its Dockerfile can pull
  `bootstrap-secrets/` and `mesh-conn/` Go sources from sibling
  directories.
- On `main`, pushes to `ghcr.io/dstack-tee/dstack-examples/consul-postgres-ha-<name>` with two tags: the long-form commit SHA (`sha-<40-hex>`) and `latest`.
- Generates a GitHub Build Provenance attestation per image via
  `actions/attest-build-provenance@v2`. The attestation is signed by
  Sigstore using a short-lived cert obtained through the workflow's
  GitHub OIDC token — no keys we manage. It binds the image digest to
  the commit SHA, workflow file, and runner identity.
- Pushes the attestation to GHCR alongside the image, so consumers can
  fetch and verify it via either GitHub's API or any cosign-style tool.
- On PRs, builds without pushing or attesting (verification only).

### Verifying a published image as a consumer

```bash
# By tag (lower assurance — `latest` floats):
gh attestation verify \
  oci://ghcr.io/dstack-tee/dstack-examples/consul-postgres-ha-mesh-sidecar:latest \
  --repo Dstack-TEE/dstack-examples

# By digest (preferred — pinned, won't drift):
gh attestation verify \
  oci://ghcr.io/dstack-tee/dstack-examples/consul-postgres-ha-mesh-sidecar@sha256:<digest> \
  --repo Dstack-TEE/dstack-examples
```

A successful verification proves: this image's digest was attested in a
GitHub Actions run on `Dstack-TEE/dstack-examples`, with a workflow
file and commit SHA you can inspect to decide whether to trust it.
Failed or absent attestations should fail your deploy.

For prod-style deploys, pin every image in `terraform.tfvars` to its
`sha-<40-hex>` tag (or a digest) rather than `latest`, so a CI rebuild
of `latest` doesn't silently swap your cluster's bits.

## 2. Manual one-off publish — dev iteration

When iterating fast on the mesh-sidecar (or any other component) you
don't want to round-trip through CI for every byte. Two equivalent
shortcuts. Note that `mesh-sidecar` builds from the
`consul-postgres-ha/` parent dir (it pulls Go sources from sibling
subdirs); the rest build from their own subdir.

### a) `ttl.sh` (24h-disposable, no auth)

```bash
TS=$(date +%s)
TAG=ttl.sh/dstack-mesh-sidecar-${TS}:24h
docker build -t $TAG -f consul-postgres-ha/mesh-sidecar/Dockerfile consul-postgres-ha
docker push $TAG
```

Then point the running cluster at it via `terraform.tfvars`'s
`mesh_sidecar_image = ...` (and `terraform apply`), or hot-patch the
running CVM (see §3). `ttl.sh` images expire 24h after push.

### b) Personal GHCR namespace (persistent, requires PAT)

If you want a longer-lived dev image without going through main:

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <your-user> --password-stdin
TAG=ghcr.io/<your-user>/consul-postgres-ha-mesh-sidecar:dev-$(date +%s)
docker build -t $TAG -f consul-postgres-ha/mesh-sidecar/Dockerfile consul-postgres-ha
docker push $TAG
```

These manual builds do **not** carry a build-provenance attestation —
that comes from CI's OIDC identity. For anything user-facing, run the
real CI workflow.

## 3. Hot-patch on a live cluster — debugging without a redeploy

Sometimes you need to swap a binary on a running CVM right now —
faster than re-running `terraform apply` (which propagates env updates
correctly as of provider `0.2.0-beta.3`, but still goes per-CVM and
takes a minute), useful for testing a fix on one CVM before rolling it
cluster-wide, and the only option on clusters running the older
`0.2.0-beta.2` provider where in-place env updates silently no-op'd
(Phala-Network/phala-cloud#246; fixed by
Phala-Network/terraform-provider-phala#8).

```bash
GW=dstack-pha-prod5.phala.network
APP_ID=<cvm-app-id>
NEW=ttl.sh/dstack-mesh-sidecar-<ts>:24h
OLD=$(ssh ... root@${APP_ID}-22.${GW} \
  "docker inspect dstack-sidecar-1 --format '{{.Config.Image}}'")

ssh ... root@${APP_ID}-22.${GW} "
  docker pull $NEW
  docker tag $NEW $OLD
  cd /tapp && docker compose \
    --env-file /dstack/.host-shared/.decrypted-env \
    -p dstack -f /tapp/docker-compose.yaml \
    up -d --force-recreate sidecar
"
```

The retag tricks compose into using the new bits without touching the
declared image string. This bypasses dstack's attestation hashes —
**fine for dev/smoke, not for prod**. Next CVM reboot re-renders the
compose from the platform-encrypted env and reverts to whatever's in
your tfstate.

## What to bump after a CI publish

When CI publishes a new `latest` and you want to roll it to a running
cluster:

1. Decide whether you're pinning to `:latest` (drifts) or to the
   `:sha-...` tag from the new run (recommended). Find the new SHA by
   inspecting the workflow run's output or `gh run view`.
2. Edit `consul-postgres-ha/cluster-example/terraform.tfvars`
   to that pin.
3. `terraform apply`. Per-CVM compose re-renders and the dstack agent
   recreates each service. (Or hot-patch per §3 if you want to verify
   on one CVM first.)
4. Verify with `gh attestation verify oci://...@<digest>` if you want
   to be sure the image you're pinning was built by this repo.
