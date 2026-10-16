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
    EVIDENCE_STAGE=$(mktemp -d "$EVIDENCE_DIR/.staging.XXXXXX") || return 1
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

# Hash whatever was collected, bind it into an attestation, and publish it.
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

    if ! evidence_attest "$quoted_hash" "$stage"; then
        echo "Error: Failed to generate evidences"
        rm -rf "$stage"
        return 1
    fi
    chmod 644 "$stage"/*
    if ! evidence_publish "$stage"; then
        echo "Error: Failed to publish evidences"
        rm -rf "$stage"
        return 1
    fi
    echo "Generated evidences successfully"
}

# Attest report_data ($1) into the stage directory ($2): quote.json from
# GetQuote as before, and attestation.json from dstack 0.6's /v1/Attest, which
# carries the quote and event log on every platform. An older agent answers
# 404 there. GetQuote is TDX-only, so once Attest has answered, a GetQuote
# failure means another platform and attestation.json stands alone.
evidence_attest() {
    local report_data="$1" stage="$2" status
    if [[ -S /var/run/dstack.sock ]]; then
        status=$(curl -sS -o "$stage/attestation.json" -w '%{http_code}' \
            --unix-socket /var/run/dstack.sock \
            "http://localhost/v1/Attest?report_data=$report_data") || return 1
        case $status in
            200) ;;
            404) rm -f "$stage/attestation.json" ;;
            *)
                echo "Error: Attest answered HTTP $status: $(head -c 300 "$stage/attestation.json")" >&2
                return 1
                ;;
        esac
    fi
    # -f: the guest agent reports errors as an HTTP status with a body, and
    # that body must not be published as the quote.
    if [[ -S /var/run/dstack.sock ]]; then
        curl -sSf --unix-socket /var/run/dstack.sock "http://localhost/GetQuote?report_data=$report_data"
    else
        curl -sSf --unix-socket /var/run/tappd.sock "http://localhost/prpc/Tappd.RawQuote?report_data=$report_data"
    fi > "$stage/quote.json" && return 0
    rm -f "$stage/quote.json"
    [ -e "$stage/attestation.json" ]
}

# Each rename is atomic. The manifest and attestations go last, so they never
# list a file that is not yet in place; certificates of removed domains, and
# an attestation file this run did not produce, go after.
evidence_publish() {
    local stage="$1" f stale=()
    for f in "$EVIDENCE_DIR"/cert-*.pem "$EVIDENCE_DIR"/attestation.json "$EVIDENCE_DIR"/quote.json; do
        if [ -e "$f" ] && [ ! -e "$stage/${f##*/}" ]; then
            stale+=("$f")
        fi
    done
    mv -f "$stage"/acme-account.json "$stage"/cert-*.pem "$EVIDENCE_DIR"/ || return 1
    mv -f "$stage"/* "$EVIDENCE_DIR"/ || return 1
    rm -f "${stale[@]}"
    rm -rf "$stage"
}

# Take down what an earlier run published, for when this one cannot replace it
# yet: no evidence is better than evidence for another container.
evidence_withdraw() {
    rm -f "$EVIDENCE_DIR"/{acme-account.json,cert-*.pem,sha256sum.txt,quote.json,attestation.json}
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
