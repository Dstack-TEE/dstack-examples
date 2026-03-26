#!/bin/bash

set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${THIS_DIR}/.." && pwd)"

# shellcheck source=../functions.sh
source "${SCRIPTS_DIR}/functions.sh"

failures=0

assert_equal() {
    local actual="$1"
    local expected="$2"
    local msg="$3"
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL: ${msg} (expected '${expected}', got '${actual}')" >&2
        failures=$((failures + 1))
    else
        echo "PASS: ${msg}"
    fi
}

assert_fails() {
    local msg="$1"
    shift
    local output_file
    output_file="$(mktemp)"
    if "$@" >"$output_file" 2>&1; then
        echo "FAIL: ${msg} (expected failure)" >&2
        cat "$output_file" >&2
        failures=$((failures + 1))
    else
        cat "$output_file"
        echo "PASS: ${msg}"
    fi
    rm -f "$output_file"
}

# Successful cases
assert_equal "$(sanitize_port 8080)" "8080" "sanitize_port accepts numeric port"
assert_equal "$(sanitize_domain example.com)" "example.com" "sanitize_domain accepts fqdn"
assert_equal "$(sanitize_domain '*.example.com')" "*.example.com" "sanitize_domain accepts wildcard"
assert_equal "$(sanitize_target_endpoint http://service:80/path)" "http://service:80/path" "sanitize_target_endpoint accepts http"
assert_equal "$(sanitize_target_endpoint grpc://svc:50051)" "grpc://svc:50051" "sanitize_target_endpoint accepts grpc"
assert_equal "$(sanitize_target_endpoint app:80)" "app:80" "sanitize_target_endpoint accepts bare host:port"
assert_equal "$(sanitize_target_endpoint app-main)" "app-main" "sanitize_target_endpoint accepts bare hostname"
assert_equal "$(sanitize_target_endpoint 10.0.0.1:8080)" "10.0.0.1:8080" "sanitize_target_endpoint accepts IP:port"
assert_equal "$(sanitize_client_max_body_size 50m)" "50m" "sanitize_client_max_body_size accepts suffix"
assert_equal "$(sanitize_dns_label test_label)" "test_label" "sanitize_dns_label accepts lowercase"
assert_equal "$(sanitize_dns_label test-label)" "test-label" "sanitize_dns_label accepts hyphen"
assert_equal "$(sanitize_proxy_timeout 30)" "30" "sanitize_proxy_timeout accepts numeric value"
assert_equal "$(sanitize_proxy_timeout 30s)" "30s" "sanitize_proxy_timeout accepts seconds suffix"
assert_equal "$(sanitize_proxy_timeout 5m)" "5m" "sanitize_proxy_timeout accepts minutes suffix"
assert_equal "$(sanitize_proxy_timeout 1h)" "1h" "sanitize_proxy_timeout accepts hours suffix"
assert_equal "$(sanitize_proxy_timeout '')" "" "sanitize_proxy_timeout accepts empty value"
assert_equal "$(sanitize_positive_integer 4096 MAXCONN)" "4096" "sanitize_positive_integer accepts 4096"
assert_equal "$(sanitize_positive_integer 1 MAXCONN)" "1" "sanitize_positive_integer accepts 1"
assert_equal "$(sanitize_haproxy_timeout 10s TIMEOUT_CONNECT)" "10s" "sanitize_haproxy_timeout accepts 10s"
assert_equal "$(sanitize_haproxy_timeout 86400s TIMEOUT_CLIENT)" "86400s" "sanitize_haproxy_timeout accepts 86400s"
assert_equal "$(sanitize_haproxy_timeout 5m TIMEOUT)" "5m" "sanitize_haproxy_timeout accepts 5m"
assert_equal "$(sanitize_haproxy_timeout 500ms TIMEOUT)" "500ms" "sanitize_haproxy_timeout accepts 500ms"
assert_equal "$(sanitize_haproxy_timeout 100us TIMEOUT)" "100us" "sanitize_haproxy_timeout accepts 100us"
assert_equal "$(sanitize_haproxy_timeout 1d TIMEOUT)" "1d" "sanitize_haproxy_timeout accepts 1d"
assert_equal "$(sanitize_alpn 'h2,http/1.1')" "h2,http/1.1" "sanitize_alpn accepts h2,http/1.1"
assert_equal "$(sanitize_alpn 'h2')" "h2" "sanitize_alpn accepts h2"
assert_equal "$(sanitize_alpn 'http/1.1')" "http/1.1" "sanitize_alpn accepts http/1.1"
assert_equal "$(sanitize_alpn '')" "" "sanitize_alpn accepts empty"

# Failing cases
assert_fails "sanitize_port rejects non-numeric" sanitize_port abc
assert_fails "sanitize_domain rejects invalid domain" sanitize_domain bad_domain
assert_fails "sanitize_target_endpoint rejects malformed URL" sanitize_target_endpoint "http:///broken"
warning_output="$(sanitize_client_max_body_size "50mb" 2>&1 || true)"
if [[ "$warning_output" == "Warning: Ignoring invalid CLIENT_MAX_BODY_SIZE value: 50mb" ]]; then
    echo "PASS: sanitize_client_max_body_size warns and returns empty"
else
    echo "FAIL: sanitize_client_max_body_size warning unexpected"
    printf '%s\n' "$warning_output"
    failures=$((failures + 1))
fi

# Test invalid timeout values
timeout_warning="$(sanitize_proxy_timeout "30ms" 2>&1 || true)"
if [[ "$timeout_warning" == "Warning: Ignoring invalid proxy timeout value: 30ms" ]]; then
    echo "PASS: sanitize_proxy_timeout warns on invalid suffix (ms)"
else
    echo "FAIL: sanitize_proxy_timeout warning unexpected"
    printf '%s\n' "$timeout_warning"
    failures=$((failures + 1))
fi

timeout_warning="$(sanitize_proxy_timeout "abc" 2>&1 || true)"
if [[ "$timeout_warning" == "Warning: Ignoring invalid proxy timeout value: abc" ]]; then
    echo "PASS: sanitize_proxy_timeout warns on non-numeric value"
else
    echo "FAIL: sanitize_proxy_timeout warning unexpected"
    printf '%s\n' "$timeout_warning"
    failures=$((failures + 1))
fi

assert_fails "sanitize_dns_label rejects invalid characters" sanitize_dns_label "bad*label"
assert_fails "sanitize_positive_integer rejects zero" sanitize_positive_integer 0 MAXCONN
assert_fails "sanitize_positive_integer rejects non-numeric" sanitize_positive_integer abc MAXCONN
assert_fails "sanitize_haproxy_timeout rejects bare text" sanitize_haproxy_timeout abc TIMEOUT
assert_fails "sanitize_haproxy_timeout rejects bare number" sanitize_haproxy_timeout 10 TIMEOUT
assert_fails "sanitize_alpn rejects semicolons" sanitize_alpn "h2;drop"
assert_fails "sanitize_alpn rejects newlines" sanitize_alpn $'h2\nhttp/1.1'
assert_fails "sanitize_alpn rejects spaces" sanitize_alpn "h2, http/1.1"

if [[ $failures -eq 0 ]]; then
    echo "All sanitizer tests passed"
else
    echo "$failures sanitizer tests failed" >&2
    exit 1
fi
