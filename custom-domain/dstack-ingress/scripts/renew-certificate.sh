#!/bin/bash
source /opt/app-venv/bin/activate

INITIAL=false
while getopts "n" opt; do
    case $opt in
    n)
        INITIAL=true
        ;;
    \?)
        echo "Invalid option: -$OPTARG" >&2
        exit 1
        ;;
    esac
done

# Use the unified certbot manager
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
python3 "$SCRIPT_DIR/certman.py" auto --domain "$DOMAIN" --email "$CERTBOT_EMAIL"
CERT_STATUS=$?

if [ $CERT_STATUS -eq 1 ]; then
    echo "Certificate management failed" >&2
    exit 1
elif [ $CERT_STATUS -eq 2 ]; then
    echo "No certificates need renewal, skipping evidence generation"
    if [ "$INITIAL" = false ]; then
        exit 0
    fi
fi

# Generate evidences (for both obtain and renew)
echo "Generating evidence files..."
generate-evidences.sh

# Reload Nginx for certificate updates
# Check if certificate exists to determine if this was obtain or renew
if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    if [ "$INITIAL" = true ]; then
        echo "Certificate obtained successfully for $DOMAIN"
    else
        if ! nginx -s reload; then
            echo "Nginx reload failed" >&2
            exit 2
        else
            echo "Certificate renewed and Nginx reloaded successfully for $DOMAIN"
        fi
    fi
fi

exit 0
