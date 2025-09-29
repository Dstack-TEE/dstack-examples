#!/bin/bash

# Parse command line arguments
PUSH=false
REPO=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --push)
            PUSH=true
            REPO="$2"
            if [ -z "$REPO" ]; then
                echo "Error: --push requires a repository argument"
                echo "Usage: $0 [--push <repo>[:<tag>]]"
                exit 1
            fi
            shift 2
            ;;
        *)
            echo "Usage: $0 [--push <repo>[:<tag>]]"
            exit 1
            ;;
    esac
done
# Check if buildkit_20 already exists before creating it
if ! docker buildx inspect buildkit_20 &>/dev/null; then
    docker buildx create --use --driver-opt image=moby/buildkit:v0.20.2 --name buildkit_20
fi
touch pinned-packages.txt
git rev-parse HEAD > .GIT_REV
TEMP_TAG="dstack-ingress-temp:$(date +%s)"
docker buildx build --builder buildkit_20 --no-cache --build-arg SOURCE_DATE_EPOCH="0" \
    --output type=oci,dest=./oci.tar,rewrite-timestamp=true \
    --output type=docker,name="$TEMP_TAG" .

if [ "$?" -ne 0 ]; then
    echo "Build failed"
    rm .GIT_REV
    exit 1
fi

echo "Build completed, manifest digest:"
echo ""
skopeo inspect oci-archive:./oci.tar | jq .Digest
echo ""

if [ "$PUSH" = true ]; then
    echo "Pushing image to $REPO..."
    skopeo copy --insecure-policy oci-archive:./oci.tar docker://"$REPO"
    echo "Image pushed successfully to $REPO"
else
    echo "To push the image to a registry, run:"
    echo ""
    echo " $0 --push <repo>[:<tag>]"
    echo ""
    echo "Or use skopeo directly:"
    echo ""
    echo " skopeo copy --insecure-policy oci-archive:./oci.tar docker://<repo>[:<tag>]"
    echo ""
    echo " Pushing image to dstacktee org:"
    echo " skopeo copy --insecure-policy oci-archive:./oci.tar docker://dstacktee/dstack-ingress:$(date +%Y%m%d) --authfile ~/.docker/config.json"
fi
echo ""

# Extract package information from the built image
echo "Extracting package information from built image: $TEMP_TAG"
docker run --rm --entrypoint bash "$TEMP_TAG" -c "dpkg -l | grep '^ii' | awk '{print \$2\"=\"\$3}' | sort" > pinned-packages.txt

echo "Package information extracted to pinned-packages.txt ($(wc -l < pinned-packages.txt) packages)"

# Clean up the temporary image from Docker daemon
docker rmi "$TEMP_TAG" 2>/dev/null || true

rm .GIT_REV
