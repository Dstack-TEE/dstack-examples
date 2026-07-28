#!/bin/bash

set -e

source "/scripts/functions.sh"

PORT=${PORT:-443}
TXT_PREFIX=${TXT_PREFIX:-"_dstack-app-address"}
MAXCONN=${MAXCONN:-4096}
TIMEOUT_CONNECT=${TIMEOUT_CONNECT:-10s}
TIMEOUT_CLIENT=${TIMEOUT_CLIENT:-86400s}
TIMEOUT_SERVER=${TIMEOUT_SERVER:-86400s}
EVIDENCE_SERVER=${EVIDENCE_SERVER:-true}
EVIDENCE_PORT=${EVIDENCE_PORT:-80}
ALPN=${ALPN:-}
CHALLENGE_TYPE=${CHALLENGE_TYPE:-dns-01}
# Loopback address/port lego's tls-alpn-01 responder binds to, and the loopback
# port the real TLS frontend moves to so the public port can be used for
# ALPN-based routing. Neither is reachable from outside the container.
TLSALPN_ADDRESS=${TLSALPN_ADDRESS:-127.0.0.1}
TLSALPN_PORT=${TLSALPN_PORT:-9443}
TLS_TERMINATE_PORT=${TLS_TERMINATE_PORT:-9444}
DNS_SETUP_MODE=${DNS_SETUP_MODE:-wait}

case "$CHALLENGE_TYPE" in
    dns-01|tls-alpn-01) ;;
    *)
        echo "Error: invalid CHALLENGE_TYPE '$CHALLENGE_TYPE' (expected dns-01 or tls-alpn-01)" >&2
        exit 1
        ;;
esac

case "$DNS_SETUP_MODE" in
    wait|print|webhook) ;;
    *)
        echo "Error: invalid DNS_SETUP_MODE '$DNS_SETUP_MODE' (expected wait, print or webhook)" >&2
        exit 1
        ;;
esac

if ! PORT=$(sanitize_port "$PORT"); then
    exit 1
fi
if ! TLSALPN_PORT=$(sanitize_port "$TLSALPN_PORT"); then
    exit 1
fi
if ! TLS_TERMINATE_PORT=$(sanitize_port "$TLS_TERMINATE_PORT"); then
    exit 1
fi
if ! DOMAIN=$(sanitize_domain "$DOMAIN"); then
    exit 1
fi
if ! TARGET_ENDPOINT=$(sanitize_target_endpoint "$TARGET_ENDPOINT"); then
    exit 1
fi
if ! TXT_PREFIX=$(sanitize_dns_label "$TXT_PREFIX"); then
    exit 1
fi
if ! MAXCONN=$(sanitize_positive_integer "$MAXCONN" "MAXCONN"); then
    exit 1
fi
if ! TIMEOUT_CONNECT=$(sanitize_haproxy_timeout "$TIMEOUT_CONNECT" "TIMEOUT_CONNECT"); then
    exit 1
fi
if ! TIMEOUT_CLIENT=$(sanitize_haproxy_timeout "$TIMEOUT_CLIENT" "TIMEOUT_CLIENT"); then
    exit 1
fi
if ! TIMEOUT_SERVER=$(sanitize_haproxy_timeout "$TIMEOUT_SERVER" "TIMEOUT_SERVER"); then
    exit 1
fi
if ! EVIDENCE_PORT=$(sanitize_positive_integer "$EVIDENCE_PORT" "EVIDENCE_PORT"); then
    exit 1
fi
if ! ALPN=$(sanitize_alpn "$ALPN"); then
    exit 1
fi

# renew-certificate.sh, renewal-daemon.sh and certman.py run as child processes
# and read these from the environment.
export CHALLENGE_TYPE TLSALPN_ADDRESS TLSALPN_PORT DNS_SETUP_MODE PORT

# Warn about deprecated L7 env vars
for var in CLIENT_MAX_BODY_SIZE PROXY_READ_TIMEOUT PROXY_SEND_TIMEOUT PROXY_CONNECT_TIMEOUT PROXY_BUFFER_SIZE PROXY_BUFFERS PROXY_BUSY_BUFFERS_SIZE; do
    if [ -n "${!var}" ]; then
        echo "Warning: $var is ignored in TCP proxy mode"
    fi
done

