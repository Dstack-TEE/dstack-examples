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
source /scripts/cert-lib.sh

# The zone this container writes into, and the switch that turns delegation on.
DELEGATION_ZONE=${DELEGATION_ZONE:-}
export DELEGATION_ZONE
if [ -n "$DELEGATION_ZONE" ] && [ -n "${DELEGATION_PROPAGATION_SECONDS:-}" ]; then
    if ! DELEGATION_PROPAGATION_SECONDS=$(sanitize_nonnegative_integer "$DELEGATION_PROPAGATION_SECONDS" "DELEGATION_PROPAGATION_SECONDS"); then
        exit 1
    fi
    export DELEGATION_PROPAGATION_SECONDS
fi

SET_CAA=${SET_CAA:-false}
if ! SET_CAA=$(sanitize_boolean "$SET_CAA" "SET_CAA"); then
    exit 1
fi

# ACME_EMAIL / ACME_STAGING are normalised by entrypoint.sh and exported. The
# contact address is optional; certman.py asks for a contactless account when
# none is given.

cert_fullchain_path() { echo "$(certman.py cert-dir --domain "$1")/fullchain.pem"; }
cert_privkey_path()   { echo "$(certman.py cert-dir --domain "$1")/privkey.pem"; }
# certman.py decides which ACME server is in use (ACME_STAGING,
# ACME_DIRECTORY_URL), and so where its account lives.
acme_account_file()   { certman.py account-file; }

