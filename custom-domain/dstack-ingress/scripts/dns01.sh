#!/bin/bash
# dns01.sh - certificates via certbot and a DNS provider API.
#
# entrypoint.sh validates the shared settings and then execs this file. There is
# no shared orchestration above it and no interface it has to implement -- this
# is simply the program that runs for dns-01, top to bottom.

set -e

source /scripts/functions.sh
source /scripts/haproxy-lib.sh
source /scripts/evidence-lib.sh

# ACME_EMAIL / ACME_STAGING are normalised by entrypoint.sh and exported. The
# contact address is optional; certman.py asks for a contactless account when
# none is given.

# certbot stores certificates under /etc/letsencrypt/live/<domain>/.
cert_fullchain_path() { echo "/etc/letsencrypt/live/$(cert_dir_name "$1")/fullchain.pem"; }
cert_privkey_path()   { echo "/etc/letsencrypt/live/$(cert_dir_name "$1")/privkey.pem"; }

setup_py_env() {
    if [ ! -d /opt/app-venv ]; then
        echo "Creating application virtual environment"
        python3 -m venv --system-site-packages /opt/app-venv
    fi

    # Activate venv for subsequent steps
    # shellcheck disable=SC1091
    source /opt/app-venv/bin/activate

    if [ ! -f /.venv_bootstrapped ]; then
        echo "Bootstrapping certbot dependencies"
        pip install --upgrade pip
        pip install certbot requests boto3 botocore
        touch /.venv_bootstrapped
    fi

    ln -sf /opt/app-venv/bin/certbot /usr/local/bin/certbot
    echo 'source /opt/app-venv/bin/activate' > /etc/profile.d/app-venv.sh
}

setup_certbot_env() {
    # Ensure the virtual environment is active for certbot configuration
    # shellcheck disable=SC1091
    source /opt/app-venv/bin/activate

    if [ "${DNS_PROVIDER}" = "route53" ]; then
      mkdir -p /root/.aws

      cat <<EOF >/root/.aws/config
[profile certbot]
role_arn=${AWS_ROLE_ARN}
source_profile=certbot-source
region=${AWS_REGION:-us-east-1}
EOF

      cat <<EOF >/root/.aws/credentials
[certbot-source]
aws_access_key_id=${AWS_ACCESS_KEY_ID}
aws_secret_access_key=${AWS_SECRET_ACCESS_KEY}
EOF

      unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
      export AWS_PROFILE=certbot
    fi

    # Use the unified certbot manager to install plugins and setup credentials
    echo "Installing DNS plugins and setting up credentials"
    certman.py setup
    if [ $? -ne 0 ]; then
        echo "Error: Failed to setup certbot environment"
        exit 1
    fi
}

set_alias_record() {
    local domain="$1"
    if [ -n "${ACME_CHALLENGE_ALIAS:-}" ]; then
        # certbot validates the challenge at the base name even for a wildcard,
        # so the _acme-challenge CNAME must use the base domain (strip "*.").
        local base="${domain#\*.}"
        echo "[challenge-delegation] Not touching ${domain}'s own zone (token is scoped to the delegated zone)."
        echo "[challenge-delegation] Set these in your production zone yourself (static, one-time):"
        echo "    ${domain}  CNAME  ${GATEWAY_DOMAIN}"
        echo "    _acme-challenge.${base}  CNAME  _acme-challenge.${base}.${ACME_CHALLENGE_ALIAS}"
        return
    fi
    echo "Setting alias record for $domain"
    dnsman.py set_alias \
        --domain "$domain" \
        --content "$GATEWAY_DOMAIN"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to set alias record for $domain"
        exit 1
    fi
    echo "Alias record set for $domain"
}

txt_record_value() { echo "${APP_ID:-$DSTACK_APP_ID}:${PORT}"; }

