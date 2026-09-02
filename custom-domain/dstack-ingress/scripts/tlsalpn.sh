#!/bin/bash
# tlsalpn.sh - certificates via lego and the TLS-ALPN-01 challenge, with no DNS
# credentials in the container.
#
# entrypoint.sh validates the shared settings and then execs this file. There is
# no shared orchestration above it and no interface it has to implement -- this
# is simply the program that runs for tls-alpn-01, top to bottom.

set -e

source /scripts/functions.sh
source /scripts/haproxy-lib.sh
source /scripts/evidence-lib.sh

# ACME_EMAIL / ACME_STAGING are normalised by entrypoint.sh and exported, so
# they are already correct here whichever name the operator used.
#
# The contact address is optional. RFC 8555 makes it optional, Let's Encrypt
# stopped sending expiry notifications in 2025, and it does not stay private:
# the account document is published at /evidences/acme-account.json, so an
# address set here is readable by anyone who fetches the evidence.

LEGO_BIN=${LEGO_BIN:-/usr/local/bin/lego}
LEGO_PATH=${LEGO_PATH:-/etc/letsencrypt/lego}
TLSALPN_ADDRESS=${TLSALPN_ADDRESS:-127.0.0.1}
TLSALPN_PORT=${TLSALPN_PORT:-9443}
TLS_TERMINATE_PORT=${TLS_TERMINATE_PORT:-9444}
DNS_SETUP_MODE=${DNS_SETUP_MODE:-wait}
DNS_SETTLE_SECONDS=${DNS_SETTLE_SECONDS:-30}
export LEGO_BIN LEGO_PATH TLSALPN_ADDRESS TLSALPN_PORT DNS_SETUP_MODE

case "$DNS_SETUP_MODE" in
    wait|print|webhook) ;;
    *)
        echo "Error: invalid DNS_SETUP_MODE '$DNS_SETUP_MODE' (expected wait, print or webhook)" >&2
        exit 1
        ;;
esac

# lego stores certificates under $LEGO_PATH/certificates/<domain>.{crt,key};
# the .crt already holds the full chain.
cert_fullchain_path() { echo "${LEGO_PATH}/certificates/${1}.crt"; }
cert_privkey_path()   { echo "${LEGO_PATH}/certificates/${1}.key"; }

acme_account_file() {
    local files=( "${LEGO_PATH}"/accounts/*/*/account.json )
    if [[ ! -f "${files[0]}" ]]; then
        echo "Error: lego account file not found under ${LEGO_PATH}/accounts" >&2
        return 1
    fi
    echo "${files[0]}"
}

setup_py_env() {
    if [ ! -d /opt/app-venv ]; then
        echo "Creating application virtual environment"
        python3 -m venv --system-site-packages /opt/app-venv
    fi
    # shellcheck disable=SC1091
    source /opt/app-venv/bin/activate

    if ! /opt/app-venv/bin/python -c 'import requests'; then
        echo "error: measured Python environment is incomplete" >&2
        return 1
    fi
    echo 'source /opt/app-venv/bin/activate' > /etc/profile.d/app-venv.sh
}

check_lego() {
    if [ ! -x "$LEGO_BIN" ]; then
        echo "Error: lego binary not found at $LEGO_BIN" >&2
        exit 1
    fi
    echo "Using lego for tls-alpn-01: $($LEGO_BIN --version)"
}

require_instance_id() {
    if [ -z "${DSTACK_INSTANCE_ID:-}" ] || [ "$DSTACK_INSTANCE_ID" = "null" ]; then
        echo "Error: could not read instance_id from the dstack guest agent, which" >&2
        echo "tls-alpn-01 needs to pin gateway routing to this instance" >&2
        exit 1
    fi
}

# RFC 8737 forbids tls-alpn-01 for wildcard identifiers, so a wildcard here can
# never succeed. That makes it a configuration error, and it has to be caught
# before the startup sequence below: past that point the container has generated
# a placeholder certificate for a name that will never get a real one, started
# haproxy serving it, and settled into retrying an unsatisfiable config forever.
#
# Fatal for the container rather than skipping the one domain. A mixed config
# does contain the damage -- the other domains are issued normally -- but it
# leaves a self-signed certificate served for the wildcard indefinitely and a
# permanently failing loop, which reads as a TLS bug rather than a typo.
reject_wildcards() {
    local wildcards
    wildcards=$(get-all-domains.sh | grep '^\*\.' || true)
    [ -n "$wildcards" ] || return 0
    echo "Error: tls-alpn-01 cannot issue wildcard certificates (RFC 8737)." >&2
    echo "$wildcards" | sed 's/^/  /' >&2
    echo "Use CHALLENGE_TYPE=dns-01 for wildcards, or list the names individually." >&2
    exit 1
}

