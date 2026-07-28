#!/bin/bash
# evidence-lib.sh - the evidence file format and its TDX quote.
#
# The modes disagree about where the ACME account document and the certificates
# live on disk, so each mode hands its own paths to evidence_collect_*. What the
# evidence *is* -- the file names, the manifest, and the report_data binding --
# is one definition, here.

EVIDENCE_DIR=${EVIDENCE_DIR:-/evidences}

evidence_reset() {
    mkdir -p "$EVIDENCE_DIR"
}

# These files exist to be published, so force them world-readable. lego writes
# its account document and certificates 0600 and cp keeps that mode, which makes
# the evidence server answer 403. Neither carries a private key: the account
# document holds the account URL and status, and a certificate chain is public
# by construction.
evidence_collect_account() {
    cp "$1" "$EVIDENCE_DIR/acme-account.json"
    chmod 644 "$EVIDENCE_DIR/acme-account.json"
}

evidence_collect_cert() {
    local domain="$1" path="$2"
    if [ ! -f "$path" ]; then
        echo "Warning: Certificate not found for domain: $domain"
        return 0
    fi
    cp "$path" "$EVIDENCE_DIR/cert-${domain}.pem"
    chmod 644 "$EVIDENCE_DIR/cert-${domain}.pem"
}

# Hash whatever was collected and bind it into a TDX quote.
evidence_finalize() {
    cd "$EVIDENCE_DIR" || return 1
# Generate checksum for all files
    sha256sum acme-account.json cert-*.pem > sha256sum.txt 2>/dev/null || {
        echo "Error: No certificate files found"
        return 1
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
        return 1
    fi
    echo "Generated evidences successfully"
}

evidence_start_server() {
    [ "${EVIDENCE_SERVER:-true}" = "true" ] || return 0
    # Bind loopback explicitly. Left to itself mini_httpd binds [::]:port first,
    # and since the container has net.ipv6.bindv6only=0 that socket already
    # covers IPv4, so its second bind fails with EADDRINUSE and it logs a
    # permanent "bind: Address already in use". The only consumer is haproxy's
    # be_evidence backend on 127.0.0.1 anyway; listening on every interface also
    # exposed this to other containers on the compose network, bypassing the
    # proxy.
    mini_httpd -d "$EVIDENCE_DIR" -p "${EVIDENCE_PORT:-80}" -h 127.0.0.1 -D -l /dev/stderr &
    echo "Evidence server started on 127.0.0.1:${EVIDENCE_PORT:-80} (mini_httpd)"
}
