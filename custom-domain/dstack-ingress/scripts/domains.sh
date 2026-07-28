#!/bin/bash
# domains.sh - what DNS records each domain needs, and how to make them exist.
#
# Sourced by both entrypoint.sh and cert-manager.sh so there is exactly one
# definition of "process this domain", whether it is the first pass at startup
# or the periodic renewal pass.

# This file is sourced by two independent processes (entrypoint.sh and
# cert-manager.sh), so it owns its own defaults rather than trusting the caller
# to have computed and exported them. Getting that wrong is quiet and nasty: an
# unset TXT_PREFIX builds a TXT name that can never exist, and the DNS wait then
# blocks forever on a record nobody could create.
#
# GATEWAY_DOMAIN, CERTBOT_EMAIL and SET_CAA are genuinely external (compose
# supplies them) and are deliberately not defaulted here.
PORT=${PORT:-443}
TXT_PREFIX=${TXT_PREFIX:-_dstack-app-address}
CHALLENGE_TYPE=${CHALLENGE_TYPE:-dns-01}
DNS_SETUP_MODE=${DNS_SETUP_MODE:-wait}
DNS_SETTLE_SECONDS=${DNS_SETTLE_SECONDS:-30}
SET_CAA=${SET_CAA:-false}
APP_ID=${APP_ID:-}

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

# Query the guest agent once for this app's identity.
load_dstack_identity() {
    local info
    if [[ -S /var/run/dstack.sock ]]; then
        info=$(curl -s --unix-socket /var/run/dstack.sock http://localhost/Info)
    else
        info=$(curl -s --unix-socket /var/run/tappd.sock http://localhost/prpc/Tappd.Info)
    fi

    DSTACK_APP_ID=$(echo "$info" | jq -j .app_id)
    DSTACK_INSTANCE_ID=$(echo "$info" | jq -j .instance_id)
    export DSTACK_APP_ID DSTACK_INSTANCE_ID

    if [ -z "$DSTACK_APP_ID" ] || [ "$DSTACK_APP_ID" = "null" ]; then
        echo "Error: could not read app_id from the dstack guest agent" >&2
        exit 1
    fi
    if [ "$CHALLENGE_TYPE" = "tls-alpn-01" ] &&
        { [ -z "$DSTACK_INSTANCE_ID" ] || [ "$DSTACK_INSTANCE_ID" = "null" ]; }; then
        echo "Error: could not read instance_id from the dstack guest agent, which" >&2
        echo "tls-alpn-01 needs to pin gateway routing to this instance" >&2
        exit 1
    fi
}

txt_record_name() {
    local domain="$1"
    if [[ "$domain" == \*.* ]]; then
        # Wildcard domain: *.myapp.com → _dstack-app-address-wildcard.myapp.com
        echo "${TXT_PREFIX}-wildcard.${domain#\*.}"
    else
        echo "${TXT_PREFIX}.${domain}"
    fi
}

# What the gateway should route this hostname to.
#
# dns-01 uses the app id, so the gateway load-balances across every instance of
# the app. tls-alpn-01 cannot: the challenge is answered by whichever instance
# certbot runs on, and routing by app id makes the gateway race connections
# across the app's instances (select_top_n_hosts -> connect_multiple_hosts)
# while the CA validates from several vantage points at once. The challenge
# would land on the wrong replica. Pinning to the instance id makes validation
# deterministic -- at the cost of sending all traffic to this one instance, so
# tls-alpn-01 mode is effectively single-instance.
txt_record_value() {
    if [ "$CHALLENGE_TYPE" = "tls-alpn-01" ]; then
        echo "${DSTACK_INSTANCE_ID}:${PORT}"
    else
        echo "${APP_ID:-$DSTACK_APP_ID}:${PORT}"
    fi
}

caa_tag_for() {
    if [[ "$1" == \*.* ]]; then echo "issuewild"; else echo "issue"; fi
}

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
        --caa-value "letsencrypt.org;validationmethods=${CHALLENGE_TYPE};accounturi=$ACCOUNT_URI"

    if [ $? -ne 0 ]; then
        echo "Warning: Failed to set CAA record for $domain"
        echo "This is not critical - certificates can still be issued without CAA records"
        echo "Consider disabling CAA records by setting SET_CAA=false if this continues to fail"
    fi
}

process_domain_dns01() {
    local domain="$1"

    set_alias_record "$domain"
    set_txt_record "$domain"
    renew-certificate.sh "$domain" || echo "First certificate renewal failed for $domain, will retry after set CAA record"
    set_caa_record "$domain"
    renew-certificate.sh "$domain"
}

process_domain_tlsalpn() {
    local domain="$1"

    if [[ "$domain" == \*.* ]]; then
        echo "Error: cannot issue a wildcard certificate for $domain with tls-alpn-01." >&2
        echo "RFC 8737 forbids it; use CHALLENGE_TYPE=dns-01 for wildcards." >&2
        exit 1
    fi

    # Register the ACME account first so the CAA record we print can already
    # pin accounturi. Without this the operator would have to add CAA in a
    # second pass, after the account exists.
    if ! legoman.py register --email "$CERTBOT_EMAIL"; then
        echo "Error: failed to register the ACME account" >&2
        exit 1
    fi

    local account_uri caa_value
    account_uri=$(legoman.py account-uri --email "$CERTBOT_EMAIL" 2>/dev/null || true)
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
    # Only on the first pass: the settle wait exists because the TXT value has
    # just changed, which is true at bootstrap (and after an instance
    # replacement, which is a fresh container and therefore also a first pass).
    # Renewal passes reuse a record the gateway resolved long ago.
    if [ ! -f /.bootstrapped ] && [ "${DNS_SETTLE_SECONDS}" -gt 0 ]; then
        echo "Waiting ${DNS_SETTLE_SECONDS}s for the gateway's DNS cache to expire"
        sleep "${DNS_SETTLE_SECONDS}"
    fi

    renew-certificate.sh "$domain"
}

process_domain() {
    local domain="$1"
    echo "Processing domain: $domain (challenge: $CHALLENGE_TYPE)"

    if [ "$CHALLENGE_TYPE" = "tls-alpn-01" ]; then
        process_domain_tlsalpn "$domain"
    else
        process_domain_dns01 "$domain"
    fi
}
