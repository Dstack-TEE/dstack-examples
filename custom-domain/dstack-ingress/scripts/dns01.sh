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

# Whether this container publishes the CAA record that pins issuance to its
# ACME account. On by default under delegation: there, everyone else who can
# write the delegation zone can also answer the delegated challenge.
if [ -n "$DELEGATION_ZONE" ]; then SET_CAA=${SET_CAA:-true}; else SET_CAA=${SET_CAA:-false}; fi
if ! SET_CAA=$(sanitize_boolean "$SET_CAA" "SET_CAA"); then
    exit 1
fi
if [ -n "$DELEGATION_ZONE" ] && [ "$SET_CAA" = "false" ]; then
    echo "Warning: SET_CAA=false with DELEGATION_ZONE: anyone who can write $DELEGATION_ZONE can get certificates for these domains" >&2
fi

# ACME_EMAIL / ACME_STAGING are normalised by entrypoint.sh and exported. The
# contact address is optional; certman.py asks for a contactless account when
# none is given.

cert_fullchain_path() { echo "$(certman.py cert-dir --domain "$1")/fullchain.pem"; }
cert_privkey_path()   { echo "$(certman.py cert-dir --domain "$1")/privkey.pem"; }
# certman.py decides which ACME server is in use (ACME_STAGING,
# ACME_DIRECTORY_URL), and so where its account lives.
acme_account_file()   { certman.py account-file; }
acme_account_uri()    { jq -j '.uri' "$(acme_account_file)"; }

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
    local domain="$1"
    echo "Setting alias record for $domain"
    # shellcheck disable=SC2046 # one flag or none
    dnsman.py set_alias $(with_caa_flag "$domain") \
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
# With SET_CAA the gateway pointer and the CAA share a name. Which form of pointer
# lets the CAA take effect is a provider property, so tell the provider and let
# it pick (an address record unless its servers answer CAA beside a CNAME).
delegated_name() {
    local domain="${1#\*.}"
    echo "${domain}.${DELEGATION_ZONE}"
}

delegation_publish() {
    local domain="$1" target txt_name
    target=$(delegated_name "$domain")

    # shellcheck disable=SC2046 # one flag or none
    dnsman.py set_alias $(with_caa_flag "$domain") --domain "$target" --content "$GATEWAY_DOMAIN" || return 1

    txt_name="$(txt_record_name "$domain").${DELEGATION_ZONE}"
    dnsman.py set_txt --domain "$txt_name" --content "$(txt_record_value)" || return 1
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

# --- CAA -------------------------------------------------------------------
#
# The same steps in both dns-01 setups: publish the record (SET_CAA), then check
# that the CAA in force lets this account issue, then issue once. The account
# is registered before any of it, so the record can name it and the check can
# compare against it.

# Where the CAA goes: the base of a wildcard (RFC 8659), in the delegation zone
# under delegation, behind the operator's CNAME. A wildcard needs the operator
# to alias its base as well, which dnsguide asks for; a base that is a zone apex
# cannot be aliased, so such a domain is not a fit for delegation.
caa_name() {
    if [ -n "$DELEGATION_ZONE" ]; then delegated_name "$1"; else echo "${1#\*.}"; fi
}

# --with-caa when the gateway pointer shares its name with the CAA, so the
# provider can pick a pointer that leaves the CAA visible.
with_caa_flag() {
    [ "$SET_CAA" = "true" ] || return 0
    if [ -n "$DELEGATION_ZONE" ] || [[ "$1" != \*.* ]]; then echo --with-caa; fi
}

publish_caa() {
    local domain="$1" name tag
    [ "$SET_CAA" = "true" ] || return 0
    name=$(caa_name "$domain")
    if [ -z "$DELEGATION_ZONE" ] && [ "$FIRST_PASS" = "true" ] && [[ "$domain" == \*.* ]] && is_zone_apex "$name"; then
        echo "Warning: $name is a zone apex. The CAA issue record published there for $domain"
        echo "replaces every existing issue value and governs every name in the zone that has no CAA"
        echo "record of its own, so other CAs and ACME accounts can no longer issue for them."
        echo "Give those names their own CAA records, or set SET_CAA=false."
    fi
    for tag in $(caa_tags_for "$domain"); do
        echo "Setting CAA record ($tag) for $name"
        dnsman.py set_caa \
            --domain "$name" \
            --caa-tag "$tag" \
            --caa-value "letsencrypt.org;validationmethods=dns-01;accounturi=$(acme_account_uri)" ||
            return 1
    done
}

# Exits 3 when the CAA in force forbids this account to issue for $1; anything
# else leaves the decision to the CA. With SET_CAA the record is our own, just
# written, and resolvers may still cache the one it replaced, so wait for it;
# anyone else's will not change by waiting.
check_caa() {
    local timeout=0
    [ "$SET_CAA" = "true" ] && timeout=$DNS_SETUP_TIMEOUT
    dnsguide.py --caa-only \
        --domain "$1" \
        --caa-tag "$(caa_tag_for "$1")" \
        --challenge dns-01 \
        --account-uri "$(acme_account_uri)" \
        --timeout "$timeout"
}

process_domain() {
    local domain="$1" caa=0

    if ! certman.py register ${ACME_EMAIL:+--email "$ACME_EMAIL"}; then
        echo "Error: could not register the ACME account" >&2
        return 1
    fi

    if [ -n "$DELEGATION_ZONE" ]; then
        # Delegation: the operator created the CNAMEs once, before deploying,
        # and everything they point at is published here -- first, because
        # checking the aliases proves nothing until their targets exist.
        delegation_publish "$domain" || {
            echo "Error: could not publish $domain into $DELEGATION_ZONE" >&2
            return 1
        }
    else
        set_alias_record "$domain"
        set_txt_record "$domain"
    fi
    if ! publish_caa "$domain"; then
        echo "Error: could not publish the CAA record for $domain" >&2
        return 1
    fi

    if [ -n "$DELEGATION_ZONE" ]; then
        # Only the _acme-challenge alias is needed to issue: under dns-01 the
        # CA reads a TXT record and never connects here, so the gateway CNAME
        # and the app-address TXT are about serving, not about issuance.
        # Blocking a renewal on them would turn a routing problem -- fixable at
        # any time -- into an expired certificate, which is not. Renewal wins.
        # The first pass still checks all of them, because that is setup: the
        # operator has just been handed a list of records to create and wants
        # to know whether they got them right.
        local want=challenge-cname
        if [ "$FIRST_PASS" = "true" ]; then
            want=delegated
        fi
        if ! delegation_guide "$domain" "$want"; then
            echo "Error: required DNS records for $domain are not in place" >&2
            return 1
        fi
    fi

    # A refusal the CA would give anyway costs one of Let's Encrypt's five
    # failed validations per hostname per hour; ask DNS first.
    check_caa "$domain" || caa=$?
    if [ "$caa" -eq 3 ]; then
        if [ "$SET_CAA" = "true" ]; then
            echo "Error: the CAA published for $domain was not in force within ${DNS_SETUP_TIMEOUT}s" >&2
        else
            echo "Error: CAA forbids issuing $domain with this account. Fix or delete that CAA record, or set SET_CAA=true to have this container publish one" >&2
        fi
        return 1
    fi

    issue_certificate "$domain"
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
