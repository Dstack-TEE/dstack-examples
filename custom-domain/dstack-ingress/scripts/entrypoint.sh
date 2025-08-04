#!/bin/bash
set -e

PORT=${PORT:-443}
TXT_PREFIX=${TXT_PREFIX:-"_tapp-address"}

setup_py_env() {
    if [ ! -d "/opt/app-venv" ]; then
        python3 -m venv --system-site-packages /opt/app-venv
    fi
    source /opt/app-venv/bin/activate
    pip install certbot-dns-cloudflare==4.0.0
}

setup_nginx_conf() {
    cat <<EOF > /etc/nginx/conf.d/default.conf
server {
    listen ${PORT} ssl http2;
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
    ssl_trusted_certificate /etc/letsencrypt/live/${DOMAIN}/chain.pem;
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
        proxy_pass ${TARGET_ENDPOINT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /evidences/ {
        alias /evidences/;
        autoindex on;
    }
}
EOF
    mkdir -p /var/log/nginx
}

obtain_certificate() {
    # Request certificate using the virtual environment
    certbot certonly --dns-cloudflare \
        --dns-cloudflare-credentials ~/.cloudflare/cloudflare.ini \
        --dns-cloudflare-propagation-seconds 120 \
        --email $CERTBOT_EMAIL \
        --agree-tos --no-eff-email --non-interactive \
        -d $DOMAIN
}

set_cname_record() {
    # Use the Python client to set the CNAME record
    # This will automatically check for and delete existing records
    cloudflare_dns.py set_cname \
        --zone-id "$CLOUDFLARE_ZONE_ID" \
        --domain "$DOMAIN" \
        --content "$GATEWAY_DOMAIN"
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to set CNAME record for $DOMAIN"
        exit 1
    fi
}

set_txt_record() {
    local APP_ID

    # Generate a unique app ID if not provided
    APP_ID=${APP_ID:-$(curl -s --unix-socket /var/run/tappd.sock http://localhost/prpc/Tappd.Info | jq -j '.app_id')}

    # Use the Python client to set the TXT record
    cloudflare_dns.py set_txt \
        --zone-id "$CLOUDFLARE_ZONE_ID" \
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
    cloudflare_dns.py set_caa \
        --zone-id "$CLOUDFLARE_ZONE_ID" \
        --domain "$DOMAIN" \
        --caa-tag "issue" \
        --caa-value "letsencrypt.org;validationmethods=dns-01;accounturi=$ACCOUNT_URI"
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to set CAA record for $DOMAIN"
        exit 1
    fi
}

bootstrap() {
    echo "Obtaining new certificate for $DOMAIN"
    setup_py_env
    obtain_certificate
    generate-evidences.sh
    set_cname_record
    set_txt_record
    set_caa_record
    touch /.bootstrapped
}

# Create Cloudflare credentials file
mkdir -p ~/.cloudflare
echo "dns_cloudflare_api_token = $CLOUDFLARE_API_TOKEN" > ~/.cloudflare/cloudflare.ini
chmod 600 ~/.cloudflare/cloudflare.ini

# Check if it's the first time the container is started
if [ ! -f "/.bootstrapped" ]; then
    bootstrap
else
    source /opt/app-venv/bin/activate
    echo "Certificate for $DOMAIN already exists"
fi

renewal-daemon.sh &

setup_nginx_conf

exec "$@"
