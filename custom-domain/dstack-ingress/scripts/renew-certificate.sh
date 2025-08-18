#!/bin/bash
source /opt/app-venv/bin/activate

DOMAIN=$1

# Use the unified certbot manager
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
python3 "$SCRIPT_DIR/certman.py" auto --domain "$DOMAIN" --email "$CERTBOT_EMAIL"
CERT_STATUS=$?

if [ $CERT_STATUS -eq 1 ]; then
    echo "Certificate management failed" >&2
    exit 1
elif [ $CERT_STATUS -eq 2 ]; then
    echo "No certificates need renewal, skipping evidence generation"
fi

exit 0
