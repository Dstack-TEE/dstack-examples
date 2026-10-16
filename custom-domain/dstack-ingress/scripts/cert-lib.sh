#!/bin/bash
# cert-lib.sh - the certificate pass and loop, identical in every mode.
#
# The modes differ in how a domain gets its certificate and where it lands on
# disk, not in what happens around that. The sourcing mode defines:
#   process_domain DOMAIN   issue or renew; 0 = changed, 2 = nothing to do
#   cert_fullchain_path DOMAIN, cert_privkey_path DOMAIN
#   acme_account_file       print the path of the ACME account document

# True until the first pass finishes. The first pass is setup and checks more
# than issuance strictly needs; later passes check only what would stop a
# renewal.
# shellcheck disable=SC2034 # read by the mode scripts
FIRST_PASS=true

# Set when certificates have changed but haproxy, or the evidence, does not
# show them yet. They survive across passes, so a failed step is retried on the
# next one, and only that step: evidence that keeps failing must not reload
# haproxy on every retry, as each reload leaves the old workers holding their
# connections for up to TIMEOUT_CLIENT. The evidence starts pending, so every
# start republishes it (see prepare_serving); haproxy has nothing to reload
# before it starts.
RELOAD_PENDING=false
EVIDENCE_PENDING=true

build_combined_pems() {
    local domain fullchain privkey combined
    mkdir -p /etc/haproxy/certs
    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        fullchain=$(cert_fullchain_path "$domain")
        privkey=$(cert_privkey_path "$domain")
        combined="/etc/haproxy/certs/${domain}.pem"
        if [ -f "$fullchain" ] && [ -f "$privkey" ]; then
            cat "$fullchain" "$privkey" > "$combined"
            chmod 600 "$combined"
            echo "Combined PEM created: ${combined}"
        elif [ -f "$combined" ]; then
            # tls-alpn-01 seeds a placeholder here before its first certificate
            # exists, so haproxy can bind and forward acme-tls/1. Leave it alone.
            echo "No certificate for ${domain} yet; serving the existing PEM"
        else
            echo "Warning: no certificate for ${domain}, skipping"
        fi
    done <<<"$(get-all-domains.sh)"
}

collect_evidence() {
    local account domain
    if ! account=$(acme_account_file); then
        echo "Error: cannot generate evidence without the ACME account file" >&2
        return 1
    fi
    evidence_reset || return 1
    evidence_collect_account "$account"
    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        evidence_collect_cert "$domain" "$(cert_fullchain_path "$domain")"
    done <<<"$(get-all-domains.sh)"
    evidence_finalize
}

# Empty when the domain has no certificate yet.
cert_checksum() { sha256sum "$(cert_fullchain_path "$1")" 2>/dev/null || true; }

# Run once, just before haproxy starts. haproxy reads the PEMs itself, so there
# is nothing to reload yet. What the last run left in /evidences attests a
# container that may no longer be running, so republish the evidence unless a
# startup pass already has -- it is local and quick -- or, if that is not
# possible yet, serve none. A first start has no ACME account to collect yet.
prepare_serving() {
    build_combined_pems
    RELOAD_PENDING=false
    [ "$EVIDENCE_PENDING" = true ] || return 0
    if acme_account_file >/dev/null 2>&1 && collect_evidence; then
        EVIDENCE_PENDING=false
    else
        evidence_withdraw
    fi
}

# One pass over every domain: make sure the records are right, then issue or
# renew. Idempotent, so the first pass and every later one are the same code.
run_pass() {
    local domain status failed=0 changed=0 before
    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        before=$(cert_checksum "$domain")
        # `if` context, not a bare command: process_domain returns 2 for
        # "nothing to do", and under `set -e` a bare non-zero would kill the
        # whole script on every quiet renewal pass.
        if ( process_domain "$domain" ); then status=0; else status=$?; fi
        # A step after issuance can still fail (a CAA write, a timeout that
        # kills the client after it saved the certificate). The new certificate
        # is on disk by then and the next pass will find it current, so apply
        # it now or never.
        [ "$(cert_checksum "$domain")" = "$before" ] || changed=1
        case $status in
            0) changed=1 ;;
            2) ;;
            *) echo "Certificate management failed for $domain" >&2; failed=1 ;;
        esac
    done <<<"$(get-all-domains.sh)"

    if [ "$changed" -eq 1 ]; then
        RELOAD_PENDING=true
        EVIDENCE_PENDING=true
    fi

    # Applying is separate from renewing, and retried until it sticks. A
    # renewal that reaches disk but not haproxy is invisible: the next pass
    # sees a fresh certificate, reports "nothing to renew", and never reloads
    # again -- so haproxy would serve the pre-renewal certificate until it
    # expires, which is soon, because being near expiry is why it renewed.
    if [ "$EVIDENCE_PENDING" = true ]; then
        if collect_evidence; then
            EVIDENCE_PENDING=false
        else
            echo "[$(date)] Evidence generation failed; retrying on the next pass" >&2
        fi
    fi
    if [ "$RELOAD_PENDING" = true ]; then
        if build_combined_pems && haproxy_reload; then
            RELOAD_PENDING=false
        else
            echo "[$(date)] Certificate apply failed; retrying on the next pass" >&2
        fi
    fi
    FIRST_PASS=false
    [ "$failed" -eq 0 ] || return 1
    # Not a quiet pass either: wait the retry backoff, not RENEW_INTERVAL.
    [ "$RELOAD_PENDING" = false ] && [ "$EVIDENCE_PENDING" = false ] || return 3
}

# $1: seconds to wait before the first pass, for a caller that has just run one.
cert_loop() {
    local attempt=0 delay="${1:-0}"
    while true; do
        if [ "$delay" -gt 0 ]; then
            echo "[$(date)] Next certificate check in ${delay}s"
            sleep "$delay"
        fi
        if run_pass; then
            attempt=0
            delay=${RENEW_INTERVAL:-43200}
        else
            # Often the failure is a DNS record an operator has yet to create,
            # so falling back to the 12-hour interval would be a terrible
            # retry rate.
            attempt=$((attempt + 1))
            delay=$((60 * attempt))
            [ "$delay" -gt 1800 ] && delay=1800
            echo "[$(date)] Pass failed (attempt ${attempt}); retrying" >&2
        fi
    done
}