# What the gateway should route this hostname to.
#
# dns-01 uses the app id, so the gateway load-balances across every instance of
# the app. tls-alpn-01 cannot: the challenge is answered by whichever instance
# lego runs on, and routing by app id makes the gateway race connections across
# the app's instances while the CA validates from several vantage points at
# once, so the challenge would land on the wrong replica. Pinning to the
# instance id makes validation deterministic -- at the cost of sending all
# traffic to this one instance, so this mode is effectively single-instance.
txt_record_value() { echo "${DSTACK_INSTANCE_ID}:${PORT}"; }

# haproxy owns the public port, but tls-alpn-01 needs the ACME responder to
# complete the TLS handshake itself. So the public port is a plain TCP frontend
# that peeks at the ClientHello and forwards only acme-tls/1 to lego; everything
# else goes to the real TLS frontend on loopback. PROXY protocol carries the
# client address across that hop so the backend still sees the real peer.
emit_peek_frontend() {
    cat <<EOF >>/etc/haproxy/haproxy.cfg
frontend tls_peek
    bind :${PORT}
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }
    # Only the CA sends this ALPN protocol. A client that sends it anyway just
    # reaches lego's responder, which refuses anything but acme-tls/1.
    use_backend be_acme if { req.ssl_alpn -i acme-tls/1 }
    default_backend be_tls_terminate

backend be_acme
    server lego ${TLSALPN_ADDRESS}:${TLSALPN_PORT}

backend be_tls_terminate
    server local 127.0.0.1:${TLS_TERMINATE_PORT} send-proxy-v2

EOF
}

# haproxy refuses to start when the crt directory has no PEM in it, and here it
# has to be listening before the first certificate can exist -- it is what
# forwards the challenge to lego. Seed a placeholder the real cert overwrites.
ensure_placeholder_certs() {
    local all_domains domain pem
    all_domains=$(get-all-domains.sh)
    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        pem="/etc/haproxy/certs/${domain}.pem"
        [ -f "$pem" ] && continue
        echo "Generating placeholder certificate for ${domain}"
        openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
            -keyout /tmp/placeholder.key -out /tmp/placeholder.crt \
            -subj "/CN=${domain#\*.}" >/dev/null 2>&1
        cat /tmp/placeholder.crt /tmp/placeholder.key >"$pem"
        chmod 600 "$pem"
        rm -f /tmp/placeholder.key /tmp/placeholder.crt
    done <<<"$all_domains"
}

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
            # Expected on a first run: ensure_placeholder_certs has already put a
            # self-signed certificate here so haproxy can bind and forward
            # acme-tls/1, and the real one does not exist yet. Leave it alone.
            echo "No certificate for ${domain} yet; serving the placeholder"
        else
            echo "Warning: no certificate or placeholder for ${domain}, skipping"
        fi
    done <<<"$(get-all-domains.sh)"
}

collect_evidence() {
    local account domain
    if ! account=$(acme_account_file); then
        echo "Error: cannot generate evidence without the ACME account file" >&2
        return 1
    fi
    evidence_reset
    evidence_collect_account "$account"
    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        evidence_collect_cert "$domain" "$(cert_fullchain_path "$domain")"
    done <<<"$(get-all-domains.sh)"
    evidence_finalize
}

