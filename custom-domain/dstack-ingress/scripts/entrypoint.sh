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

if ! PORT=$(sanitize_port "$PORT"); then
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

setup_py_env

# Emit common haproxy global/defaults/frontend preamble.
# Both single-domain and multi-domain modes share this identical config.
emit_haproxy_preamble() {
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

frontend tls_in
    bind :${PORT} ssl crt /etc/haproxy/certs/${ALPN:+ alpn ${ALPN}}
EOF

    if [ "$EVIDENCE_SERVER" = "true" ]; then
        cat <<'EVIDENCE_BLOCK' >>/etc/haproxy/haproxy.cfg

    # Route /evidences requests to local evidence HTTP server
    tcp-request inspect-delay 5s
    tcp-request content accept if WAIT_END
    acl is_evidence payload(0,0) -m beg "GET /evidences"
    acl is_evidence payload(0,0) -m beg "HEAD /evidences"
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

set_txt_record() {
    local domain="$1"
    local APP_ID

    if [[ -S /var/run/dstack.sock ]]; then
        DSTACK_APP_ID=$(curl -s --unix-socket /var/run/dstack.sock http://localhost/Info | jq -j .app_id)
        export DSTACK_APP_ID
    else
        DSTACK_APP_ID=$(curl -s --unix-socket /var/run/tappd.sock http://localhost/prpc/Tappd.Info | jq -j .app_id)
        export DSTACK_APP_ID
    fi
    APP_ID=${APP_ID:-"$DSTACK_APP_ID"}

    local txt_domain
    if [[ "$domain" == \*.* ]]; then
        # Wildcard domain: *.myapp.com → _dstack-app-address-wildcard.myapp.com
        txt_domain="${TXT_PREFIX}-wildcard.${domain#\*.}"
    else
        txt_domain="${TXT_PREFIX}.${domain}"
    fi

    dnsman.py set_txt \
        --domain "$txt_domain" \
        --content "$APP_ID:$PORT"

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
    if [[ "$domain" == \*.* ]]; then
        caa_domain="${domain#\*.}"
        caa_tag="issuewild"
    else
        caa_domain="$domain"
        caa_tag="issue"
    fi

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
    local domain="$1"
    echo "Processing domain: $domain"

    set_alias_record "$domain"
    set_txt_record "$domain"
    renew-certificate.sh "$domain" || echo "First certificate renewal failed for $domain, will retry after set CAA record"
    set_caa_record "$domain"
    renew-certificate.sh "$domain"
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

# Credentials are now handled by certman.py setup

# Setup certbot environment (venv is already created in Dockerfile)
setup_certbot_env

# Check if it's the first time the container is started
if [ ! -f "/.bootstrapped" ]; then
    bootstrap
else
    echo "Certificate for $DOMAIN already exists"
    generate-evidences.sh
fi

# Build combined PEM files for haproxy
build-combined-pems.sh

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

renewal-daemon.sh &

exec "$@"
