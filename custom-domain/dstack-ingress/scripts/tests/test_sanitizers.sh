#!/bin/bash

set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${THIS_DIR}/.." && pwd)"

# shellcheck source=../functions.sh
source "${SCRIPTS_DIR}/functions.sh"
# shellcheck source=../haproxy-lib.sh
source "${SCRIPTS_DIR}/haproxy-lib.sh"

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
assert_equal "$(sanitize_host 127.0.0.1 ADDR)" "127.0.0.1" "sanitize_host accepts IPv4"
assert_equal "$(sanitize_host localhost ADDR)" "localhost" "sanitize_host accepts hostname"
assert_equal "$(sanitize_host '[::1]' ADDR)" "[::1]" "sanitize_host accepts bracketed IPv6"
assert_equal "$(sanitize_nonnegative_integer 0 WAIT)" "0" "sanitize_nonnegative_integer accepts 0"
assert_equal "$(sanitize_email ops+acme@mail.example.com)" "ops+acme@mail.example.com" "sanitize_email accepts an address"
assert_equal "$(sanitize_email "o'brien@example.com")" "o'brien@example.com" "sanitize_email accepts an apostrophe"
assert_equal "$(sanitize_email ops@my_host.example.com)" "ops@my_host.example.com" "sanitize_email accepts _ in the domain"
assert_equal "$(sanitize_email user@localhost)" "user@localhost" "sanitize_email accepts a single-label domain"
assert_equal "$(sanitize_domain example.com)" "example.com" "sanitize_domain accepts fqdn"
assert_equal "$(sanitize_domain '*.example.com')" "*.example.com" "sanitize_domain accepts wildcard"
assert_equal "$(sanitize_target_endpoint http://service:80/path)" "http://service:80/path" "sanitize_target_endpoint accepts http"
assert_equal "$(sanitize_target_endpoint grpc://svc:50051)" "grpc://svc:50051" "sanitize_target_endpoint accepts grpc"
assert_equal "$(sanitize_target_endpoint app:80)" "app:80" "sanitize_target_endpoint accepts bare host:port"
assert_equal "$(sanitize_target_endpoint app-main)" "app-main" "sanitize_target_endpoint accepts bare hostname"
assert_equal "$(sanitize_target_endpoint 10.0.0.1:8080)" "10.0.0.1:8080" "sanitize_target_endpoint accepts IP:port"
assert_equal "$(sanitize_dns_label test_label)" "test_label" "sanitize_dns_label accepts lowercase"
assert_equal "$(sanitize_dns_label test-label)" "test-label" "sanitize_dns_label accepts hyphen"
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
assert_equal "$(sanitize_boolean true FLAG)" "true" "sanitize_boolean accepts true"
assert_equal "$(sanitize_boolean false FLAG)" "false" "sanitize_boolean accepts false"


