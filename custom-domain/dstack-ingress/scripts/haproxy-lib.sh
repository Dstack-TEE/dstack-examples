#!/bin/bash
# haproxy-lib.sh - the haproxy config pieces that are identical in every mode.
#
# The modes differ only in their frontends: dns-01 terminates TLS on the public
# port, tls-alpn-01 puts a ClientHello-peeking frontend there and moves the TLS
# frontend to loopback. global/defaults, the evidence ACL, the backends and the
# reload are the same either way, so they live here and each mode composes them.
# Nothing in this file branches on the mode; callers pass what differs.

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

# global + defaults. Always the first thing written to haproxy.cfg.
haproxy_emit_global() {
    cat <<EOF >/etc/haproxy/haproxy.cfg
global
    log stdout format raw local0
    maxconn ${MAXCONN}
    pidfile /var/run/haproxy/haproxy.pid
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305
    ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets
    ssl-default-bind-curves X25519MLKEM768:X25519:secp256r1:secp384r1

defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect ${TIMEOUT_CONNECT}
    timeout client  ${TIMEOUT_CLIENT}
    timeout server  ${TIMEOUT_SERVER}

EOF
}

# The TLS-terminating frontend. $1 is the bind spec -- the one part the modes
# disagree about.
haproxy_emit_tls_frontend() {
    local bind_spec="$1"
    # "crt <dir>" loads all PEM files from the directory.
    # ALPN is appended conditionally via ${ALPN:+ alpn ${ALPN}}.
    cat <<EOF >>/etc/haproxy/haproxy.cfg
frontend tls_in
    bind ${bind_spec} ssl crt /etc/haproxy/certs/${ALPN:+ alpn ${ALPN}}
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
haproxy_emit_evidence_backend() {
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
haproxy_emit_backends_single() {
    local target_hostport
    target_hostport=$(parse_target_endpoint "$TARGET_ENDPOINT")

    cat <<EOF >>/etc/haproxy/haproxy.cfg

    default_backend be_upstream

backend be_upstream
    server app1 ${target_hostport}
EOF
}

# Generate haproxy.cfg for multi-domain mode (ROUTING_MAP)
haproxy_emit_backends_multi() {
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
}

# Pick the backend layout from the environment, then append the evidence backend.
haproxy_emit_backends() {
    if [ -n "${ROUTING_MAP:-}" ]; then
        haproxy_emit_backends_multi
    elif [ -n "${DOMAIN:-}" ] && [ -n "${TARGET_ENDPOINT:-}" ]; then
        haproxy_emit_backends_single
    fi
    haproxy_emit_evidence_backend
}

haproxy_reload() {
    if [ ! -f /var/run/haproxy/haproxy.pid ]; then
        # Normal during a startup pass: haproxy has not been exec'd yet and will
        # read the fresh certificates when it starts.
        echo "HAProxy is not running yet; certificates will be picked up at start"
        return 0
    fi
    if kill -USR2 "$(cat /var/run/haproxy/haproxy.pid)"; then
        echo "HAProxy reloaded with the new certificates"
    else
        echo "HAProxy reload failed: SIGUSR2 to PID $(cat /var/run/haproxy/haproxy.pid) failed" >&2
        return 1
    fi
}