setup_py_env() {
    if [ ! -d /opt/app-venv ]; then
        echo "Creating application virtual environment"
        python3 -m venv --system-site-packages /opt/app-venv
    fi

    # Activate venv for subsequent steps
    # shellcheck disable=SC1091
    source /opt/app-venv/bin/activate

    # Dependencies are installed and measured in the image at build time.
    # Never resolve or execute code from PyPI while the CVM is starting.
    if ! /opt/app-venv/bin/python -c 'import certbot, requests, boto3, botocore'; then
        echo "error: measured Python environment is incomplete" >&2
        return 1
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

      rm -f /root/.aws/credentials
      (
        umask 077
        cat <<EOF >/root/.aws/credentials
[certbot-source]
aws_access_key_id=${AWS_ACCESS_KEY_ID}
aws_secret_access_key=${AWS_SECRET_ACCESS_KEY}
EOF
      )

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
    local domain="$1" with_caa=()
    # A plain name gets its CAA beside this record.
    if [ "$SET_CAA" = "true" ] && [[ "$domain" != \*.* ]]; then
        with_caa=(--with-caa)
    fi
    echo "Setting alias record for $domain"
    dnsman.py set_alias "${with_caa[@]}" \
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

# --- Full delegation --------------------------------------------------------
#
# The operator aliases three names into a zone this container can write, once,
# before deploying. Everything those names resolve to is published here, so DNS
# never needs touching again -- not when the app id changes with the compose,
# not when the ACME account is recreated, not when the gateway moves.
#
# The gateway pointer and the CAA end up on one name. Which form of pointer
# lets the CAA take effect is a provider property, so tell the provider and let
# it pick (an address record unless its servers answer CAA beside a CNAME).
delegated_name() {
    local domain="${1#\*.}"
    echo "${domain}.${DELEGATION_ZONE}"
}

delegation_publish() {
    local domain="$1" target txt_name
    target=$(delegated_name "$domain")

    dnsman.py set_alias --with-caa --domain "$target" --content "$GATEWAY_DOMAIN" || return 1

    txt_name="$(txt_record_name "$domain").${DELEGATION_ZONE}"
    dnsman.py set_txt --domain "$txt_name" --content "$(txt_record_value)" || return 1
}

# The accounturi CAA goes on the delegated name, beside the gateway pointer.
#
# A wildcard is evaluated at its base (RFC 8659), so it needs the `issuewild`
# tag (beside `issue`) and it needs the operator to have aliased the base as well -- dnsguide
# asks for that fourth CNAME. A base that is a zone apex cannot be aliased at
# all, so such a domain is not a fit for delegation; the CAA check reports the
# record missing rather than the container pretending to have set it.
delegation_publish_caa() {
    local domain="$1" account_file account_uri tag
    account_file=$(acme_account_file) || return 1
    account_uri=$(jq -j '.uri' "$account_file")
    for tag in $(caa_tags_for "$domain"); do
        dnsman.py set_caa \
            --domain "$(delegated_name "$domain")" \
            --caa-tag "$tag" \
            --caa-value "letsencrypt.org;validationmethods=dns-01;accounturi=$account_uri" ||
            return 1
    done
}

# Challenge delegation: this container holds no token for the served domain's
# zone, so the operator creates those records. dnsguide.py is what prints and
# verifies operator-managed records everywhere else in this image, so use it
# here too rather than a second implementation -- it queries two resolvers
# instead of one, parses both CAA wire formats, and understands DNS_SETUP_MODE.
#
# $1 domain, $2 comma-separated record subset, $3.. extra dnsguide flags.
delegation_guide() {
    local domain="$1" include="$2"
    shift 2
    local caa_domain caa_tag
    caa_domain="${domain#\*.}"
    caa_tag=$(caa_tag_for "$domain")

    dnsguide.py \
        --domain "$domain" \
        --alias-target "$GATEWAY_DOMAIN" \
        --txt-name "$(txt_record_name "$domain")" \
        --txt-value "$(txt_record_value)" \
        --caa-name "$caa_domain" \
        --caa-tag "$caa_tag" \
        --challenge dns-01 \
        --delegation-zone "$DELEGATION_ZONE" \
        --mode "${DNS_SETUP_MODE:-wait}" \
        --include "$include" \
        "$@"
}

# Only a zone apex answers SOA for itself. Best effort: a failed lookup says no.
is_zone_apex() {
    local resolvers="${DOH_RESOLVERS:-${DOH_RESOLVER:-https://dns.google/resolve}}"
    curl -fsS --max-time 10 -H 'accept: application/dns-json' \
        "${resolvers%%,*}?name=$1&type=SOA" 2>/dev/null |
        jq -e --arg name "${1,,}" \
            'any(.Answer[]?; .type == 6 and (.name | ascii_downcase | rtrimstr(".")) == $name)' \
            >/dev/null
}

set_caa_record() {
    local domain="$1"

    # Delegation is deliberately NOT gated by SET_CAA: this record is the only
    # thing stopping anyone else who can satisfy the delegated challenge, so it
    # is not optional here.
    if [ -n "${DELEGATION_ZONE:-}" ]; then
        if ! delegation_publish_caa "$domain"; then
            echo "Error: could not publish the CAA record for $domain" >&2
            exit 1
        fi
        return
    fi

    if [ "$SET_CAA" != "true" ]; then
        echo "Skipping CAA record setup"
        return
    fi

    local ACCOUNT_URI
    local account_file

    if ! account_file=$(acme_account_file); then
        echo "Warning: Cannot set CAA record - account file not found"
        echo "This is not critical - certificates can still be issued without CAA records"
        return
    fi

    local caa_domain caa_tag
    caa_domain="${domain#\*.}"

    if [ "$FIRST_PASS" = "true" ] && [[ "$domain" == \*.* ]] && is_zone_apex "$caa_domain"; then
        echo "Warning: $caa_domain is a zone apex. The CAA issue record published there for $domain"
        echo "replaces every existing issue value and governs every name in the zone that has no CAA"
        echo "record of its own, so other CAs and ACME accounts can no longer issue for them."
        echo "Give those names their own CAA records, or set SET_CAA=false."
    fi

    ACCOUNT_URI=$(jq -j '.uri' "$account_file")
    for caa_tag in $(caa_tags_for "$domain"); do
        echo "Adding CAA record ($caa_tag) for $caa_domain, accounturi=$ACCOUNT_URI"
        if ! dnsman.py set_caa \
            --domain "$caa_domain" \
            --caa-tag "$caa_tag" \
            --caa-value "letsencrypt.org;validationmethods=dns-01;accounturi=$ACCOUNT_URI"; then
            echo "Warning: Failed to set CAA record for $domain"
            echo "This is not critical - certificates can still be issued without CAA records"
            echo "Consider disabling CAA records by setting SET_CAA=false if this continues to fail"
        fi
    done
}

process_domain() {
    local domain="$1" status retry=false

    if [ -n "${DELEGATION_ZONE:-}" ]; then
        # Delegation: the operator created three CNAMEs once, before deploying.
        # Everything they point at is published here. Which of them block
        # depends on the pass.
        #
        # Only the _acme-challenge alias is needed to issue: under dns-01 the CA
        # reads a TXT record and never connects here, so the gateway CNAME and
        # the app-address TXT are about serving, not about issuance. Blocking a
        # renewal on them would turn a routing problem -- fixable at any time --
        # into an expired certificate, which is not. Renewal wins.
        #
        # The first pass still checks all three, because that is setup: the
        # operator has just been handed a list of records to create and wants to
        # know whether they got them right.
        # Publish first: the aliases the operator created point at names that
        # have to exist before checking them proves anything.
        if ! delegation_publish "$domain"; then
            echo "Error: could not publish $domain into $DELEGATION_ZONE" >&2
            return 1
        fi
        local want=challenge-cname
        if [ "$FIRST_PASS" = "true" ]; then
            want=delegated
        fi
        if ! delegation_guide "$domain" "$want"; then
            echo "Error: required DNS records for $domain are not in place" >&2
            return 1
        fi
    else
        set_alias_record "$domain"
        set_txt_record "$domain"
    fi

    # The CAA record names our ACME account, so the account has to exist first:
    # try once, write CAA, and try again if the first attempt failed after
    # creating the account. That is the attempt a CAA record naming an earlier
    # account refuses, and set_caa_record has just replaced it. Any other
    # failure would only fail again, spending another of Let's Encrypt's five
    # failed validations per hostname per hour on every pass.
    if [ -n "${DELEGATION_ZONE:-}" ] || [ "$SET_CAA" = "true" ]; then
        acme_account_file >/dev/null 2>&1 || retry=true
    fi
    if issue_certificate "$domain"; then status=0; else status=$?; fi

    set_caa_record "$domain"

    # Never after a success (0) or "nothing to renew" (2): a second attempt
    # would issue another certificate whenever renewal is due. Nor when the
    # attempt did not get as far as creating the account (the CA unreachable,
    # say): then there is no CAA naming it either.
    if [ "$retry" = true ] && [ "$status" -ne 0 ] && [ "$status" -ne 2 ] &&
        acme_account_file >/dev/null 2>&1; then
        echo "First certificate attempt failed for $domain, retrying now that the CAA record names the new account"
        if issue_certificate "$domain"; then status=0; else status=$?; fi
    fi
    return "$status"
}

issue_certificate() {
    source /opt/app-venv/bin/activate
    # The contact address is optional; certman.py asks for a contactless
    # account when none is given.
    certman.py auto --domain "$1" ${ACME_EMAIL:+--email "$ACME_EMAIL"}
}

setup_py_env
setup_certbot_env
load_dstack_identity

have_any_cert() {
    local domain
    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        [ -f "$(cert_fullchain_path "$domain")" ] && [ -f "$(cert_privkey_path "$domain")" ] && return 0
    done <<<"$(get-all-domains.sh)"
    return 1
}

# With a certificate on disk, serve it first and run the pass behind haproxy.
# Running it first would leave every domain unserved until it finishes, and one
# new domain can hold it for long: a certbot run up to its timeout, or up to
# DNS_SETUP_TIMEOUT while its delegation CNAMEs are still being created.
#
# With none there is nothing to serve, and dns-01 needs no inbound traffic, so
# issue first. A pass that ends with still no certificate is fatal; one that
# got some serves them and leaves the loop to retry the rest with backoff.
next_check=0
if ! have_any_cert; then
    startup_status=0
    run_pass || startup_status=$?
    case $startup_status in
        0) next_check=${RENEW_INTERVAL:-43200} ;;
        3) next_check=60 ;;
        *)
            have_any_cert || exit "$startup_status"
            echo "Certificate pass failed; serving the certificates there are and retrying" >&2
            next_check=60
            ;;
    esac
fi
prepare_serving

haproxy_emit_global
haproxy_emit_tls_frontend ":${PORT}$(haproxy_accept_proxy)"
haproxy_emit_backends

evidence_start_server
cert_loop "$next_check" &

exec "$@"
