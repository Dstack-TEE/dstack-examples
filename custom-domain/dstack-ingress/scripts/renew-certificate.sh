#!/bin/bash
source /opt/app-venv/bin/activate

DOMAIN=$1

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# dns-01 runs certbot with a DNS provider plugin. tls-alpn-01 runs lego: certbot
# never implemented the challenge and the acme library removed it in 4.2.0.
if [ "${CHALLENGE_TYPE:-dns-01}" = "tls-alpn-01" ]; then
    python3 "$SCRIPT_DIR/legoman.py" auto --domain "$DOMAIN" --email "$CERTBOT_EMAIL"
else
    python3 "$SCRIPT_DIR/certman.py" auto --domain "$DOMAIN" --email "$CERTBOT_EMAIL"
fi
CERT_STATUS=$?

if [ $CERT_STATUS -eq 1 ]; then
    echo "Certificate management failed" >&2
elif [ $CERT_STATUS -eq 2 ]; then
    echo "No certificates need renewal, skipping evidence generation"
fi

# Propagate the tri-state: 0 = certificate changed, 2 = nothing to do, 1 =
# failure. This used to always exit 0, which told the caller "something
# changed" on every single pass -- so evidences were regenerated and haproxy
# reloaded every 12 hours whether or not a certificate had moved.
exit $CERT_STATUS