process_domain() {
    local domain="$1"

    # No wildcard check here: reject_wildcards has already refused to start over
    # the same domain list, which cannot change while the container runs.
    # legoman.py checks independently, guarding the ACME call itself.

    # Register the ACME account first so the CAA record we print can already
    # pin accounturi. Without this the operator would have to add CAA in a
    # second pass, after the account exists.
    if ! legoman.py register ${ACME_EMAIL:+--email "$ACME_EMAIL"}; then
        echo "Error: failed to register the ACME account" >&2
        exit 1
    fi

    local account_uri caa_value
    account_uri=$(legoman.py account-uri 2>/dev/null || true)
    if [ -n "$account_uri" ]; then
        caa_value="letsencrypt.org;validationmethods=tls-alpn-01;accounturi=$account_uri"
    else
        echo "Warning: could not read the ACME account URI; the CAA record will not pin it" >&2
        caa_value="letsencrypt.org;validationmethods=tls-alpn-01"
    fi

    # Wait for the records routing depends on. An existing CAA record is also
    # checked for compatibility -- not because CAA is required (an absent CAA
    # record set permits every CA), but because an incompatible one makes the CA
    # refuse and burns Let's Encrypt's failed-validation budget: 5 per account
    # per hostname per hour.
    if ! dnsguide.py \
        --domain "$domain" \
        --alias-target "$GATEWAY_DOMAIN" \
        --txt-name "$(txt_record_name "$domain")" \
        --txt-value "$(txt_record_value)" \
        --caa-name "${domain#\*.}" \
        --caa-tag "$(caa_tag_for "$domain")" \
        --caa-value "$caa_value" \
        --account-uri "$account_uri" \
        --challenge tls-alpn-01 \
        --mode "$DNS_SETUP_MODE"; then
        echo "Error: required DNS records for $domain are not in place" >&2
        exit 1
    fi

    # Public DNS being correct is not the same as the gateway acting on it. The
    # gateway resolves the app-address TXT itself and caches the answer for the
    # record's TTL, so right after the value changes -- which is every time the
    # CVM instance is replaced, since the record names the instance -- it can
    # still route the challenge to the previous target. Observed exactly that:
    # dnsguide passed, then the CA got "Error getting validation data" because
    # the gateway was still sending it to the old instance.
    # Only on the first pass. The settle wait exists because the TXT value has
    # just changed -- true at startup, and after an instance replacement, which
    # is a fresh container and therefore also a first pass. Renewal passes reuse
    # a record the gateway resolved long ago.
    if [ "$FIRST_PASS" = "true" ] && [ "${DNS_SETTLE_SECONDS}" -gt 0 ]; then
        echo "Waiting ${DNS_SETTLE_SECONDS}s for the gateway's DNS cache to expire"
        sleep "${DNS_SETTLE_SECONDS}"
    fi

    legoman.py auto --domain "$domain" ${ACME_EMAIL:+--email "$ACME_EMAIL"}
}

# Set when certificates have been renewed but not yet applied to haproxy.
# Survives across passes, so a failed apply is retried on the next one.
APPLY_PENDING=false

# One pass over every domain: make sure the records exist, then issue or renew.
# Idempotent, so the first pass and every later one are the same code. There is
# deliberately only one of these -- an earlier split between a one-shot
# bootstrap and a renewal daemon raced for lego's challenge port, and the loser
# still spent one of Let's Encrypt's five failed validations per hostname/hour.
FIRST_PASS=true

run_pass() {
    local domain status failed=0 changed=0
    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        # `if` context, not a bare command: process_domain returns 2 for
        # "nothing to do", and under `set -e` a bare non-zero would kill the
        # whole script on every quiet renewal pass.
        if ( process_domain "$domain" ); then status=0; else status=$?; fi
        case $status in
            0) changed=1 ;;
            2) ;;
            *) echo "Certificate management failed for $domain" >&2; failed=1 ;;
        esac
    done <<<"$(get-all-domains.sh)"

    if [ "$changed" -eq 1 ]; then
        APPLY_PENDING=true
    fi

    # Applying is separate from renewing, and retried until it sticks. A
    # renewal that reaches disk but not haproxy is invisible: the next pass
    # sees a fresh certificate, reports "nothing to renew", and never reloads
    # again -- so haproxy would serve the pre-renewal certificate until it
    # expires, which is soon, because being near expiry is why it renewed.
    if [ "$APPLY_PENDING" = true ]; then
        local applied=true
        collect_evidence || { echo "Evidence generation failed" >&2; applied=false; }
        build_combined_pems || { echo "Combined PEM build failed" >&2; applied=false; }
        haproxy_reload || applied=false
        if [ "$applied" = true ]; then
            APPLY_PENDING=false
        else
            echo "[$(date)] Certificate apply incomplete; retrying on the next pass" >&2
        fi
    fi
    FIRST_PASS=false
    [ "$failed" -eq 0 ]
}

cert_loop() {
    local attempt=0 delay
    while true; do
        if run_pass; then
            attempt=0
            delay=${RENEW_INTERVAL:-43200}
        else
            # The normal state here is "waiting for an operator to create a DNS
            # record", so falling back to the 12-hour interval would be a
            # terrible retry rate.
            attempt=$((attempt + 1))
            delay=$((60 * attempt))
            [ "$delay" -gt 1800 ] && delay=1800
            echo "[$(date)] Pass failed (attempt ${attempt}); retrying in ${delay}s"
        fi
        echo "[$(date)] Next certificate check in ${delay}s"
        sleep "$delay"
    done
}

reject_wildcards
setup_py_env
check_lego
load_dstack_identity
require_instance_id

# Ordering is load-bearing: haproxy has to be forwarding acme-tls/1 before the
# first certificate can exist, so start on a placeholder and let the loop
# converge behind it.
ensure_placeholder_certs
build_combined_pems

haproxy_emit_global
emit_peek_frontend
haproxy_emit_tls_frontend "127.0.0.1:${TLS_TERMINATE_PORT} accept-proxy"
haproxy_emit_backends

evidence_start_server
cert_loop &

exec "$@"
