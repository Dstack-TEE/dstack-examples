#!/bin/bash
# build-combined-pems.sh - Concatenate Let's Encrypt cert files into
# HAProxy combined PEM format (fullchain + privkey in one file).

set -e

CERT_DIR="/etc/haproxy/certs"
mkdir -p "$CERT_DIR"

all_domains=$(get-all-domains.sh)

while IFS= read -r domain; do
    [[ -n "$domain" ]] || continue
    le_dir="/etc/letsencrypt/live/${domain}"
    combined="${CERT_DIR}/${domain}.pem"
    if [ -f "${le_dir}/fullchain.pem" ] && [ -f "${le_dir}/privkey.pem" ]; then
        cat "${le_dir}/fullchain.pem" "${le_dir}/privkey.pem" > "$combined"
        chmod 600 "$combined"
        echo "Combined PEM created: ${combined}"
    else
        echo "Warning: Cert files missing for ${domain}, skipping"
    fi
done <<< "$all_domains"
