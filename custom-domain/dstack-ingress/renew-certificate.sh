#!/bin/bash
source /opt/app-venv/bin/activate

echo "Renewing certificate for $DOMAIN"

# Perform the actual renewal and capture the output
RENEW_OUTPUT=$(certbot renew --non-interactive 2>&1)
RENEW_STATUS=$?

# Check if renewal failed
if [ $RENEW_STATUS -ne 0 ]; then
    echo "Certificate renewal failed" >&2
    exit 1
fi

# Check if no renewals were attempted
if echo "$RENEW_OUTPUT" | grep -q "No renewals were attempted"; then
    echo "No certificates need renewal, skipping evidence generation"
    exit 0
fi

# Only generate evidences if certificates were actually renewed
generate-evidences.sh

# Only reload Nginx if we got here (meaning certificates were renewed)
if ! nginx -s reload; then
    echo "Nginx reload failed" >&2
    exit 2
fi

exit 0

