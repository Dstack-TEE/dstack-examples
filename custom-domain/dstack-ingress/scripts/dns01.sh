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

# The zone this container writes into, and the switch that turns delegation on.
DELEGATION_ZONE=${DELEGATION_ZONE:-}
export DELEGATION_ZONE

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

# --- Full delegation --------------------------------------------------------
#
# The operator aliases three names into a zone this container can write, once,
# before deploying. Everything those names resolve to is published here, so DNS
# never needs touching again -- not when the app id changes with the compose,
# not when the ACME account is recreated, not when the gateway moves.
#
# How the delegated name points at the gateway.
#
# A CNAME is better -- a gateway that moves is followed automatically -- but the
# same name also has to carry the CAA, and RFC 1034 says a CNAME excludes every
# other type at its name. Cloudflare allows the pair anyway, and Let's Encrypt
# honours the CAA it finds there (verified against the staging CA). Providers
# that enforce the standard reject it, so they get an address record instead:
# A and CAA coexist legally, at the cost of re-resolving GATEWAY_DOMAIN once a
# pass rather than letting DNS follow it.
#
# Default per provider, since only Cloudflare is known to allow the pair.
# DELEGATION_GATEWAY_RECORD overrides it either way.
delegation_gateway_record() {
    if [ -n "${DELEGATION_GATEWAY_RECORD:-}" ]; then
        echo "$DELEGATION_GATEWAY_RECORD"
        return
    fi
    case "$(dnsman.py provider 2>/dev/null)" in
        cloudflare) echo cname ;;
        *) echo a ;;
    esac
}

delegated_name() {
    local domain="${1#\*.}"
    echo "${domain}.${DELEGATION_ZONE}"
}

delegation_publish() {
    local domain="$1" target txt_name
    target=$(delegated_name "$domain")

    case "$(delegation_gateway_record)" in
        cname)
            dnsman.py set_alias --domain "$target" --content "$GATEWAY_DOMAIN" || return 1
            ;;
        a)
            # For providers that refuse a CAA beside a CNAME. Costs the
            # automatic following of a gateway that moves: the address is
            # re-resolved once per pass instead.
            local addrs addr
            addrs=$(dnsguide.py --resolve "$GATEWAY_DOMAIN" 2>/dev/null)
            if [ -z "$addrs" ]; then
                echo "Error: could not resolve $GATEWAY_DOMAIN to any address" >&2
                return 1
            fi
            addr=$(echo "$addrs" | head -1)
            dnsman.py set_a --domain "$target" --content "$addr" || return 1
            ;;
        *)
            echo "Error: invalid DELEGATION_GATEWAY_RECORD (expected cname or a)" >&2
            return 1
            ;;
    esac

    txt_name="$(txt_record_name "$domain").${DELEGATION_ZONE}"
    dnsman.py set_txt --domain "$txt_name" --content "$(txt_record_value)" || return 1
}

# The accounturi CAA goes on the delegated name, beside the gateway pointer.
#
# A wildcard is evaluated at its base (RFC 8659), so it needs the `issuewild`
# tag and it needs the operator to have aliased the base as well -- dnsguide
# asks for that fourth CNAME. A base that is a zone apex cannot be aliased at
# all, so such a domain is not a fit for delegation; the CAA check reports the
# record missing rather than the container pretending to have set it.
delegation_publish_caa() {
    local domain="$1" account_file account_uri
    account_file=$(get_letsencrypt_account_file) || return 1
    account_uri=$(jq -j '.uri' "$account_file")
    dnsman.py set_caa \
        --domain "$(delegated_name "$domain")" \
        --caa-tag "$(caa_tag_for "$domain")" \
        --caa-value "letsencrypt.org;validationmethods=dns-01;accounturi=$account_uri"
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
        --challenge-alias "$DELEGATION_ZONE" \
        --mode "${DNS_SETUP_MODE:-wait}" \
        --include "$include" \
        "$@"
}

# The accounturi CAA is what stops anyone else who can satisfy the delegated
# challenge from getting a certificate for this name, and we cannot write it, so
# a confirmed-absent record is fatal. ALLOW_MISSING_CAA downgrades it to a
# warning for operators who accept that risk.
delegation_verify_caa() {
    local domain="$1" account_file account_uri
    if ! account_file=$(get_letsencrypt_account_file); then
        echo "ERROR: cannot read the ACME account file to determine the required CAA" >&2
        return 1
    fi
    account_uri=$(jq -j '.uri' "$account_file")
    # Absent is the state to block on here, not "absent means unrestricted":
    # we cannot create this record, so nothing else protects the name.
    local gate=(--caa-required)
    if [ "${ALLOW_MISSING_CAA:-false}" = "true" ]; then
        gate=(--caa-required --caa-advisory)
    fi

    delegation_guide "$domain" caa \
        --caa-value "letsencrypt.org;validationmethods=dns-01;accounturi=$account_uri" \
        --account-uri "$account_uri" \
        "${gate[@]}"
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

# True until the first pass finishes. The first pass is setup and checks more
# than issuance strictly needs; later passes check only what would stop a
# renewal.
FIRST_PASS=true

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
    FIRST_PASS=false
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