set_txt_record() {
    local domain="$1"
    local txt_domain
    txt_domain=$(txt_record_name "$domain")

    if [ -n "${ACME_CHALLENGE_ALIAS:-}" ]; then
        echo "[challenge-delegation] Set this in your production zone yourself (static, one-time):"
        echo "    ${txt_domain}  TXT  \"$(txt_record_value)\""
        return
    fi

    dnsman.py set_txt \
        --domain "$txt_domain" \
        --content "$(txt_record_value)"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to set TXT record for $domain"
        exit 1
    fi
}

# In delegation mode we have NO token for the served domain's zone, so we cannot
# set the accounturi CAA ourselves. That CAA is the forge-prevention (only this
# enclave's ACME account may issue), so this path is deliberately NOT gated by
# SET_CAA and fails closed if the record is confirmed absent -- otherwise anyone
# who can satisfy the delegated DNS-01 challenge could obtain a cert for the
# domain. Set ALLOW_MISSING_CAA=true to override (accept the risk).
verify_delegation_caa() {
    local domain="$1"
    local account_file account_uri caa_domain caa_tag caa_value resp status found

    if ! account_file=$(get_letsencrypt_account_file); then
        echo "ERROR: cannot read the Let's Encrypt account file to determine the required accounturi CAA" >&2
        caa_fail_or_allow "$domain"
        return
    fi
    caa_domain="${domain#\*.}"
    caa_tag=$(caa_tag_for "$domain")
    account_uri=$(jq -j '.uri' "$account_file")
    caa_value="letsencrypt.org;validationmethods=dns-01;accounturi=$account_uri"

    echo "[challenge-delegation] Set this CAA in your production zone (static, one-time):"
    echo "    ${caa_domain}  CAA  0 ${caa_tag} \"${caa_value}\""

    # Verify via DNS-over-HTTPS (dig is not installed in the image; curl+jq are).
    resp=$(curl -s --max-time 10 "https://dns.google/resolve?name=${caa_domain}&type=257" 2>/dev/null || true)
    if [ -z "$resp" ]; then
        echo "WARNING: could not reach dns.google to verify the CAA (network issue) — NOT confirmed; continuing"
        return
    fi
    status=$(echo "$resp" | jq -r '.Status // empty' 2>/dev/null || true)
    if [ "$status" != "0" ]; then
        echo "WARNING: CAA DoH query for ${caa_domain} returned status ${status:-unknown} — NOT confirmed; continuing"
        return
    fi
    # Literal (grep -F) match on the CAA data fields — the account URI contains
    # '/' and '.', which must not be treated as regex.
    found=$(echo "$resp" | jq -r '.Answer // [] | .[] | .data' 2>/dev/null | grep -F "accounturi=$account_uri" || true)
    if [ -n "$found" ]; then
        echo "[challenge-delegation] Verified: accounturi CAA is present for $caa_domain"
        return
    fi
    echo "ERROR: the accounturi CAA is NOT present for $caa_domain." >&2
    echo "ERROR: without it, anyone who can satisfy the delegated DNS-01 challenge could obtain a" >&2
    echo "ERROR: publicly-trusted certificate for this domain (forged TLS termination)." >&2
    caa_fail_or_allow "$domain"
}

caa_fail_or_allow() {
    local domain="$1"
    if [ "${ALLOW_MISSING_CAA:-false}" = "true" ]; then
        echo "WARNING: ALLOW_MISSING_CAA=true — continuing without a verified accounturi CAA for $domain"
        return 0
    fi
    echo "ERROR: refusing to continue without the accounturi CAA for $domain." >&2
    echo "ERROR: set the CAA record shown above, or ALLOW_MISSING_CAA=true to override." >&2
    exit 1
}

