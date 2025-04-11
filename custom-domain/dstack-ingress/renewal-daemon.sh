#!/bin/bash
set -e

while true; do
    echo "[$(date)] Checking for certificate renewal"
    /usr/bin/env renew-certificate.sh || echo "Certificate renewal check failed with status $?"
    # Sleep for 12 hours (43200 seconds) before next renewal check
    echo "[$(date)] Next renewal check in 12 hours"
    sleep 43200
done
