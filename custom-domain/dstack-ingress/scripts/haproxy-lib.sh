#!/bin/bash
# haproxy-lib.sh - the haproxy config pieces that are identical in every mode.
#
# The modes differ only in their frontends: dns-01 terminates TLS on the public
# port, tls-alpn-01 puts a ClientHello-peeking frontend there and moves the TLS
# frontend to loopback. global/defaults, the evidence ACL, the backends and the
# reload are the same either way, so they live here and each mode composes them.
# Nothing in this file branches on the mode; callers pass what differs.

# Where the rendered configuration goes. Overridable so the generation logic
# can be exercised off-container (scripts/tests/test_observability_config.sh);
# production
# never sets this.
HAPROXY_CFG="${HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"

# entrypoint.sh pins this to TIMEOUT_CLIENT; default it here too so the emit
# functions stay callable without the entrypoint (as the tests call them).
TIMEOUT_TUNNEL="${TIMEOUT_TUNNEL:-${TIMEOUT_CLIENT:-}}"

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
    # Optional second log destination, off the box. Off by default on
    # purpose: the log carries client addresses, SNI and timing metadata,
    # and in the TEE threat model the host operator is not trusted with
    # tenant traffic metadata. SYSLOG_SERVER must point at a collector the
    # tenant controls (HAProxy speaks UDP syslog only; TLS needs a sidecar).
    local syslog_line=""
    if [ -n "${SYSLOG_SERVER:-}" ]; then
        syslog_line="
    log ${SYSLOG_SERVER} format rfc5424 local0"
    fi
    local logasap_line=""
    if [ "${LOG_ASAP:-false}" = "true" ]; then
        logasap_line="
    option  logasap"
    fi
    cat <<EOF >"$HAPROXY_CFG"
global
    log stdout format raw local0${syslog_line}
    log-tag dstack-ingress
    maxconn ${MAXCONN}
    pidfile /var/run/haproxy/haproxy.pid
    # Runtime API for incident response: show sess / show fd / show info
    # answer "is this flow still alive here, and how much is buffered" while
    # it is happening. The operator level covers every read-only command;
    # the admin-level commands (shutdown session, set server, clear table)
    # stay disabled. Unix socket, root-only, inside the container: access
    # equals whoever may exec into the container, i.e. the tenant. Never
    # volume-mount this out of the CVM.
    stats socket /var/run/haproxy/admin.sock mode 660 level operator
    stats timeout 30s
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305
    ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets
    ssl-default-bind-curves X25519MLKEM768:X25519:secp256r1:secp384r1

defaults
    log     global
    mode    tcp
    # Default tcplog fields plus a per-connection id and the TLS parameters,
    # so a terminated long-lived session can be matched to a domain and a
    # TLS stack after the fact. The custom log-format replaces option tcplog.
    # %ts is the two-character termination state; its first letter names
    # which side's timer or close ended the session (lowercase = a timeout:
    # c client, s server).
    unique-id-format %{+X}o\ %ci:%cp_%fi:%fp_%Ts_%rt:%pid
    log-format "%ci:%cp [%tr] %ft %b/%s %Tw/%Tc/%Tt %B %ts %ac/%fc/%bc/%sc/%rc %sq/%bq id=%ID sni=%[ssl_fc_sni] sslv=%sslv sslc=%sslc"${logasap_line}
    timeout connect ${TIMEOUT_CONNECT}
    timeout client  ${TIMEOUT_CLIENT}
    timeout server  ${TIMEOUT_SERVER}
    # Tunnels: in TCP mode a connection becomes a tunnel as soon as no
    # analyzer remains attached, and the tunnel timeout then supersedes the
    # client/server timeouts. Unset, the fallback is implicit; pinning it to
    # TIMEOUT_CLIENT keeps that behavior but makes the effective value
    # visible in the rendered config.
    timeout tunnel  ${TIMEOUT_TUNNEL}

EOF
}

