#!/bin/bash
# evidence-lib.sh - the evidence file format and its TDX quote.
#
# The modes disagree about where the ACME account document and the certificates
# live on disk, so each mode hands its own paths to evidence_collect_*. What the
# evidence *is* -- the file names, the manifest, and the report_data binding --
# is one definition, here.

EVIDENCE_DIR=${EVIDENCE_DIR:-/evidences}

# Evidence is assembled in a staging directory and published only once the
# quote is in hand. Rewriting the served files in place let a reader catch a
# sha256sum.txt that did not match quote.json, and kept certificates of
# domains that are no longer configured. The staging directory sits inside
# EVIDENCE_DIR because that is a volume mount point: it cannot be swapped
# itself, and rename(2) only works within one filesystem.
evidence_reset() {
    mkdir -p "$EVIDENCE_DIR"
    rm -rf "$EVIDENCE_DIR"/.staging.*
    EVIDENCE_STAGE=$(mktemp -d "$EVIDENCE_DIR/.staging.XXXXXX")
}

# These files exist to be published, so force them world-readable. lego writes
# its account document and certificates 0600 and cp keeps that mode, which makes
# the evidence server answer 403. Neither carries a private key: the account
# document holds the account URL and status, and a certificate chain is public
# by construction.
evidence_collect_account() {
    cp "$1" "$EVIDENCE_STAGE/acme-account.json"
    chmod 644 "$EVIDENCE_STAGE/acme-account.json"
}

evidence_collect_cert() {
    local domain="$1" path="$2"
    if [ ! -f "$path" ]; then
        echo "Warning: Certificate not found for domain: $domain"
        return 0
    fi
    cp "$path" "$EVIDENCE_STAGE/cert-${domain}.pem"
    chmod 644 "$EVIDENCE_STAGE/cert-${domain}.pem"
}

# Hash whatever was collected, bind it into a TDX quote, and publish it.
evidence_finalize() {
    local stage="$EVIDENCE_STAGE" quoted_hash
    if ! (cd "$stage" && sha256sum acme-account.json cert-*.pem > sha256sum.txt) 2>/dev/null; then
        echo "Error: No certificate files found"
        rm -rf "$stage"
        return 1
    fi

    quoted_hash=$(sha256sum "$stage/sha256sum.txt" | awk '{print $1}')
    while [ ${#quoted_hash} -lt 128 ]; do
        quoted_hash="${quoted_hash}0"
    done

    if ! evidence_get_quote "$quoted_hash" > "$stage/quote.json"; then
        echo "Error: Failed to generate evidences"
        rm -rf "$stage"
        return 1
    fi
    chmod 644 "$stage/sha256sum.txt" "$stage/quote.json"
    evidence_publish "$stage"
    echo "Generated evidences successfully"
}

# -f: the guest agent reports errors as an HTTP status with a body, and that
# body must not be published as the quote.
evidence_get_quote() {
    if [[ -S /var/run/dstack.sock ]]; then
        curl -sSf --unix-socket /var/run/dstack.sock "http://localhost/GetQuote?report_data=$1"
    else
        curl -sSf --unix-socket /var/run/tappd.sock "http://localhost/prpc/Tappd.RawQuote?report_data=$1"
    fi
}

# Each rename is atomic. The manifest and quote go last, so they never list a
# file that is not yet in place, and certificates of removed domains go after.
evidence_publish() {
    local stage="$1" names name f
    names=$(awk '{print $2}' "$stage/sha256sum.txt")
    for name in $names sha256sum.txt quote.json; do
        mv -f "$stage/$name" "$EVIDENCE_DIR/$name"
    done
    for f in "$EVIDENCE_DIR"/cert-*.pem; do
        [ -e "$f" ] || continue
        grep -qxF "${f##*/}" <<<"$names" || rm -f "$f"
    done
    rm -rf "$stage"
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
