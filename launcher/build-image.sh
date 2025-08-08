#!/bin/bash
NAME=$1
if [ -z "$NAME" ]; then
    echo "Usage: $0 <name>[:<tag>]"
    exit 1
fi
# Check if buildkit_20 already exists before creating it
if ! docker buildx inspect buildkit_20 &>/dev/null; then
    docker buildx create --use --driver-opt image=moby/buildkit:v0.20.2 --name buildkit_20
fi
touch pinned-packages.txt
git rev-parse HEAD > .GIT_REV
docker buildx build --platform linux/amd64 --builder buildkit_20 --no-cache --build-arg SOURCE_DATE_EPOCH="0" --output type=docker,name=$NAME,rewrite-timestamp=true .
docker run --rm --entrypoint bash $NAME -c "dpkg -l | grep '^ii' |awk '{print \$2\"=\"\$3}' | sort" > pinned-packages.txt
rm .GIT_REV