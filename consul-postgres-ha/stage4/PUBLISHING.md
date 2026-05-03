# Stage 4 — image publishing & verification

The stage-4 example needs six container images deployed in lockstep:
`mesh-conn`, `bootstrap-secrets`, `signaling`, `webdemo`, `sidecar`,
`patroni`. CI publishes them to GHCR with Sigstore-backed GitHub Build
Provenance; consumers pin by tag (or, better, by digest) and verify
provenance with `gh attestation verify`.

This doc covers the three paths you'll actually use:

1. **CI publish** (the steady-state)
2. **Manual one-off publish** (dev iteration / breaking glass)
3. **Hot-patch on a live cluster** (debugging without a redeploy)

## 1. CI publish — the steady-state

`.github/workflows/consul-postgres-ha-publish.yml` runs on push to `main`
when any of the six image build contexts (or the workflow itself)
change, and on PRs touching the same paths. Each run:

- Builds all six images via a matrix job.
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
  oci://ghcr.io/dstack-tee/dstack-examples/consul-postgres-ha-mesh-conn:latest \
  --repo Dstack-TEE/dstack-examples

# By digest (preferred — pinned, won't drift):
gh attestation verify \
  oci://ghcr.io/dstack-tee/dstack-examples/consul-postgres-ha-mesh-conn@sha256:<digest> \
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

When iterating fast on `mesh-conn` (or any other component) you don't
want to round-trip through CI for every byte. Two equivalent shortcuts:

### a) `ttl.sh` (24h-disposable, no auth)

```bash
TS=$(date +%s)
TAG=ttl.sh/dstack-mesh-conn-${TS}:24h
docker build -t $TAG consul-postgres-ha/stage4/mesh-conn
docker push $TAG
```

Then point the running cluster at it via `terraform.tfvars`'s
`mesh_conn_image = ...` (and `terraform apply`), or hot-patch the
running CVM (see §3). `ttl.sh` images expire 24h after push.

### b) Personal GHCR namespace (persistent, requires PAT)

If you want a longer-lived dev image without going through main:

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <your-user> --password-stdin
TAG=ghcr.io/<your-user>/consul-postgres-ha-mesh-conn:dev-$(date +%s)
docker build -t $TAG consul-postgres-ha/stage4/mesh-conn
docker push $TAG
```

These manual builds do **not** carry a build-provenance attestation —
that comes from CI's OIDC identity. For anything user-facing, run the
real CI workflow.

## 3. Hot-patch on a live cluster — debugging without a redeploy

Sometimes you need to swap a binary on a running CVM right now,
without re-applying terraform (because `terraform-provider-phala` has
a known bug where `env`-block in-place updates silently no-op — see
`Phala-Network/phala-cloud#246` — and you don't want to recreate CVMs
just to roll a new image).

```bash
GW=dstack-pha-prod5.phala.network
APP_ID=<cvm-app-id>
NEW=ttl.sh/dstack-mesh-conn-<ts>:24h
OLD=$(ssh ... root@${APP_ID}-22.${GW} \
  "docker inspect dstack-mesh-conn-1 --format '{{.Config.Image}}'")

ssh ... root@${APP_ID}-22.${GW} "
  docker pull $NEW
  docker tag $NEW $OLD
  cd /tapp && docker compose \
    --env-file /dstack/.host-shared/.decrypted-env \
    -p dstack -f /tapp/docker-compose.yaml \
    up -d --force-recreate mesh-conn
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
2. Edit `consul-postgres-ha/stage4/cluster-example/terraform.tfvars`
   to that pin.
3. `terraform apply`. Per-CVM compose re-renders and the dstack agent
   recreates each service. (Or hot-patch per §3 if you want to verify
   on one CVM first.)
4. Verify with `gh attestation verify oci://...@<digest>` if you want
   to be sure the image you're pinning was built by this repo.