# Optional Prometheus exporter, loopback only. The built-in service has no
# authentication: binding it beyond loopback would serve per-connection
# metadata to everything that can route to it, which on the dstack WireGuard
# network includes other tenants' CVMs. Scrape it from a tenant-controlled
# sidecar inside this CVM, or not at all. Scrapes are logged (httplog): an
# unlogged HTTP listener would draw a config warning on every reload, and a
# steady one-line-per-scrape trail doubles as proof the scrape path works.
haproxy_emit_metrics() {
    if [ -z "${METRICS_PORT:-}" ]; then
        return 0
    fi
    cat <<EOF >>"$HAPROXY_CFG"
frontend metrics_in
    bind 127.0.0.1:${METRICS_PORT}
    mode http
    option httplog
    option dontlognull
    http-request use-service prometheus-exporter
EOF
}

# PROXY protocol, opt-in at each end: accept it from the gateway on the public
# bind, send it (v2) to the app backends.
haproxy_accept_proxy() {
    if [ "${ACCEPT_PROXY_PROTOCOL:-false}" = "true" ]; then printf ' accept-proxy'; fi
}
haproxy_send_proxy() {
    if [ "${SEND_PROXY_PROTOCOL:-false}" = "true" ]; then printf ' send-proxy-v2'; fi
}

# The TLS-terminating frontend. $1 is the bind spec -- the one part the modes
# disagree about.
haproxy_emit_tls_frontend() {
    local bind_spec="$1"
    # "crt <dir>" loads all PEM files from the directory.
    # ALPN is appended conditionally via ${ALPN:+ alpn ${ALPN}}.
    cat <<EOF >>"$HAPROXY_CFG"
frontend tls_in
    bind ${bind_spec} ssl crt /etc/haproxy/certs/${ALPN:+ alpn ${ALPN}}
EOF

    if [ "$EVIDENCE_SERVER" = "true" ]; then
        cat <<'EVIDENCE_BLOCK' >>"$HAPROXY_CFG"

    # Route /evidences and /evidences/... to the local evidence HTTP
    # server. The byte after the path has to be checked too, or an app
    # path such as /evidences-report would be taken.
    # accept fires once 16 bytes have arrived — enough for the
    # longest prefix we match ("HEAD /evidences/" = 16 chars).
    # Using req.len with a concrete threshold is critical: the
    # previous payload(0,0) (length 0 = "whole buffer") deferred
    # evaluation until the full inspect-delay because HAProxy
    # cannot know when a TCP stream ends. A first byte that cannot
    # start either request is accepted at once, so short messages
    # of other protocols are not held for the full delay; that rule
    # comes first because a rule still waiting for data stops the
    # evaluation of the ones after it.
    tcp-request inspect-delay 5s
    tcp-request content accept if !{ req.payload(0,1) -m str G H }
    tcp-request content accept if { req.len ge 16 }
    acl is_evidence payload(0,16) -m beg "GET /evidences/" "GET /evidences " "GET /evidences?"
    acl is_evidence payload(0,16) -m beg "HEAD /evidences/" "HEAD /evidences " "HEAD /evidences?"
    use_backend be_evidence if is_evidence
EVIDENCE_BLOCK
    fi
}

# Append the evidence backend block to haproxy.cfg
haproxy_emit_evidence_backend() {
    if [ "$EVIDENCE_SERVER" = "true" ]; then
        cat <<EOF >>"$HAPROXY_CFG"

backend be_evidence
    mode http
    http-request replace-path ^/evidences/?(.*) /\1
    server evidence 127.0.0.1:${EVIDENCE_PORT}
EOF
    fi
}

# Generate haproxy.cfg for single-domain mode (DOMAIN + TARGET_ENDPOINT)
haproxy_emit_backends_single() {
    local target_hostport
    target_hostport=$(parse_target_endpoint "$TARGET_ENDPOINT")

    cat <<EOF >>"$HAPROXY_CFG"

    default_backend be_upstream

backend be_upstream
    server app1 ${target_hostport}$(haproxy_send_proxy)
EOF
}