set_caa_record() {
    local domain="$1"

    # Delegation mode is handled separately and is NOT gated by SET_CAA.
    if [ -n "${ACME_CHALLENGE_ALIAS:-}" ]; then
        verify_delegation_caa "$domain"
        return
    fi

    if [ "$SET_CAA" != "true" ]; then
        echo "Skipping CAA record setup"
        return
    fi

    local ACCOUNT_URI
    local account_file

    if ! account_file=$(get_letsencrypt_account_file); then
        echo "Warning: Cannot set CAA record - account file not found"
        echo "This is not critical - certificates can still be issued without CAA records"
        return
    fi

    local caa_domain caa_tag
    caa_domain="${domain#\*.}"
    caa_tag=$(caa_tag_for "$domain")

    ACCOUNT_URI=$(jq -j '.uri' "$account_file")
    echo "Adding CAA record ($caa_tag) for $caa_domain, accounturi=$ACCOUNT_URI"
    dnsman.py set_caa \
        --domain "$caa_domain" \
        --caa-tag "$caa_tag" \
        --caa-value "letsencrypt.org;validationmethods=dns-01;accounturi=$ACCOUNT_URI"

    if [ $? -ne 0 ]; then
        echo "Warning: Failed to set CAA record for $domain"
        echo "This is not critical - certificates can still be issued without CAA records"
        echo "Consider disabling CAA records by setting SET_CAA=false if this continues to fail"
    fi
}

process_domain() {
    local domain="$1" first status

    set_alias_record "$domain"
    set_txt_record "$domain"

    # The CAA record names our ACME account, so the account has to exist first:
    # try once, write CAA, try again. The first attempt is expected to fail when
    # a CAA record from an earlier account is still in place.
    if issue_certificate "$domain"; then first=0; else first=$?; fi
    if [ "$first" -eq 1 ]; then
        echo "First certificate attempt failed for $domain, retrying after the CAA record is set"
    fi

    set_caa_record "$domain"

    if issue_certificate "$domain"; then status=0; else status=$?; fi

    # Either attempt producing a certificate counts as a change. Reporting only
    # the second one hid the common case: on a clean first deployment attempt
    # one obtains the certificate and attempt two reports "nothing to renew",
    # so the pass looked quiet and skipped evidence generation entirely.
    if [ "$first" -eq 0 ] || [ "$status" -eq 0 ]; then
        return 0
    fi
    return "$status"
}

issue_certificate() {
    source /opt/app-venv/bin/activate
    # The contact address is optional; certman.py asks for a contactless
    # account when none is given.
    certman.py auto --domain "$1" ${ACME_EMAIL:+--email "$ACME_EMAIL"}
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
        else
            echo "Warning: Cert files missing for ${domain}, skipping"
        fi
    done <<<"$(get-all-domains.sh)"
}

collect_evidence() {
    local account domain
    if ! account=$(get_letsencrypt_account_file); then
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

# Set when certificates have been renewed but not yet applied to haproxy.
# Survives across passes, so a failed apply is retried on the next one.
APPLY_PENDING=false

# One pass over every domain: make the DNS records right, then issue or renew.
# Idempotent, so the first pass and every later one are the same code.
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
    [ "$failed" -eq 0 ]
}

# $1: seconds to wait before the first pass. dns-01 issues before it serves, so
# the caller has already run a pass by the time we get here; without this the
# loop would immediately repeat it -- two full passes, and for a single domain
# four certbot invocations plus a duplicate round of DNS writes, on every start.
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
            attempt=$((attempt + 1))
            delay=$((60 * attempt))
            [ "$delay" -gt 1800 ] && delay=1800
            echo "[$(date)] Pass failed (attempt ${attempt}); retrying" >&2
        fi
    done
}

setup_py_env
setup_certbot_env
load_dstack_identity

# dns-01 needs no inbound traffic, so keep the original order: certificate
# first, serving second. A failure here is fatal, as it always was.
run_pass
build_combined_pems

haproxy_emit_global
haproxy_emit_tls_frontend ":${PORT}"
haproxy_emit_backends

evidence_start_server
cert_loop "${RENEW_INTERVAL:-43200}" &

exec "$@"
