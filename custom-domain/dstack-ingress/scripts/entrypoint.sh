#!/bin/bash

set -e

PORT=${PORT:-443}
TXT_PREFIX=${TXT_PREFIX:-"_tapp-address"}

echo "Setting up Python environment"

setup_py_env() {
    if [ ! -d "/opt/app-venv" ]; then
        python3 -m venv --system-site-packages /opt/app-venv
    fi
    source /opt/app-venv/bin/activate

    pip install requests

    # Use the unified certbot manager to install plugins and setup credentials
    echo "Setting up certbot environment"
    certman.py setup
    if [ $? -ne 0 ]; then
        echo "Error: Failed to setup certbot environment"
        exit 1
    fi
}

PROXY_CMD="proxy"
if [[ "${TARGET_ENDPOINT}" == grpc://* ]]; then
    PROXY_CMD="grpc"
fi

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
    mkdir -p /var/log/nginx
}


set_alias_record() {
    # Use the unified DNS manager to set the alias record
    source /opt/app-venv/bin/activate
    echo "Setting alias record for $DOMAIN"
    dns_manager.py set_alias \
        --domain "$DOMAIN" \
        --content "$GATEWAY_DOMAIN"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to set alias record for $DOMAIN"
        exit 1
    fi
    echo "Alias record set for $DOMAIN"
}

set_txt_record() {
    local APP_ID

    # Generate a unique app ID if not provided
    if [[ -e /var/run/dstack.sock ]]; then
        DSTACK_APP_ID=$(curl -s --unix-socket /var/run/dstack.sock http://localhost/Info | jq -j .app_id)
        export DSTACK_APP_ID
    else
        DSTACK_APP_ID=$(curl -s --unix-socket /var/run/tappd.sock http://localhost/prpc/Tappd.Info | jq -j .app_id)
        export DSTACK_APP_ID
    fi
    APP_ID=${APP_ID:-"$DSTACK_APP_ID"}

    # Use the unified DNS manager to set the TXT record
    source /opt/app-venv/bin/activate
    dns_manager.py set_txt \
        --domain "${TXT_PREFIX}.${DOMAIN}" \
        --content "$APP_ID:$PORT"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to set TXT record for $DOMAIN"
        exit 1
    fi
}

set_caa_record() {
    if [ "$SET_CAA" != "true" ]; then
        echo "Skipping CAA record setup"
        return
    fi
    # Add CAA record for the domain
    local ACCOUNT_URI
    ACCOUNT_URI=$(jq -j '.uri' /evidences/acme-account.json)
    echo "Adding CAA record for $DOMAIN, accounturi=$ACCOUNT_URI"
    source /opt/app-venv/bin/activate
    dns_manager.py set_caa \
        --domain "$DOMAIN" \
        --caa-tag "issue" \
        --caa-value "letsencrypt.org;validationmethods=dns-01;accounturi=$ACCOUNT_URI"

    if [ $? -ne 0 ]; then
        echo "Warning: Failed to set CAA record for $DOMAIN"
        echo "This is not critical - certificates can still be issued without CAA records"
        echo "Consider disabling CAA records by setting SET_CAA=false if this continues to fail"
        # Don't exit - CAA records are optional for certificate generation
    fi
}

bootstrap() {
    echo "Bootstrap: Setting up $DOMAIN"
    source /opt/app-venv/bin/activate
    renew-certificate.sh -n
    set_alias_record
    set_txt_record
    set_caa_record
    touch /.bootstrapped
}

# Credentials are now handled by certman.py setup

# Setup Python environment and install dependencies first
setup_py_env

# Check if it's the first time the container is started
if [ ! -f "/.bootstrapped" ]; then
    bootstrap
else
    echo "Certificate for $DOMAIN already exists"
fi

renewal-daemon.sh &

setup_nginx_conf

exec "$@"
