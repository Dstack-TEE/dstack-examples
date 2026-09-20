#!/bin/bash
#
# Reproducible image build. The same script runs in CI and on a developer
# machine, so everything that ends up in the image -- including the OCI
# labels/annotations that point back to the source -- is derived from the git
# checkout only. Nothing that ends up in the image may depend on wall-clock
# time, the CI run, or the build host, or the digest stops being reproducible.

set -euo pipefail

usage() {
    echo "Usage: $0 [--push <repo>[:<tag>]] [--require-clean]"
    echo ""
    echo "  --push <repo>    Push the built image to the given registry reference."
    echo "  --require-clean  Fail instead of warn when the working tree has"
    echo "                   uncommitted or untracked changes (used by CI)."
    echo ""
    echo "Environment:"
    echo "  SOURCE_URL       Repository URL recorded in the image metadata."
    echo "                   Defaults to the canonical upstream repository; set it"
    echo "                   when building from a fork."
}

PUSH=false
REPO=""
REQUIRE_CLEAN=false
PINS_REGENERATED=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --push)
            PUSH=true
            REPO="${2:-}"
            if [ -z "$REPO" ]; then
                echo "Error: --push requires a repository argument" >&2
                usage >&2
                exit 1
            fi
            shift 2
            ;;
        --require-clean)
            REQUIRE_CLEAN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
done

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: required command '$cmd' not found in PATH" >&2
        exit 1
    fi
}

for required in docker skopeo jq git; do
    require_command "$required"
done

cd "$(dirname "$0")"

# ---------------------------------------------------------------------------
# Source metadata. Every value below is a function of the checked-out commit
# and the committed VERSION file (plus SOURCE_URL for forks), so a rebuild of
# the same commit yields the same labels and therefore the same digest.
# ---------------------------------------------------------------------------
SOURCE_URL="${SOURCE_URL:-https://github.com/Dstack-TEE/dstack-examples}"
SOURCE_URL="${SOURCE_URL%/}"
GIT_REV="$(git rev-parse HEAD)"
VERSION="$(tr -d '[:space:]' < VERSION)"
if [ -z "$VERSION" ]; then
    echo "Error: VERSION file is empty" >&2
    exit 1
fi

# Untracked files count as dirty: scripts/ is copied wholesale into the image.
DIRTY="$(git status --porcelain --untracked-files=all -- .)"
if [ -n "$DIRTY" ]; then
    if [ "$REQUIRE_CLEAN" = true ]; then
        echo "Error: working tree is not clean; refusing to build a release image:" >&2
        echo "$DIRTY" >&2
        exit 1
    fi
    echo "Warning: working tree is not clean; the image will be marked dirty and" >&2
    echo "         its digest will not match a build of commit ${GIT_REV}." >&2
    GIT_REV="${GIT_REV}-dirty"
fi

# Base image, kept in sync with the Dockerfile FROM line. The labels below are
# what someone else checks the supply chain against, so a second FROM -- a
# builder stage, say -- must not silently relabel the image after the wrong
# one. Fail instead, and whoever adds the stage picks the right base.
BASE_REFS=$(sed -n 's/^FROM[[:space:]][[:space:]]*\([^[:space:]][^[:space:]]*\).*/\1/p' Dockerfile)
BASE_REF_COUNT=$(printf '%s\n' "$BASE_REFS" | grep -c . || true)
if [ "$BASE_REF_COUNT" -ne 1 ]; then
    echo "Error: expected exactly one FROM in the Dockerfile, found ${BASE_REF_COUNT}" >&2
    if [ -n "$BASE_REFS" ]; then
        printf '%s\n' "$BASE_REFS" | sed 's/^/  /' >&2
    fi
    echo "Teach this script which one the final image is built on." >&2
    exit 1
