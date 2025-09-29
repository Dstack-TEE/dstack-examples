#!/bin/bash

set -e

PORT=${PORT:-443}
TXT_PREFIX=${TXT_PREFIX:-"_dstack-app-address"}
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
        pip install certbot requests
        touch /.venv_bootstrapped
    fi

    ln -sf /opt/app-venv/bin/certbot /usr/local/bin/certbot
    echo 'source /opt/app-venv/bin/activate' > /etc/profile.d/app-venv.sh
}

setup_certbot_env() {
    # Ensure the virtual environment is active for certbot configuration
    # shellcheck disable=SC1091
    source /opt/app-venv/bin/activate

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

    # Disable SSL renegotiation
    ssl_early_data off;

    location / {
        ${PROXY_CMD}_pass ${TARGET_ENDPOINT};
        ${PROXY_CMD}_set_header Host \$host;
        ${PROXY_CMD}_set_header X-Real-IP \$remote_addr;
        ${PROXY_CMD}_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        ${PROXY_CMD}_set_header X-Forwarded-Proto \$scheme;
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
    ACCOUNT_URI=$(jq -j '.uri' /etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory/*/regr.json)
    echo "Adding CAA record for $domain, accounturi=$ACCOUNT_URI"
    dnsman.py set_caa \
        --domain "$domain" \
        --caa-tag "issue" \
        --caa-value "letsencrypt.org;validationmethods=dns-01;accounturi=$ACCOUNT_URI"

    if [ $? -ne 0 ]; then
        echo "Warning: Failed to set CAA record for $domain"
        echo "This is not critical - certificates can still be issued without CAA records"
        echo "Consider disabling CAA records by setting SET_CAA=false if this continues to fail"
        # Don't exit - CAA records are optional for certificate generation
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