# Failing cases
assert_fails "sanitize_port rejects non-numeric" sanitize_port abc
assert_fails "sanitize_port rejects newlines" sanitize_port $'9443\nfrontend leak' TLSALPN_PORT
assert_fails "sanitize_port rejects out of range" sanitize_port 65536
assert_fails "sanitize_host rejects newlines" sanitize_host $'127.0.0.1\nfrontend leak' ADDR
assert_fails "sanitize_host rejects empty" sanitize_host "" ADDR
assert_fails "sanitize_host rejects spaces" sanitize_host "a b" ADDR
assert_fails "sanitize_host rejects newline in IPv6" sanitize_host $'[::1]\nfrontend leak' ADDR
assert_fails "sanitize_port rejects leading zeros" sanitize_port 0443 PORT
assert_fails "sanitize_positive_integer rejects leading zeros" sanitize_positive_integer 08 INTERVAL
assert_fails "sanitize_nonnegative_integer rejects negative" sanitize_nonnegative_integer -1 WAIT
assert_fails "sanitize_nonnegative_integer rejects a suffix" sanitize_nonnegative_integer 120s WAIT
assert_fails "sanitize_email rejects path traversal" sanitize_email ../../../../evidences/x@x.com
assert_fails "sanitize_email rejects a missing domain" sanitize_email ops@
assert_fails "sanitize_email rejects newlines" sanitize_email $'ops@example.com\nx'
assert_fails "sanitize_email rejects a missing local part" sanitize_email @example.com
assert_fails "sanitize_email rejects two @" sanitize_email a@b@example.com
assert_fails "sanitize_email rejects a leading dot" sanitize_email ..@example.com
assert_fails "sanitize_email rejects a slash in the domain" sanitize_email ops@example.com/..
assert_fails "sanitize_email rejects spaces" sanitize_email 'ops @example.com'
assert_fails "sanitize_email rejects tabs" sanitize_email $'ops@example.com\t'
assert_fails "sanitize_email rejects control characters" sanitize_email $'ops@exa\x01mple.com'
assert_fails "sanitize_domain rejects invalid domain" sanitize_domain bad_domain
assert_equal "$(sanitize_gateway_domain gw.example.com)" "gw.example.com" "sanitize_gateway_domain accepts a hostname"
assert_equal "$(sanitize_gateway_domain _.gw.example.com)" "_.gw.example.com" "sanitize_gateway_domain accepts the older _. form"
assert_fails "sanitize_gateway_domain rejects an empty value" sanitize_gateway_domain ""
assert_fails "sanitize_gateway_domain rejects a newline" sanitize_gateway_domain $'gw.example.com\nx'
assert_fails "sanitize_gateway_domain rejects a space" sanitize_gateway_domain "gw example.com"
assert_fails "sanitize_domain rejects path traversal" sanitize_domain ../etc/passwd
assert_fails "sanitize_target_endpoint rejects malformed URL" sanitize_target_endpoint "http:///broken"
assert_fails "sanitize_dns_label rejects invalid characters" sanitize_dns_label "bad*label"
assert_fails "sanitize_positive_integer rejects zero" sanitize_positive_integer 0 MAXCONN
assert_fails "sanitize_positive_integer rejects non-numeric" sanitize_positive_integer abc MAXCONN
assert_fails "sanitize_haproxy_timeout rejects bare text" sanitize_haproxy_timeout abc TIMEOUT
assert_fails "sanitize_haproxy_timeout rejects bare number" sanitize_haproxy_timeout 10 TIMEOUT
assert_fails "sanitize_alpn rejects semicolons" sanitize_alpn "h2;drop"
assert_fails "sanitize_alpn rejects newlines" sanitize_alpn $'h2\nhttp/1.1'
assert_fails "sanitize_alpn rejects spaces" sanitize_alpn "h2, http/1.1"
assert_fails "sanitize_boolean rejects yes" sanitize_boolean yes FLAG
assert_fails "sanitize_boolean rejects empty" sanitize_boolean "" FLAG

routing_map() { ROUTING_MAP="$1" routing_map_entries; }
assert_equal "$(routing_map $'# apps\n  a.example.com = http://app:80\n\n  # api\n*.example.com=api:8080')" \
    $'a.example.com app:80\n*.example.com api:8080' "routing_map_entries skips indented comments and blank lines"
assert_equal "$(routing_map 'a.example.com=app:80, b.example.com=api:8080')" \
    $'a.example.com app:80\nb.example.com api:8080' "routing_map_entries accepts comma-separated entries"
assert_equal "$(routing_map $'# apps, internal\r\na.example.com=app:80\r\nb.example.com=api:8080\r\n')" \
    $'a.example.com app:80\nb.example.com api:8080' "routing_map_entries accepts CRLF and commas in comments"
assert_fails "routing_map_entries rejects duplicate domains" routing_map $'a.example.com=app:80\nA.example.com=api:8080'
assert_fails "routing_map_entries rejects an entry without a target" routing_map 'a.example.com'
assert_fails "routing_map_entries rejects an invalid domain" routing_map 'bad_domain=app:80'
assert_fails "routing_map_entries rejects an empty map" routing_map '# none'

if [[ $failures -eq 0 ]]; then
    echo "All sanitizer tests passed"
else
    echo "$failures sanitizer tests failed" >&2
    exit 1
fi