fi
BASE_REF="$BASE_REFS"
BASE_NAME="${BASE_REF%%@*}"
BASE_DIGEST="${BASE_REF#*@}"
case "$BASE_NAME" in
    */*) ;;
    *) BASE_NAME="docker.io/library/${BASE_NAME}" ;;
esac
if [ "$BASE_DIGEST" = "$BASE_REF" ]; then
    echo "Error: Dockerfile FROM must pin the base image by digest" >&2
    exit 1
fi

# OCI standard keys: https://github.com/opencontainers/image-spec/blob/main/annotations.md
METADATA=(
    "org.opencontainers.image.title=dstack-ingress"
    "org.opencontainers.image.description=TLS ingress for dstack TEE applications with ACME certificates and attestation evidence"
    "org.opencontainers.image.source=${SOURCE_URL}"
    "org.opencontainers.image.revision=${GIT_REV}"
    "org.opencontainers.image.version=${VERSION}"
    # Version-derived, not commit-derived, and deliberately so. The examples
    # in the tree pin the image by digest, so they can only be updated after
    # the digest exists -- one commit later than the one being built. A link
    # to this commit's tree or README therefore always lands on a page that
    # tells the reader to deploy the previous release. The release page is
    # the one document written after the digest is known, so it is the only
    # one that can describe this image. Both inputs (SOURCE_URL, VERSION) are
    # already build inputs, so the digest stays reproducible.
    "org.opencontainers.image.url=${SOURCE_URL}/releases/tag/dstack-ingress-v${VERSION}"
    "org.opencontainers.image.documentation=${SOURCE_URL}/releases/tag/dstack-ingress-v${VERSION}"
    "org.opencontainers.image.licenses=MIT"
    "org.opencontainers.image.base.name=${BASE_NAME}"
    "org.opencontainers.image.base.digest=${BASE_DIGEST}"
)

# The same key=value set goes to three places: image config labels (docker
# inspect, skopeo inspect), image manifest annotations (visible in the registry
# without fetching the config) and a file inside the image (readable from the
# running container, printed by the entrypoint).
METADATA_ARGS=()
for kv in "${METADATA[@]}"; do
    METADATA_ARGS+=(--label "$kv" --annotation "manifest:$kv")
done

BUILD_INFO=.BUILD_INFO
PACKAGES_BUILT=$(mktemp)
cleanup() {
    rm -f "$BUILD_INFO" "$PACKAGES_BUILT"
    docker rmi "$TEMP_TAG" >/dev/null 2>&1 || true
}
TEMP_TAG="dstack-ingress-temp:$(date +%s)"
trap cleanup EXIT

printf '%s\n' "${METADATA[@]}" > "$BUILD_INFO"

echo "Image metadata:"
sed 's/^/  /' "$BUILD_INFO"
echo ""

# Check if buildkit_20 already exists before creating it
if ! docker buildx inspect buildkit_20 &>/dev/null; then
    docker buildx create --use --driver-opt image=moby/buildkit:v0.20.2 --name buildkit_20
fi
touch pinned-packages.txt
docker buildx build --builder buildkit_20 --no-cache --build-arg SOURCE_DATE_EPOCH="0" \
    "${METADATA_ARGS[@]}" \
    --output type=oci,dest=./oci.tar,rewrite-timestamp=true \
    --output type=docker,name="$TEMP_TAG" .

echo "Build completed, manifest digest:"
echo ""
skopeo inspect oci-archive:./oci.tar | jq .Digest
echo ""

# pinned-packages.txt is an input to the build as well as its record: it is
# tracked, and bind-mounted in to pin apt. Overwriting it in place would make
# the next run of this script see a dirty tree and stamp the image -dirty, so
# compare first and say what happened.
echo "Checking pinned-packages.txt against the built image..."
docker run --rm --entrypoint bash "$TEMP_TAG" \
    -c "dpkg -l | grep '^ii' | awk '{print \$2\"=\"\$3}' | sort" > "$PACKAGES_BUILT"

if cmp -s "$PACKAGES_BUILT" pinned-packages.txt; then
    echo "pinned-packages.txt matches the image ($(wc -l < pinned-packages.txt) packages)"
else
    # Nothing that does not match its own record may leave this machine, so a
    # mismatch is fatal whenever the image is about to be published.
    if [ "$REQUIRE_CLEAN" = true ] || [ "$PUSH" = true ]; then
        echo "Error: the image installed a package set that pinned-packages.txt does not record:" >&2
        diff -u pinned-packages.txt "$PACKAGES_BUILT" | tail -n +3 >&2 || true
        echo "Regenerate it with a local build, commit it, and build again." >&2
        exit 1
    fi
    cp "$PACKAGES_BUILT" pinned-packages.txt
    PINS_REGENERATED=true
    echo "Warning: pinned-packages.txt was out of date and has been regenerated" >&2
    echo "         ($(wc -l < pinned-packages.txt) packages). This image was built with" >&2
    echo "         the old pins -- commit the file and build again." >&2
fi
echo ""

if [ "$PUSH" = true ]; then
    echo "Pushing image to $REPO..."
    skopeo copy --insecure-policy oci-archive:./oci.tar docker://"$REPO"
    echo "Image pushed successfully to $REPO"
elif [ "$PINS_REGENERATED" = true ]; then
    # Withhold the push instructions rather than hand over a command that
    # publishes this image: it was built with the pins that were just replaced,
    # and the dirty check ran before that, so nothing in its labels says so.
    echo "Not printing push instructions: ./oci.tar was built with the pins that"
    echo "were just regenerated, and its revision label does not say so. Commit"
    echo "pinned-packages.txt and build again to get an image worth publishing."
else
    echo "To push the image to a registry, run:"
    echo ""
    echo " $0 --push <repo>[:<tag>]"
    echo ""
    echo "Or use skopeo directly:"
    echo ""
    echo " skopeo copy --insecure-policy oci-archive:./oci.tar docker://<repo>[:<tag>]"
    echo ""
    echo " Pushing image to the project registry:"
    echo " skopeo copy --insecure-policy oci-archive:./oci.tar docker://ghcr.io/dstack-tee/dstack-ingress:${VERSION} --authfile ~/.docker/config.json"
fi
echo ""
