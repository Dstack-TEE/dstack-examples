#!/bin/bash
# Script to get the latest image for demonstration of upgrade process
#
# CUSTOMIZATION GUIDE:
# This is where you implement your own version detection logic. Some options include:
#
# 1. Read from an onchain contract:
#    - Install web3 tools: apk add --no-cache nodejs npm && npm install -g web3
#    - Query contract: CONTRACT_ADDRESS="0x123..." && IMAGE=$(web3 contract call --abi=/path/to/abi.json $CONTRACT_ADDRESS getLatestImage)
#
# 2. Use another container to check for updates and output the latest image:
#    - Create a separate container that runs periodically (via cron or continuous loop)
#    - This container can perform complex checks (e.g., registry scanning, security validation)
#    - Mount a shared volume between containers: docker-compose.yml:
#      volumes:
#        - shared-data:/shared
#    - The update checker writes to the shared file: echo "new-image:latest" > /shared/latest-image.txt
#    - In this script: IMAGE=$(cat /shared/latest-image.txt)
#
# The script should output the full image reference (including tag or digest) to the file specified by $OUTPUT

OUTPUT=$1

# Add a small delay to simulate network/processing time
sleep 2

MINUTE=$(date +%-M)

# Use time-based selection instead of random to create more predictable upgrade patterns
# This will switch images roughly every minute
if [ $((MINUTE % 2)) -eq 0 ]; then
    echo "nginx@sha256:d67fed8b03f1ed3d2a5e3cbc5ca268ad7a7528adfdd1220c420c8cf4e3802d9c" > "$OUTPUT"
else
    echo "nginx@sha256:81aa342ba08035632898b78d46d0e11d79abeee63b3a6994a44ac34e102ef888" > "$OUTPUT"
fi

