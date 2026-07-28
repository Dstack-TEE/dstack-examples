#!/bin/bash

# Sanitizer helpers shared across scripts. Each function echoes the sanitized
# value on success; on failure it writes an error to stderr and returns non-zero.

sanitize_port() {
    local candidate="$1"
    if [[ "$candidate" =~ ^[0-9]+$ ]] && (( candidate >= 1 && candidate <= 65535 )); then
        echo "$candidate"
    else
        echo "Error: Invalid PORT value: $candidate" >&2
        return 1
    fi
}

sanitize_domain() {
    local candidate="$1"
    if [ -z "$candidate" ]; then
        echo ""
        return 0
    fi
    if [[ "$candidate" =~ ^(\*\.)?[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]; then
        echo "$candidate"
    else
        echo "Error: Invalid DOMAIN value: $candidate" >&2
        return 1
    fi
}

sanitize_target_endpoint() {
    local candidate="$1"
    if [ -z "$candidate" ]; then
        echo ""
        return 0
    fi
    # Accept protocol://host:port/path or bare host:port
    if [[ "$candidate" =~ ^(grpc|https?)://[A-Za-z0-9._-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~:/?&=%-]*)?$ ]] ||
       [[ "$candidate" =~ ^[A-Za-z0-9._-]+(:[0-9]{1,5})?$ ]]; then
        echo "$candidate"
    else
        echo "Error: Invalid TARGET_ENDPOINT value: $candidate" >&2
        return 1
    fi
}

sanitize_client_max_body_size() {
    local candidate="$1"
    if [ -z "$candidate" ]; then
        echo ""
        return 0
    fi
    if [[ "$candidate" =~ ^[0-9]+[kKmMgG]?$ ]]; then
        echo "$candidate"
    else
        echo "Warning: Ignoring invalid CLIENT_MAX_BODY_SIZE value: $candidate" >&2
        echo ""
    fi
}

sanitize_dns_label() {
    local candidate="$1"
    if [ -z "$candidate" ]; then
        echo "Error: TXT_PREFIX cannot be empty" >&2
        return 1
    fi
    if [[ "$candidate" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "$candidate"
    else
        echo "Error: Invalid TXT_PREFIX value: $candidate" >&2
        return 1
    fi
}

sanitize_positive_integer() {
    local candidate="$1"
    local name="${2:-value}"
    if [[ "$candidate" =~ ^[0-9]+$ ]] && (( candidate >= 1 )); then
        echo "$candidate"
    else
        echo "Error: Invalid ${name}: $candidate (must be a positive integer)" >&2
        return 1
    fi
}

sanitize_haproxy_timeout() {
    local candidate="$1"
    local name="${2:-timeout}"
    # Require a time suffix — bare numbers are milliseconds in HAProxy,
    # which is almost never what users intend.
    if [[ "$candidate" =~ ^[0-9]+(us|ms|s|m|h|d)$ ]]; then
        echo "$candidate"
    else
        echo "Error: Invalid ${name}: $candidate (must include suffix, e.g. 10s, 5m, 86400s)" >&2
        return 1
    fi
}

sanitize_alpn() {
    local candidate="$1"
    if [ -z "$candidate" ]; then
        echo ""
        return 0
    fi
    # ALPN value is comma-separated protocol names (e.g. "h2,http/1.1")
    # Only allow alphanumeric, dots, slashes, hyphens, and commas.
    if [[ "$candidate" =~ ^[A-Za-z0-9./-]+(,[A-Za-z0-9./-]+)*$ ]]; then
        echo "$candidate"
    else
        echo "Error: Invalid ALPN value: $candidate (e.g. h2,http/1.1)" >&2
        return 1
    fi
}

sanitize_proxy_timeout() {
    local candidate="$1"
    if [ -z "$candidate" ]; then
        echo ""
        return 0
    fi
    if [[ "$candidate" =~ ^[0-9]+[smh]?$ ]]; then
        echo "$candidate"
    else
        echo "Warning: Ignoring invalid proxy timeout value: $candidate" >&2
        echo ""
    fi
}

sanitize_proxy_buffer_size() {
    local candidate="$1"
    if [ -z "$candidate" ]; then
        echo ""
        return 0
    fi
    if [[ "$candidate" =~ ^[0-9]+[kKmM]?$ ]]; then
        echo "$candidate"
    else
        echo "Warning: Ignoring invalid proxy buffer size value: $candidate" >&2
        echo ""
    fi
}

sanitize_proxy_buffers() {
    local candidate="$1"
    if [ -z "$candidate" ]; then
        echo ""
        return 0
    fi
    # Format: number size (e.g., "4 256k")
    if [[ "$candidate" =~ ^[0-9]+[[:space:]]+[0-9]+[kKmM]?$ ]]; then
        echo "$candidate"
    else
        echo "Warning: Ignoring invalid proxy buffers value: $candidate (expected format: 'number size', e.g., '4 256k')" >&2
        echo ""
    fi
}

# Get the certbot certificate directory name for a domain.
# Certbot stores wildcard certs without the "*." prefix:
#   *.example.com → /etc/letsencrypt/live/example.com/
cert_dir_name() {
    local domain="$1"
    echo "${domain#\*.}"
}

get_letsencrypt_account_path() {
    local base_path="/etc/letsencrypt/accounts"
    local api_endpoint="acme-v02.api.letsencrypt.org"

    if [[ "$CERTBOT_STAGING" == "true" ]]; then
        api_endpoint="acme-staging-v02.api.letsencrypt.org"
    fi

    echo "${base_path}/${api_endpoint}/directory/*/regr.json"
}

get_letsencrypt_account_file() {
    local account_pattern
    account_pattern=$(get_letsencrypt_account_path)

    local account_files
    account_files=( $account_pattern )

    if [[ ! -f "${account_files[0]}" ]]; then
        echo "Error: Let's Encrypt account file not found at $account_pattern" >&2
        return 1
    fi

    echo "${account_files[0]}"
}

# --- ACME client layout ------------------------------------------------------
#
# The two challenge types use different clients, and they lay their state out
# differently:
#
#   certbot (dns-01)     /etc/letsencrypt/live/<domain>/{fullchain,privkey}.pem
#                        /etc/letsencrypt/accounts/<server>/directory/*/regr.json
#   lego    (tls-alpn-01) $LEGO_PATH/certificates/<domain>.{crt,key}
#                        $LEGO_PATH/accounts/<server>/<email>/account.json
#
# Everything downstream (combined PEMs, evidence) goes through these helpers so
# it does not have to care which client produced the files.

lego_path() {
    echo "${LEGO_PATH:-/etc/letsencrypt/lego}"
}

using_lego() {
    [[ "${CHALLENGE_TYPE:-dns-01}" == "tls-alpn-01" ]]
}

# lego writes the full chain into the .crt file.
cert_fullchain_path() {
    local domain="$1"
    if using_lego; then
        echo "$(lego_path)/certificates/${domain}.crt"
    else
        echo "/etc/letsencrypt/live/$(cert_dir_name "$domain")/fullchain.pem"
    fi
}

cert_privkey_path() {
    local domain="$1"
    if using_lego; then
        echo "$(lego_path)/certificates/${domain}.key"
    else
        echo "/etc/letsencrypt/live/$(cert_dir_name "$domain")/privkey.pem"
    fi
}

get_lego_account_file() {
    local pattern account_files
    pattern="$(lego_path)/accounts/*/*/account.json"
    account_files=( $pattern )

    if [[ ! -f "${account_files[0]}" ]]; then
        echo "Error: lego account file not found at $pattern" >&2
        return 1
    fi

    echo "${account_files[0]}"
}

# Account registration document, whichever client produced it.
acme_account_file() {
    if using_lego; then
        get_lego_account_file
    else
        get_letsencrypt_account_file
    fi
}
