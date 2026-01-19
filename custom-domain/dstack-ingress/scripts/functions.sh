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
    if [[ "$candidate" =~ ^(grpc|https?)://[A-Za-z0-9._-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~:/?&=%-]*)?$ ]]; then
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
