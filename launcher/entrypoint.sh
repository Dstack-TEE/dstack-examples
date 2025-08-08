#!/bin/bash

PROJECT_NAME=launched
WORKDIR=/app-data
EXTERNAL_PORT=10080
SERVICE_NAME=server


cd $WORKDIR || exit

check-update() {
    echo "Checking for updates..."
    get-latest.sh latest.tmp
    if [ -f latest.tmp ]; then
        if [ -f latest ] && diff -q latest.tmp latest > /dev/null; then
            echo "No changes detected in latest version"
            rm -f latest.tmp
            return 1
        fi
        mv latest.tmp latest
        return 0
    fi
    echo "No update found"
    return 1
}

mk-compose() {
    if [ ! -f latest ] || [ ! -s latest ]; then
        echo "Error: latest file not found or empty"
        return 1
    fi
    cat <<EOF > docker-compose.yml
services:
    $SERVICE_NAME:
        image: $(cat latest)
        ports:
            - "$EXTERNAL_PORT:80"
        restart: always
EOF
    echo "docker-compose.yml created"
    return 0
}

apply-update() {
    echo "Making docker-compose.yml..."
    if ! mk-compose; then
        echo "Error: Failed to make docker-compose.yml"
        return 1
    fi
    echo "Applying update..."
    docker-compose -p $PROJECT_NAME up -d --remove-orphans
    echo "Update applied"
    return 0
}

rm -f latest
while true; do
    check-update
    apply-update
    sleep 5
done
