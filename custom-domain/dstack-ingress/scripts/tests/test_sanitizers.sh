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
assert_equal "$(sanitize_client_max_body_size 50m)" "50m" "sanitize_client_max_body_size accepts suffix"
assert_equal "$(sanitize_dns_label test_label)" "test_label" "sanitize_dns_label accepts lowercase"
assert_equal "$(sanitize_dns_label test-label)" "test-label" "sanitize_dns_label accepts hyphen"

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
assert_fails "sanitize_dns_label rejects invalid characters" sanitize_dns_label "bad*label"

if [[ $failures -eq 0 ]]; then
    echo "All sanitizer tests passed"
else
    echo "$failures sanitizer tests failed" >&2
    exit 1
fi
