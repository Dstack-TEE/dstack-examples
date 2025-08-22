#!/bin/bash

ACME_ACCOUNT_FILE=$(ls /etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory/*/regr.json)
CERT_FILE=/etc/letsencrypt/live/${DOMAIN}/fullchain.pem

mkdir -p /evidences
cd /evidences || exit
cp "${ACME_ACCOUNT_FILE}" acme-account.json
cp "${CERT_FILE}" cert.pem

sha256sum acme-account.json cert.pem > sha256sum.txt

QUOTED_HASH=$(sha256sum sha256sum.txt | awk '{print $1}')

# Pad QUOTED_HASH with zeros to ensure it's 128 characters long
PADDED_HASH="${QUOTED_HASH}"
while [ ${#PADDED_HASH} -lt 128 ]; do
    PADDED_HASH="${PADDED_HASH}0"
done
QUOTED_HASH="${PADDED_HASH}"

if [[ -e /var/run/dstack.sock ]]; then
    curl -s --unix-socket /var/run/dstack.sock "http://localhost/prpc/GetQuote?report_data=${QUOTED_HASH}" > quote.json
else
    curl -s --unix-socket /var/run/tappd.sock "http://localhost/prpc/Tappd.RawQuote?report_data=${QUOTED_HASH}" > quote.json
fi
if [ $? -ne 0 ]; then
    echo "Error: Failed to generate evidences"
    exit 1
fi
echo "Generated evidences successfully"
