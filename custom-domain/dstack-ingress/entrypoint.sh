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
    listen ${PORT} ssl;
    server_name ${DOMAIN};
    
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    
    location / {
        proxy_pass ${TARGET_ENDPOINT};
    }

    location /evidences/ {
        alias /evidences/;
        autoindex on;
    }
}
EOF
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
    touch /etc/letsencrypt/bootstrapped
}

# Create Cloudflare credentials file
mkdir -p ~/.cloudflare
echo "dns_cloudflare_api_token = $CLOUDFLARE_API_TOKEN" > ~/.cloudflare/cloudflare.ini
chmod 600 ~/.cloudflare/cloudflare.ini

# Check if it's the first time the container is started
if [ ! -f "/etc/letsencrypt/bootstrapped" ]; then
    bootstrap
else
    source /opt/app-venv/bin/activate
    echo "Certificate for $DOMAIN already exists"
fi

renewal-daemon.sh &

setup_nginx_conf

exec "$@"