# Parse TARGET_ENDPOINT into host:port for haproxy backend
parse_target_endpoint() {
    local endpoint="$1"
    # Strip protocol prefix if present (http://, https://, grpc://)
    local hostport="${endpoint#*://}"
    # If no protocol was stripped, use as-is
    if [ "$hostport" = "$endpoint" ]; then
        hostport="$endpoint"
    fi
    # Strip any trailing path
    hostport="${hostport%%/*}"
    echo "$hostport"
}

echo "Setting up certbot environment"

setup_py_env() {
    if [ ! -d /opt/app-venv ]; then
        echo "Creating application virtual environment"
        python3 -m venv --system-site-packages /opt/app-venv
    fi

    # Activate venv for subsequent steps
    # shellcheck disable=SC1091
    source /opt/app-venv/bin/activate

    if [ ! -f /.venv_bootstrapped ]; then
        pip install --upgrade pip
        if [ "$CHALLENGE_TYPE" = "tls-alpn-01" ]; then
            # lego handles ACME here, so certbot and the cloud SDKs are dead
            # weight: skip them and keep startup and attack surface smaller.
            echo "Bootstrapping python dependencies (tls-alpn-01: no certbot)"
            pip install requests
        else
            echo "Bootstrapping certbot dependencies"
            pip install certbot requests boto3 botocore
        fi
        touch /.venv_bootstrapped
    fi

    [ -x /opt/app-venv/bin/certbot ] && ln -sf /opt/app-venv/bin/certbot /usr/local/bin/certbot
    echo 'source /opt/app-venv/bin/activate' > /etc/profile.d/app-venv.sh
}

setup_certbot_env() {
    # Ensure the virtual environment is active for certbot configuration
    # shellcheck disable=SC1091
    source /opt/app-venv/bin/activate

    if [ "$CHALLENGE_TYPE" = "tls-alpn-01" ]; then
        # No DNS provider and no certbot plugin: lego handles this path and is
        # baked into the image.
        if [ ! -x "${LEGO_BIN:-/usr/local/bin/lego}" ]; then
            echo "Error: lego binary not found at ${LEGO_BIN:-/usr/local/bin/lego}" >&2
            exit 1
        fi
        echo "Using lego for tls-alpn-01: $(${LEGO_BIN:-/usr/local/bin/lego} --version)"
        return
    fi

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

setup_py_env

# Emit common haproxy global/defaults/frontend preamble.
# Both single-domain and multi-domain modes share this identical config.
emit_haproxy_preamble() {
    # In tls-alpn-01 mode the ACME responder has to complete the TLS handshake
    # itself, but haproxy owns the public port. So the public port becomes a
    # plain TCP frontend that peeks at the ClientHello and forwards only
    # acme-tls/1 connections to lego; everything else goes to the real TLS
    # frontend, which moves to loopback. PROXY protocol carries the client
    # address across that extra hop so the backend still sees the real peer.
    local tls_bind=":${PORT}"
    if [ "$CHALLENGE_TYPE" = "tls-alpn-01" ]; then
        tls_bind="127.0.0.1:${TLS_TERMINATE_PORT} accept-proxy"
    fi

    # "crt <dir>" loads all PEM files from the directory.
    # ALPN is appended conditionally via ${ALPN:+ alpn ${ALPN}}.
    cat <<EOF >/etc/haproxy/haproxy.cfg
global
    log stdout format raw local0
    maxconn ${MAXCONN}
    pidfile /var/run/haproxy/haproxy.pid
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305
    ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets
    ssl-default-bind-curves secp384r1

defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect ${TIMEOUT_CONNECT}
    timeout client  ${TIMEOUT_CLIENT}
    timeout server  ${TIMEOUT_SERVER}

EOF

    if [ "$CHALLENGE_TYPE" = "tls-alpn-01" ]; then
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
    fi

    cat <<EOF >>/etc/haproxy/haproxy.cfg
frontend tls_in
    bind ${tls_bind} ssl crt /etc/haproxy/certs/${ALPN:+ alpn ${ALPN}}
EOF

    if [ "$EVIDENCE_SERVER" = "true" ]; then
        cat <<'EVIDENCE_BLOCK' >>/etc/haproxy/haproxy.cfg

    # Route /evidences requests to the local evidence HTTP server.
    # accept fires once 16 bytes have arrived — enough for the
    # longest prefix we match ("HEAD /evidences" = 16 chars).
    # Using req.len with a concrete threshold is critical: the
    # previous payload(0,0) (length 0 = "whole buffer") deferred
    # evaluation until the full inspect-delay because HAProxy
    # cannot know when a TCP stream ends.
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.len ge 16 }
    acl is_evidence payload(0,16) -m beg "GET /evidences"
    acl is_evidence payload(0,16) -m beg "HEAD /evidences"
    use_backend be_evidence if is_evidence
EVIDENCE_BLOCK
    fi
}

