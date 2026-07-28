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

# ACME contact address. CERTBOT_EMAIL is the documented name on this path --
# certbot really is the client here -- and ACME_EMAIL is accepted too so one
# variable works in either mode. Optional either way.
ACME_EMAIL=${ACME_EMAIL:-${CERTBOT_EMAIL:-}}
export ACME_EMAIL

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

    dnsman.py set_txt \
        --domain "$txt_domain" \
        --content "$(txt_record_value)"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to set TXT record for $domain"
        exit 1
    fi
}

set_caa_record() {
    local domain="$1"
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
        collect_evidence || echo "Evidence generation failed" >&2
        build_combined_pems || echo "Combined PEM build failed" >&2
        haproxy_reload || true
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
