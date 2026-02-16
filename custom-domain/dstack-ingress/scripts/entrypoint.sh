#!/bin/bash

set -e

source "/scripts/functions.sh"

PORT=${PORT:-443}
TXT_PREFIX=${TXT_PREFIX:-"_dstack-app-address"}

if ! PORT=$(sanitize_port "$PORT"); then
    exit 1
fi
if ! DOMAIN=$(sanitize_domain "$DOMAIN"); then
    exit 1
fi
if ! TARGET_ENDPOINT=$(sanitize_target_endpoint "$TARGET_ENDPOINT"); then
    exit 1
fi
if ! CLIENT_MAX_BODY_SIZE=$(sanitize_client_max_body_size "$CLIENT_MAX_BODY_SIZE"); then
    exit 1
fi
if ! PROXY_READ_TIMEOUT=$(sanitize_proxy_timeout "$PROXY_READ_TIMEOUT"); then
    exit 1
fi
if ! PROXY_SEND_TIMEOUT=$(sanitize_proxy_timeout "$PROXY_SEND_TIMEOUT"); then
    exit 1
fi
if ! PROXY_CONNECT_TIMEOUT=$(sanitize_proxy_timeout "$PROXY_CONNECT_TIMEOUT"); then
    exit 1
fi
if ! PROXY_BUFFER_SIZE=$(sanitize_proxy_buffer_size "$PROXY_BUFFER_SIZE"); then
    exit 1
fi
if ! PROXY_BUFFERS=$(sanitize_proxy_buffers "$PROXY_BUFFERS"); then
    exit 1
fi
if ! PROXY_BUSY_BUFFERS_SIZE=$(sanitize_proxy_buffer_size "$PROXY_BUSY_BUFFERS_SIZE"); then
    exit 1
fi
if ! TXT_PREFIX=$(sanitize_dns_label "$TXT_PREFIX"); then
    exit 1
fi

PROXY_CMD="proxy"
if [[ "${TARGET_ENDPOINT}" == grpc://* ]]; then
    PROXY_CMD="grpc"
fi

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

setup_nginx_conf() {
    local client_max_body_size_conf=""
    if [ -n "$CLIENT_MAX_BODY_SIZE" ]; then
        client_max_body_size_conf="    client_max_body_size ${CLIENT_MAX_BODY_SIZE};"
    fi

    local proxy_read_timeout_conf=""
    if [ -n "$PROXY_READ_TIMEOUT" ]; then
        proxy_read_timeout_conf="        ${PROXY_CMD}_read_timeout ${PROXY_READ_TIMEOUT};"
    fi

    local proxy_send_timeout_conf=""
    if [ -n "$PROXY_SEND_TIMEOUT" ]; then
        proxy_send_timeout_conf="        ${PROXY_CMD}_send_timeout ${PROXY_SEND_TIMEOUT};"
    fi

    local proxy_connect_timeout_conf=""
    if [ -n "$PROXY_CONNECT_TIMEOUT" ]; then
        proxy_connect_timeout_conf="        ${PROXY_CMD}_connect_timeout ${PROXY_CONNECT_TIMEOUT};"
    fi

    local proxy_buffer_size_conf=""
    if [ -n "$PROXY_BUFFER_SIZE" ]; then
        proxy_buffer_size_conf="    proxy_buffer_size ${PROXY_BUFFER_SIZE};"
    fi

    local proxy_buffers_conf=""
    if [ -n "$PROXY_BUFFERS" ]; then
        proxy_buffers_conf="    proxy_buffers ${PROXY_BUFFERS};"
    fi

    local proxy_busy_buffers_size_conf=""
    if [ -n "$PROXY_BUSY_BUFFERS_SIZE" ]; then
        proxy_busy_buffers_size_conf="    proxy_busy_buffers_size ${PROXY_BUSY_BUFFERS_SIZE};"
    fi

    cat <<EOF >/etc/nginx/conf.d/default.conf
server {
    listen ${PORT} ssl;
    http2 on;
    server_name ${DOMAIN};

    # SSL certificate configuration
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    # Modern SSL configuration - TLS 1.2 and 1.3 only
    ssl_protocols TLSv1.2 TLSv1.3;

    # Strong cipher suites - Only AES-GCM and ChaCha20-Poly1305
    ssl_ciphers 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';

    # Prefer server cipher suites
    ssl_prefer_server_ciphers on;

    # ECDH curve for ECDHE ciphers
    ssl_ecdh_curve secp384r1;

    # Enable OCSP stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;

    # SSL session configuration
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;

    # SSL buffer size (optimized for TLS 1.3)
    ssl_buffer_size 4k;
${proxy_buffer_size_conf}
${proxy_buffers_conf}
${proxy_busy_buffers_size_conf}

    # Disable SSL renegotiation
    ssl_early_data off;
${client_max_body_size_conf}

    location / {
        ${PROXY_CMD}_pass ${TARGET_ENDPOINT};
        ${PROXY_CMD}_set_header Host \$host;
        ${PROXY_CMD}_set_header X-Real-IP \$remote_addr;
        ${PROXY_CMD}_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        ${PROXY_CMD}_set_header X-Forwarded-Proto \$scheme;
${proxy_read_timeout_conf}
${proxy_send_timeout_conf}
${proxy_connect_timeout_conf}
    }

    location /evidences/ {
        alias /evidences/;
        autoindex on;
    }
}
EOF
}

set_alias_record() {
    local domain="$1"
    local cname_target="$GATEWAY_DOMAIN"

    # Namecheap DNS servers don't serve CNAME records pointing to underscore-prefixed domains.
    # The record appears in the Namecheap API but isn't visible in public DNS.
    # Workaround: use the full app-specific domain instead (resolves to the same IP).
    if [[ "$DNS_PROVIDER" == "namecheap" && "$cname_target" == _* ]]; then
        local app_id
        if [[ -S /var/run/dstack.sock ]]; then
            app_id=$(curl -s --unix-socket /var/run/dstack.sock http://localhost/Info | jq -j .app_id)
        else
            app_id=$(curl -s --unix-socket /var/run/tappd.sock http://localhost/prpc/Tappd.Info | jq -j .app_id)
        fi
        # Replace _.domain with appid-port.domain
        cname_target="${app_id}-${PORT}.${cname_target#_.}"
        echo "Namecheap workaround: using $cname_target instead of $GATEWAY_DOMAIN"
    fi

    echo "Setting alias record for $domain"
    dnsman.py set_alias \
        --domain "$domain" \
        --content "$cname_target"

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

    dnsman.py set_txt \
        --domain "${TXT_PREFIX}.${domain}" \
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

    ACCOUNT_URI=$(jq -j '.uri' "$account_file")
    echo "Adding CAA record for $domain, accounturi=$ACCOUNT_URI"
    dnsman.py set_caa \
        --domain "$domain" \
        --caa-tag "issue" \
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

renewal-daemon.sh &

mkdir -p /var/log/nginx

if [ -n "$DOMAIN" ] && [ -n "$TARGET_ENDPOINT" ]; then
    setup_nginx_conf
fi

exec "$@"