# Append the evidence backend block to haproxy.cfg
emit_evidence_backend() {
    if [ "$EVIDENCE_SERVER" = "true" ]; then
        cat <<EOF >>/etc/haproxy/haproxy.cfg

backend be_evidence
    mode http
    http-request replace-path /evidences(.*) \1
    server evidence 127.0.0.1:${EVIDENCE_PORT}
EOF
    fi
}

# Generate haproxy.cfg for single-domain mode (DOMAIN + TARGET_ENDPOINT)
setup_haproxy_cfg() {
    local target_hostport
    target_hostport=$(parse_target_endpoint "$TARGET_ENDPOINT")

    emit_haproxy_preamble

    cat <<EOF >>/etc/haproxy/haproxy.cfg

    default_backend be_upstream

backend be_upstream
    server app1 ${target_hostport}
EOF

    emit_evidence_backend
}

# Generate haproxy.cfg for multi-domain mode (ROUTING_MAP)
setup_haproxy_cfg_multi() {
    emit_haproxy_preamble

    # Parse ROUTING_MAP and generate use_backend rules + backend sections
    # Support both newline-separated and comma-separated formats
    local routing_map_normalized
    routing_map_normalized=$(echo "$ROUTING_MAP" | tr ',' '\n')

    local backend_rules=""
    local backend_sections=""
    local first_be_name=""
    local domain target be_name

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        [[ "$line" == \#* ]] && continue
        domain="${line%%=*}"
        target="${line#*=}"
        domain=$(echo "$domain" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        target=$(echo "$target" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -n "$domain" && -n "$target" ]] || continue

        # Validate domain and target to prevent config injection
        if ! domain=$(sanitize_domain "$domain"); then
            echo "Error: Invalid domain in ROUTING_MAP: ${line}" >&2
            exit 1
        fi
        if ! target=$(sanitize_target_endpoint "$target"); then
            echo "Error: Invalid target in ROUTING_MAP: ${line}" >&2
            exit 1
        fi

        # Strip protocol prefix from target if present
        target=$(parse_target_endpoint "$target")

        # Generate safe backend name from domain
        be_name="be_$(echo "$domain" | sed 's/[^A-Za-z0-9]/_/g')"

        if [ -z "$first_be_name" ]; then
            first_be_name="$be_name"
        fi

        backend_rules="${backend_rules}
    use_backend ${be_name} if { ssl_fc_sni -i ${domain} }"
        backend_sections="${backend_sections}

backend ${be_name}
    server s1 ${target}"
    done <<< "$routing_map_normalized"

    echo "$backend_rules" >> /etc/haproxy/haproxy.cfg

    # Default to first backend in ROUTING_MAP
    if [ -n "$first_be_name" ]; then
        echo "" >> /etc/haproxy/haproxy.cfg
        echo "    default_backend ${first_be_name}" >> /etc/haproxy/haproxy.cfg
    fi

    echo "$backend_sections" >> /etc/haproxy/haproxy.cfg

    emit_evidence_backend
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

    if [ -n "${ACME_CHALLENGE_ALIAS:-}" ]; then
        echo "[challenge-delegation] Set this in your production zone yourself (static, one-time):"
        echo "    ${txt_domain}  TXT  \"$APP_ID:$PORT\""
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

# caa_domain_and_tag DOMAIN -> prints "caa_domain caa_tag" (strips a wildcard).
caa_domain_and_tag() {
    local domain="$1"
    if [[ "$domain" == \*.* ]]; then
        echo "${domain#\*.} issuewild"
    else
        echo "$domain issue"
    fi
}

# In delegation mode we have NO token for the served domain's zone, so we cannot
# set the accounturi CAA ourselves. That CAA is the forge-prevention (only this
# enclave's ACME account may issue), so this path is deliberately NOT gated by
# SET_CAA and fails closed if the record is confirmed absent — otherwise anyone
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
    read -r caa_domain caa_tag < <(caa_domain_and_tag "$domain")
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

    local account_file account_uri caa_domain caa_tag
    if ! account_file=$(get_letsencrypt_account_file); then
        echo "Warning: Cannot set CAA record - account file not found"
        echo "This is not critical - certificates can still be issued without CAA records"
        return
    fi
    read -r caa_domain caa_tag < <(caa_domain_and_tag "$domain")
    account_uri=$(jq -j '.uri' "$account_file")

    echo "Adding CAA record ($caa_tag) for $caa_domain, accounturi=$account_uri"
    dnsman.py set_caa \
        --domain "$caa_domain" \
        --caa-tag "$caa_tag" \
        --caa-value "letsencrypt.org;validationmethods=${CHALLENGE_TYPE};accounturi=$account_uri"

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
    if [ "${DNS_SETTLE_SECONDS:-30}" -gt 0 ]; then
        echo "Waiting ${DNS_SETTLE_SECONDS:-30}s for the gateway's DNS cache to expire"
        sleep "${DNS_SETTLE_SECONDS:-30}"
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

bootstrap() {
    echo "Bootstrap: Setting up domains"

    local all_domains
    all_domains=$(get-all-domains.sh)

    if [ -z "$all_domains" ]; then
        echo "Error: No domains found. Set either DOMAIN or DOMAINS environment variable"
        exit 1
    fi

    echo "Found domains:"
    echo "$all_domains"

    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        process_domain "$domain"
    done <<<"$all_domains"

    # Generate evidences after all certificates are obtained
    echo "Generating evidence files for all domains..."
    generate-evidences.sh

    touch /.bootstrapped
}

# haproxy refuses to start when the crt directory has no PEM in it. In
# tls-alpn-01 mode the proxy has to be listening *before* the first certificate
# exists, because it is what forwards the ACME challenge to certbot, so seed a
# self-signed placeholder that the real certificate overwrites later.
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

# Obtain certificates once the proxy is already serving, then swap them in.
bootstrap_and_reload() {
    local attempt=0 delay
    while true; do
        attempt=$((attempt + 1))
        # Nested subshell so an `exit 1` from a process_domain helper is
        # reported as a failed condition here rather than silently killing
        # this background job.
        if ( bootstrap ); then
            build-combined-pems.sh || echo "Combined PEM build failed" >&2
            if [ -f /var/run/haproxy/haproxy.pid ]; then
                kill -USR2 "$(cat /var/run/haproxy/haproxy.pid)" &&
                    echo "Certificates installed and HAProxy reloaded"
            fi
            return 0
        fi

        # Falling through to the 12-hour renewal daemon would be a terrible
        # retry interval for a flow whose normal state is "waiting for the
        # operator to create a DNS record". Back off, but keep trying.
        delay=$((60 * attempt))
        [ "$delay" -gt 1800 ] && delay=1800
        echo "Bootstrap attempt ${attempt} failed; the proxy keeps serving the" >&2
        echo "placeholder certificate. Retrying in ${delay}s." >&2
        sleep "$delay"
    done
}

# Credentials are now handled by certman.py setup

# Setup certbot environment (venv is already created in Dockerfile)
setup_certbot_env
load_dstack_identity

if [ "$CHALLENGE_TYPE" = "tls-alpn-01" ]; then
    # Ordering is load-bearing here. The tls-alpn-01 challenge arrives on the
    # public TLS port, so haproxy must already be routing acme-tls/1 to certbot
    # before the first certificate can be issued. Start the proxy on a
    # placeholder certificate and let issuance converge behind it.
    ensure_placeholder_certs
    build-combined-pems.sh || true
else
    # dns-01 needs no inbound traffic, so keep the original order: get the
    # certificate first, start serving second.
    if [ ! -f "/.bootstrapped" ]; then
        bootstrap
    else
        echo "Certificate for $DOMAIN already exists"
        generate-evidences.sh
    fi
    build-combined-pems.sh
fi

# Generate haproxy config
if [ -n "$ROUTING_MAP" ]; then
    setup_haproxy_cfg_multi
elif [ -n "$DOMAIN" ] && [ -n "$TARGET_ENDPOINT" ]; then
    setup_haproxy_cfg
fi

# Start evidence HTTP server if enabled
if [ "$EVIDENCE_SERVER" = "true" ]; then
    mini_httpd -d /evidences -p "${EVIDENCE_PORT}" -D -l /dev/stderr &
    echo "Evidence server started on port ${EVIDENCE_PORT} (mini_httpd)"
fi

if [ "$CHALLENGE_TYPE" = "tls-alpn-01" ]; then
    if [ ! -f "/.bootstrapped" ]; then
        bootstrap_and_reload &
    else
        echo "Certificates already bootstrapped"
        generate-evidences.sh || echo "Evidence generation failed" >&2
    fi
fi

renewal-daemon.sh &

exec "$@"
