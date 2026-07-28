#!/bin/bash
# build-combined-pems.sh - Concatenate Let's Encrypt cert files into
# HAProxy combined PEM format (fullchain + privkey in one file).

set -e

source /scripts/functions.sh

CERT_DIR="/etc/haproxy/certs"
mkdir -p "$CERT_DIR"

all_domains=$(get-all-domains.sh)

while IFS= read -r domain; do
    [[ -n "$domain" ]] || continue
    fullchain=$(cert_fullchain_path "$domain")
    privkey=$(cert_privkey_path "$domain")
    combined="${CERT_DIR}/${domain}.pem"
    if [ -f "$fullchain" ] && [ -f "$privkey" ]; then
        cat "$fullchain" "$privkey" > "$combined"
        chmod 600 "$combined"
        echo "Combined PEM created: ${combined}"
    else
        echo "Warning: Cert files missing for ${domain}, skipping"
    fi
done <<< "$all_domains"
