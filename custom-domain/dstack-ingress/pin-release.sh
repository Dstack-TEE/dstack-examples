#!/bin/bash
#
# Point every example in the repository at a published dstack-ingress image.
#
# A release is only finished once this has run: the compose files and README
# snippets are what people deploy, and they pin the image by digest, so they
# cannot be updated until the digest exists. 2.4 and 2.5 were both tagged and
# published without this step and every example kept deploying 2.3.
#
# The release workflow runs this and opens the resulting pull request. Run it
# by hand only when that failed.

set -euo pipefail

usage() {
    echo "Usage: $0 <image-reference>@sha256:<digest>"
    echo ""
    echo "  e.g. $0 ghcr.io/dstack-tee/dstack-ingress:2.7@sha256:0123...cdef"
}

if [ $# -ne 1 ]; then
    usage >&2
    exit 1
fi

PINNED_REF="$1"
if ! [[ "$PINNED_REF" =~ ^[A-Za-z0-9][A-Za-z0-9./_-]*/dstack-ingress:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$ ]]; then
    echo "Error: not a digest-pinned dstack-ingress reference: $PINNED_REF" >&2
    usage >&2
    exit 1
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Any registry, any version -- the registry moved once already (Docker Hub to
# GHCR in 2.6) and will not be the last thing about the reference to change.
PATTERN='[A-Za-z0-9][A-Za-z0-9./_-]*/dstack-ingress:[^[:space:]@"'"'"']+@sha256:[0-9a-f]{64}'

mapfile -t FILES < <(git grep -lE "$PATTERN" -- '*.yaml' '*.yml' '*.md')

if [ ${#FILES[@]} -eq 0 ]; then
    echo "Error: found no digest-pinned dstack-ingress reference to update." >&2
    echo "The examples are supposed to pin the image; check what changed." >&2
    exit 1
fi

# Compare the references themselves rather than the tree against HEAD, so the
# answer is the same whether or not something else is already uncommitted.
BEFORE="$(git grep -hoE "$PATTERN" -- '*.yaml' '*.yml' '*.md' | sort -u)"
sed -E -i "s#${PATTERN}#${PINNED_REF}#g" "${FILES[@]}"
AFTER="$(git grep -hoE "$PATTERN" -- '*.yaml' '*.yml' '*.md' | sort -u)"

if [ "$BEFORE" = "$AFTER" ]; then
    echo "The examples already pin ${PINNED_REF}; nothing to do."
    exit 0
fi

echo "Pinned ${#FILES[@]} file(s) to ${PINNED_REF}:"
git grep -nE "$PATTERN" -- '*.yaml' '*.yml' '*.md' | sed 's/^/  /'
