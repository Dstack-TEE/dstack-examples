#!/bin/bash

# Verify the observability surface of the generated haproxy.cfg: the
# operator-level runtime API socket, the extended traffic log format (SNI,
# TLS parameters, per-connection id, termination state), the explicit tunnel
# timeout, and the opt-in syslog copy / metrics frontend / logasap.
#
# Unlike the docker-based tests this one runs anywhere with bash and a
# haproxy binary: the emit functions take the config path from HAPROXY_CFG
# and validation is `haproxy -c`, no container needed.
#
# Usage: ./scripts/tests/test_observability_config.sh

set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${THIS_DIR}/.." && pwd)"

# shellcheck source=../functions.sh
source "${SCRIPTS_DIR}/functions.sh"
# shellcheck source=../haproxy-lib.sh
source "${SCRIPTS_DIR}/haproxy-lib.sh"

failures=0

check() {
    local msg="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS: ${msg}"
    else
        echo "FAIL: ${msg} (expected '${expected}', got '${actual}')" >&2
        failures=$((failures + 1))
    fi
}

check_absent() {
    local msg="$1" pattern="$2" file="$3"
    if grep -q "$pattern" "$file"; then
        echo "FAIL: ${msg} (unexpected match: ${pattern})" >&2
        failures=$((failures + 1))
    else
        echo "PASS: ${msg}"
    fi
}

check_present() {
    local msg="$1" pattern="$2" file="$3"
    if grep -q "$pattern" "$file"; then
        echo "PASS: ${msg}"
    else
        echo "FAIL: ${msg} (missing: ${pattern})" >&2
        failures=$((failures + 1))
    fi
}

check_valid() {
    local msg="$1" file="$2"
    local out
    if out=$(haproxy -c -f "$file" 2>&1); then
        echo "PASS: ${msg}"
    else
        echo "FAIL: ${msg}" >&2
        echo "$out" >&2
        failures=$((failures + 1))
    fi
}

generate() {
    local cfg="$1"
    HAPROXY_CFG="$cfg" \
    MAXCONN=16 TIMEOUT_CONNECT=5s TIMEOUT_CLIENT=30s TIMEOUT_SERVER=30s \
    EVIDENCE_SERVER=false DOMAIN=localhost TARGET_ENDPOINT=127.0.0.1:25080 \
    bash -c '
        set -euo pipefail
        source "'"${SCRIPTS_DIR}"'/functions.sh"
        source "'"${SCRIPTS_DIR}"'/haproxy-lib.sh"
        haproxy_emit_global
        haproxy_emit_tls_frontend "127.0.0.1:24443"
        haproxy_emit_backends
    '
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# The TLS frontend hard-codes the production cert directory; give haproxy -c
# a real one and point the generated config at it.
mkdir -p "$workdir/certs"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$workdir/key.pem" -out "$workdir/cert.pem" \
    -subj /CN=localhost -days 1 >/dev/null 2>&1
cat "$workdir/key.pem" "$workdir/cert.pem" > "$workdir/certs/test.pem"

# shellcheck disable=SC2317 # Invoked as finalize <cfg> below.
finalize() {
    sed -i '' "s|/etc/haproxy/certs/|$workdir/certs|" "$1"
}

# --- default: every visibility feature with no opt-ins ---
default_cfg="$workdir/default.cfg"
SYSLOG_SERVER='' METRICS_PORT='' LOG_ASAP=false generate "$default_cfg"
finalize "$default_cfg"

check_present "runtime API socket is present" 'stats socket /var/run/haproxy/admin.sock' "$default_cfg"
check_present "runtime API is operator level" 'level operator' "$default_cfg"
check_absent "runtime API never gets admin level" 'level admin' "$default_cfg"
check_present "log lines carry the dstack-ingress tag" 'log-tag dstack-ingress' "$default_cfg"
check_present "log format records SNI" 'ssl_fc_sni' "$default_cfg"
check_present "log format records the TLS version" 'sslv=%sslv' "$default_cfg"
check_present "log format records the termination state" '%ts' "$default_cfg"
check_present "log format records a per-connection id" 'unique-id-format' "$default_cfg"
check "tunnel timeout follows TIMEOUT_CLIENT by default" "1" "$(grep -cE 'timeout tunnel +30s' "$default_cfg")"
check_absent "no syslog target by default" 'log 192\.0\.2\.' "$default_cfg"
check_absent "no metrics frontend by default" 'metrics_in' "$default_cfg"
check_absent "no logasap by default" 'logasap' "$default_cfg"
check_valid "default config passes haproxy -c" "$default_cfg"

# --- opt-ins: syslog copy, metrics frontend, logasap ---
optin_cfg="$workdir/optin.cfg"
SYSLOG_SERVER=192.0.2.7:514 METRICS_PORT=8405 LOG_ASAP=true generate "$optin_cfg"
finalize "$optin_cfg"

check_present "syslog target emitted" 'log 192.0.2.7:514 format rfc5424 local0' "$optin_cfg"
check "exactly one off-box log target" "1" "$(grep -cE '^    log [0-9[]' "$optin_cfg")"
check_present "metrics frontend binds loopback only" 'bind 127.0.0.1:8405' "$optin_cfg"
check_absent "metrics never binds a routable address" 'bind 0.0.0.0' "$optin_cfg"
check_present "metrics frontend uses the prometheus service" 'use-service prometheus-exporter' "$optin_cfg"
check_present "metrics scrapes log in HTTP format" 'option httplog' "$optin_cfg"
check_present "logasap emitted when opted in" 'option  logasap' "$optin_cfg"
check_valid "opt-in config passes haproxy -c" "$optin_cfg"

# --- sanitizers ---
check "sanitize_syslog_server accepts host:port" "logs.example.com:514" "$(sanitize_syslog_server logs.example.com:514)"
check "sanitize_syslog_server accepts IPv4:port" "192.0.2.7:514" "$(sanitize_syslog_server 192.0.2.7:514)"
check "sanitize_syslog_server accepts bracketed IPv6" "[::1]:514" "$(sanitize_syslog_server '[::1]:514')"
if sanitize_syslog_server "192.0.2.7" >/dev/null 2>&1; then
    echo "FAIL: sanitize_syslog_server rejects a missing port" >&2
    failures=$((failures + 1))
else
    echo "PASS: sanitize_syslog_server rejects a missing port"
fi
if sanitize_syslog_server 'evil" --inject:514' >/dev/null 2>&1; then
    echo "FAIL: sanitize_syslog_server rejects config-injection characters" >&2
    failures=$((failures + 1))
else
    echo "PASS: sanitize_syslog_server rejects config-injection characters"
fi
if sanitize_haproxy_timeout 300 TIMEOUT_TUNNEL >/dev/null 2>&1; then
    echo "FAIL: sanitize_haproxy_timeout accepts a bare number for TIMEOUT_TUNNEL" >&2
    failures=$((failures + 1))
else
    echo "PASS: sanitize_haproxy_timeout rejects a bare number for TIMEOUT_TUNNEL"
fi

if [[ $failures -eq 0 ]]; then
    echo "All observability config tests passed"
else
    echo "$failures observability config tests failed" >&2
    exit 1
fi
