#!/bin/bash

set -e

ACME_ACCOUNT_FILE=$(ls /etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory/*/regr.json)

mkdir -p /evidences
cd /evidences || exit
cp ${ACME_ACCOUNT_FILE} acme-account.json

# Get all domains and copy their certificates
all_domains=$(get-all-domains.sh)
if [ -z "$all_domains" ]; then
    echo "Error: No domains found for evidence generation"
    exit 1
fi

# Copy all certificate files
while IFS= read -r domain; do
    [[ -n "$domain" ]] || continue
    cert_file="/etc/letsencrypt/live/${domain}/fullchain.pem"
    if [ -f "$cert_file" ]; then
        cp "$cert_file" "cert-${domain}.pem"
    else
        echo "Warning: Certificate not found for domain: $domain"
    fi
done <<< "$all_domains"

# Generate checksum for all files
sha256sum acme-account.json cert-*.pem > sha256sum.txt 2>/dev/null || {
    echo "Error: No certificate files found"
    exit 1
}

QUOTED_HASH=$(sha256sum sha256sum.txt | awk '{print $1}')

PADDED_HASH="${QUOTED_HASH}"
while [ ${#PADDED_HASH} -lt 128 ]; do
    PADDED_HASH="${PADDED_HASH}0"
done
QUOTED_HASH="${PADDED_HASH}"

if [[ -S /var/run/dstack.sock ]]; then
    curl -s --unix-socket /var/run/dstack.sock "http://localhost/GetQuote?report_data=${QUOTED_HASH}" > quote.json
else
    curl -s --unix-socket /var/run/tappd.sock "http://localhost/prpc/Tappd.RawQuote?report_data=${QUOTED_HASH}" > quote.json
fi
if [ $? -ne 0 ]; then
    echo "Error: Failed to generate evidences"
    exit 1
fi
echo "Generated evidences successfully"
