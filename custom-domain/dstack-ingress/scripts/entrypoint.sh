#!/bin/bash

set -e

source "/scripts/functions.sh"
source "/scripts/domains.sh"

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

# cert-manager.sh, renew-certificate.sh and the ACME clients run as child
# processes and read these from the environment.
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

# Credentials are now handled by certman.py setup

# Setup certbot environment (venv is already created in Dockerfile)
setup_certbot_env
load_dstack_identity

if [ "$CHALLENGE_TYPE" = "tls-alpn-01" ]; then
    # Ordering is load-bearing. The tls-alpn-01 challenge arrives on the public
    # TLS port, so haproxy has to be forwarding acme-tls/1 before the first
    # certificate can exist. Start on a placeholder and let the certificate
    # manager converge behind it.
    ensure_placeholder_certs
else
    # dns-01 needs no inbound traffic, so keep the original order: certificate
    # first, serving second, and a failure here is fatal as it always was.
    cert-manager.sh --once
fi
build-combined-pems.sh || true

# Generate haproxy config
if [ -n "$ROUTING_MAP" ]; then
    setup_haproxy_cfg_multi
elif [ -n "$DOMAIN" ] && [ -n "$TARGET_ENDPOINT" ]; then
    setup_haproxy_cfg
fi

# Start evidence HTTP server if enabled
if [ "$EVIDENCE_SERVER" = "true" ]; then
    # Bind loopback explicitly, for two reasons.
    #
    # Correctness of the logs: left to itself mini_httpd binds [::]:port first,
    # and since the container has net.ipv6.bindv6only=0 that socket already
    # covers IPv4, so its second bind on 0.0.0.0:port fails with EADDRINUSE. It
    # logs "bind: Address already in use", keeps serving on the surviving
    # socket, and leaves a scary line in the log forever.
    #
    # Reach: the only consumer is haproxy's be_evidence backend, which connects
    # to 127.0.0.1:${EVIDENCE_PORT}. Listening on every interface additionally
    # exposed the evidence server to any other container on the compose
    # network at ingress:${EVIDENCE_PORT}, bypassing the proxy. Nothing
    # documented depends on that; evidence is meant to be read through
    # https://<domain>/evidences/ or the shared /evidences volume.
    mini_httpd -d /evidences -p "${EVIDENCE_PORT}" -h 127.0.0.1 -D -l /dev/stderr &
    echo "Evidence server started on 127.0.0.1:${EVIDENCE_PORT} (mini_httpd)"
fi

# One process owns certificates from here on: first pass (tls-alpn-01, where it
# has to run behind a live proxy) and every renewal after that.
cert-manager.sh &

exec "$@"