# Generate haproxy.cfg for multi-domain mode (ROUTING_MAP)
haproxy_emit_backends_multi() {
    local routing_map_normalized
    routing_map_normalized=$(routing_map_entries) || exit 1

    local exact_rules=""
    local wildcard_rules=""
    local backend_sections=""
    local first_be_name=""
    local domain target be_name suffix
    local index=0

    while read -r domain target; do

        # Generate safe backend name from domain; the index keeps names
        # unique when two domains map to the same one (a-b.x vs a.b.x)
        index=$((index + 1))
        be_name="be_${index}_${domain//[^A-Za-z0-9]/_}"

        if [ -z "$first_be_name" ]; then
            first_be_name="$be_name"
        fi

        # A wildcard covers exactly one label, like its certificate. Exact
        # names are matched first, so they win over a wildcard covering them.
        if [[ "$domain" == \*.* ]]; then
            suffix="${domain#\*.}"
            wildcard_rules="${wildcard_rules}
    use_backend ${be_name} if { ssl_fc_sni -i -m reg '^[^.]+[.]${suffix//./[.]}\$' }"
        else
            exact_rules="${exact_rules}
    use_backend ${be_name} if { ssl_fc_sni -i ${domain} }"
        fi
        backend_sections="${backend_sections}

backend ${be_name}
    server s1 ${target}$(haproxy_send_proxy)"
    done <<< "$routing_map_normalized"

    echo "${exact_rules}${wildcard_rules}" >> "$HAPROXY_CFG"

    # Default to first backend in ROUTING_MAP
    if [ -n "$first_be_name" ]; then
        echo "" >> "$HAPROXY_CFG"
        echo "    default_backend ${first_be_name}" >> "$HAPROXY_CFG"
    fi

    echo "$backend_sections" >> "$HAPROXY_CFG"
}

# Parse and validate ROUTING_MAP (newline- or comma-separated domain=target
# entries; comment lines are dropped before splitting on commas) into
# "domain host:port" lines. Fails on an invalid or duplicate entry or an empty
# map, so entrypoint.sh can reject a bad map before any ACME work.
routing_map_entries() {
    local line domain target
    local -A seen=()
    while IFS= read -r line; do
        read -r domain target <<< "${line/=/ }"
        [[ -n "$domain" && "$domain" != \#* ]] || continue
        if [[ "$line" != *=* || -z "$target" ]]; then
            echo "Error: ROUTING_MAP entry is not domain=target: ${line}" >&2
            return 1
        fi

        # Validate domain and target to prevent config injection
        if ! domain=$(sanitize_domain "$domain"); then
            echo "Error: Invalid domain in ROUTING_MAP: ${line}" >&2
            return 1
        fi
        if ! target=$(sanitize_target_endpoint "$target"); then
            echo "Error: Invalid target in ROUTING_MAP: ${line}" >&2
            return 1
        fi
        if [[ -n "${seen[${domain,,}]:-}" ]]; then
            echo "Error: Duplicate domain in ROUTING_MAP: ${domain}" >&2
            return 1
        fi
        seen[${domain,,}]=1

        # Strip protocol prefix from target if present
        echo "${domain} $(parse_target_endpoint "$target")"
    done <<< "$(echo "$ROUTING_MAP" | tr -d '\r' | sed '/^[[:space:]]*#/d' | tr ',' '\n')"
    if [[ ${#seen[@]} -eq 0 ]]; then
        echo "Error: ROUTING_MAP has no entries" >&2
        return 1
    fi
}

# Pick the backend layout from the environment, then append the evidence backend.
haproxy_emit_backends() {
    if [ -n "${ROUTING_MAP:-}" ]; then
        haproxy_emit_backends_multi
    elif [ -n "${TARGET_ENDPOINT:-}" ]; then
        haproxy_emit_backends_single
    fi
    haproxy_emit_evidence_backend
    haproxy_emit_metrics
}

haproxy_reload() {
    local pid
    pid=$(cat /var/run/haproxy/haproxy.pid 2>/dev/null) || pid=
    # Checked by name: a pidfile left by a previous run can name a PID that now
    # belongs to the startup script, which haproxy is about to replace.
    if [ -z "$pid" ] || [ "$(cat "/proc/$pid/comm" 2>/dev/null)" != haproxy ]; then
        # Normal during a startup pass: haproxy has not been exec'd yet and will
        # read the fresh certificates when it starts.
        echo "HAProxy is not running yet; certificates will be picked up at start"
        return 0
    fi
    if kill -USR2 "$pid"; then
        echo "HAProxy reloaded with the new certificates"
    else
        echo "HAProxy reload failed: SIGUSR2 to PID $pid failed" >&2
        return 1
    fi
}
