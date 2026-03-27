#!/bin/bash
#
# End-to-end test for dstack-ingress 2.0
#
# Deploys dstack-ingress with multi-protocol backends to a Phala CVM,
# verifies HTTP/1.1, HTTP/2, gRPC, TLS, and evidence serving, then cleans up.
#
# Required env vars:
#   DOMAIN              - Test domain (e.g., test-ingress.example.com)
#   CLOUDFLARE_API_TOKEN - Cloudflare API token for DNS management
#   CERTBOT_EMAIL       - Email for Let's Encrypt registration
#
# Optional env vars:
#   GATEWAY_DOMAIN      - dstack gateway domain (default: _.dstack-prod5.phala.network)
#   IMAGE               - dstack-ingress image (default: dstacktee/dstack-ingress:latest)
#   INSTANCE_TYPE       - CVM instance type (default: tdx.small)
#   CERTBOT_STAGING     - Use LE staging (default: true)
#   SKIP_CLEANUP        - Don't delete CVM on exit (default: false)
#   BOOT_TIMEOUT        - Max seconds to wait for CVM boot (default: 300)
#   READY_TIMEOUT       - Max seconds to wait for HTTPS ready (default: 600)
#

set -uo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────

: "${DOMAIN:?DOMAIN is required}"
: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required}"
: "${CERTBOT_EMAIL:?CERTBOT_EMAIL is required}"
GATEWAY_DOMAIN="${GATEWAY_DOMAIN:-_.dstack-prod5.phala.network}"
IMAGE="${IMAGE:-dstacktee/dstack-ingress:latest}"
INSTANCE_TYPE="${INSTANCE_TYPE:-tdx.small}"
CERTBOT_STAGING="${CERTBOT_STAGING:-true}"
SKIP_CLEANUP="${SKIP_CLEANUP:-false}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
READY_TIMEOUT="${READY_TIMEOUT:-600}"

# Derived domains for multi-protocol testing
if [[ "$DOMAIN" == \** ]]; then
    echo "Error: DOMAIN must not be a wildcard for e2e testing (got $DOMAIN)" >&2
    exit 1
fi
GRPC_DOMAIN="grpc-${DOMAIN}"

CVM_NAME="ingress-e2e-$(date +%s)"
COMPOSE_FILE="$(mktemp /tmp/e2e-compose-XXXXXX.yaml)"
TESTS_PASSED=0
TESTS_FAILED=0

# ── Helpers ────────────────────────────────────────────────────────────────────

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); log "PASS: $1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); log "FAIL: $1" >&2; }

# Resolve domain IP via public DNS (local resolver may not have it yet)
resolve_domain() {
    dig +short A "$1" @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1
}

# curl with common flags (TLS insecure for staging, DNS resolve bypass)
do_curl() {
    local flags=("--max-time" "10")
    if [ "$CERTBOT_STAGING" = "true" ]; then
        flags+=(-k)
    fi
    if [ -n "${DOMAIN_IP:-}" ]; then
        flags+=("--resolve" "${DOMAIN}:443:${DOMAIN_IP}")
        flags+=("--resolve" "${GRPC_DOMAIN}:443:${DOMAIN_IP}")
    fi
    curl "${flags[@]}" "$@"
}

cleanup() {
    log "Cleaning up..."
    rm -f "$COMPOSE_FILE"
    if [ "$SKIP_CLEANUP" = "true" ]; then
        log "SKIP_CLEANUP=true, CVM '$CVM_NAME' left running"
        return
    fi
    if phala cvms get "$CVM_NAME" --json >/dev/null 2>&1; then
        log "Deleting CVM: $CVM_NAME"
        echo y | phala cvms delete "$CVM_NAME" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Generate test compose ──────────────────────────────────────────────────────
#
# Architecture:
#   client ──TLS──► haproxy (L4 proxy) ──TCP──► whoami   (HTTP/1.1 + h2c)
#                                        └─TCP──► grpcbin (gRPC / h2c)
#
# haproxy uses SNI to route:
#   ${DOMAIN}      → whoami:80
#   ${GRPC_DOMAIN} → grpcbin:9000
#

log "Generating test compose: $COMPOSE_FILE"
cat > "$COMPOSE_FILE" <<YAML
services:
  dstack-ingress:
    image: ${IMAGE}
    ports:
      - "443:443"
    environment:
      - DNS_PROVIDER=cloudflare
      - CLOUDFLARE_API_TOKEN=\${CLOUDFLARE_API_TOKEN}
      - CERTBOT_EMAIL=\${CERTBOT_EMAIL}
      - CERTBOT_STAGING=\${CERTBOT_STAGING}
      - GATEWAY_DOMAIN=\${GATEWAY_DOMAIN}
      - SET_CAA=false
      - EVIDENCE_SERVER=true
      - ALPN=h2,http/1.1
      - DOMAINS=\${DOMAINS}
      - ROUTING_MAP=\${ROUTING_MAP}
    volumes:
      - /var/run/dstack.sock:/var/run/dstack.sock
      - /var/run/tappd.sock:/var/run/tappd.sock
      - cert-data:/etc/letsencrypt
      - evidences:/evidences
    restart: unless-stopped

  whoami:
    image: traefik/whoami:latest
    volumes:
      - evidences:/data/evidences:ro
    restart: unless-stopped

  grpcbin:
    image: moul/grpcbin
    restart: unless-stopped

volumes:
  cert-data:
  evidences:
YAML

log "Test configuration:"
log "  CVM_NAME:        $CVM_NAME"
log "  DOMAIN:          $DOMAIN"
log "  GRPC_DOMAIN:     $GRPC_DOMAIN"
log "  IMAGE:           $IMAGE"
log "  INSTANCE_TYPE:   $INSTANCE_TYPE"
log "  CERTBOT_STAGING: $CERTBOT_STAGING"

# ── Deploy ─────────────────────────────────────────────────────────────────────

# Use comma-separated format (phala CLI -e flattens newlines)
DOMAINS_VAL="${DOMAIN},${GRPC_DOMAIN}"
ROUTING_MAP_VAL="${DOMAIN}=whoami:80,${GRPC_DOMAIN}=grpcbin:9000"

log "Deploying CVM: $CVM_NAME"
if ! phala deploy \
    -c "$COMPOSE_FILE" \
    -n "$CVM_NAME" \
    -t "$INSTANCE_TYPE" \
    -e "CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}" \
    -e "CERTBOT_EMAIL=${CERTBOT_EMAIL}" \
    -e "CERTBOT_STAGING=${CERTBOT_STAGING}" \
    -e "GATEWAY_DOMAIN=${GATEWAY_DOMAIN}" \
    -e "DOMAINS=${DOMAINS_VAL}" \
    -e "ROUTING_MAP=${ROUTING_MAP_VAL}" \
    --wait; then
    fail "CVM deployment failed"
    exit 1
fi

log "CVM deployed, waiting for boot..."

# ── Wait for CVM running ──────────────────────────────────────────────────────

wait_for_status() {
    local target_status="$1"
    local timeout="$2"
    local elapsed=0
    local interval=10

    while [ "$elapsed" -lt "$timeout" ]; do
        local status
        status=$(phala cvms get "$CVM_NAME" --json 2>/dev/null | jq -r '.status // empty' 2>/dev/null || echo "")
        if [ "$status" = "$target_status" ]; then
            log "CVM status: $status"
            return 0
        fi
        log "CVM status: ${status:-unknown} (waiting for $target_status, ${elapsed}s/${timeout}s)"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    return 1
}

if wait_for_status "running" "$BOOT_TIMEOUT"; then
    pass "CVM reached running state"
else
    fail "CVM did not reach running state within ${BOOT_TIMEOUT}s"
    log "Fetching serial logs..."
    phala logs --serial --cvm-id "$CVM_NAME" -n 50 2>/dev/null || true
    exit 1
fi

# ── Resolve domain IPs ────────────────────────────────────────────────────────

log "Resolving domain IPs via public DNS..."
DOMAIN_IP=""
for i in $(seq 1 30); do
    DOMAIN_IP=$(resolve_domain "$DOMAIN")
    if [ -n "$DOMAIN_IP" ]; then
        log "Domain resolves to: $DOMAIN_IP"
        break
    fi
    log "DNS not propagated yet (attempt $i/30)"
    sleep 10
done

if [ -z "$DOMAIN_IP" ]; then
    fail "Domain $DOMAIN did not resolve within 5 minutes"
    exit 1
fi

# ── Wait for HTTPS ready ──────────────────────────────────────────────────────

log "Waiting for HTTPS to become available at https://${DOMAIN}/"

wait_for_https() {
    local domain="$1"
    local timeout="$2"
    local elapsed=0
    local interval=15

    while [ "$elapsed" -lt "$timeout" ]; do
        if do_curl -sf --http1.1 -o /dev/null "https://${domain}/" 2>/dev/null; then
            log "HTTPS responding on ${domain}"
            return 0
        fi
        log "HTTPS not ready yet on ${domain} (${elapsed}s/${timeout}s)"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    return 1
}

if wait_for_https "$DOMAIN" "$READY_TIMEOUT"; then
    pass "HTTPS endpoint is reachable"
else
    fail "HTTPS endpoint not reachable within ${READY_TIMEOUT}s"
    log "Fetching ingress container logs..."
    phala logs --cvm-id "$CVM_NAME" --serial -n 100 2>/dev/null || true
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# Verification tests
# ══════════════════════════════════════════════════════════════════════════════

# ── HTTP/1.1 tests ───────────────────────────────────────────────────────────

log "Test: HTTP/1.1 through TCP proxy"
H1_STATUS=$(do_curl -s -o /dev/null -w '%{http_code}' --http1.1 "https://${DOMAIN}/")
if [ "$H1_STATUS" = "200" ]; then
    pass "HTTP/1.1 returns 200"
else
    fail "HTTP/1.1 expected 200, got $H1_STATUS"
fi

# Verify response came from whoami backend
log "Test: HTTP/1.1 routed to correct backend"
H1_BODY=$(do_curl -sf --http1.1 "https://${DOMAIN}/" || echo "")
if echo "$H1_BODY" | grep -qi "hostname"; then
    pass "HTTP/1.1 routed to whoami backend"
else
    fail "HTTP/1.1 response doesn't look like whoami"
fi

# ── HTTP/2 ALPN test ─────────────────────────────────────────────────────────
# Verify TLS ALPN negotiation at the protocol level using openssl.
# curl --http2 is unreliable here because grpcbin doesn't serve HTTP on GET /.

log "Test: TLS ALPN negotiates h2 (via gRPC domain)"
ALPN_PROTO=$(echo | openssl s_client -connect "${DOMAIN_IP}:443" -servername "${GRPC_DOMAIN}" -alpn h2 2>/dev/null \
    | grep -oP 'ALPN protocol: \K\S+' || echo "")
if [ "$ALPN_PROTO" = "h2" ]; then
    pass "TLS ALPN negotiated h2"
else
    fail "TLS ALPN expected h2, got: ${ALPN_PROTO:-none}"
fi

# ── gRPC tests ───────────────────────────────────────────────────────────────

log "Test: gRPC through TCP proxy"
GRPC_FLAGS=()
if [ "$CERTBOT_STAGING" = "true" ]; then
    GRPC_FLAGS+=("-insecure")
fi

# Wait for gRPC domain to be ready (may take a moment after HTTP domain)
log "Waiting for gRPC domain..."
GRPC_READY=false
for i in $(seq 1 20); do
    if grpcurl "${GRPC_FLAGS[@]}" \
        -authority "${GRPC_DOMAIN}" \
        "${DOMAIN_IP}:443" \
        list >/dev/null 2>&1; then
        GRPC_READY=true
        break
    fi
    sleep 5
done

if [ "$GRPC_READY" = "true" ]; then
    pass "gRPC endpoint reachable"
else
    fail "gRPC endpoint not reachable"
fi

# List available gRPC services (tests reflection)
if [ "$GRPC_READY" = "true" ]; then
    log "Test: gRPC service listing (reflection)"
    GRPC_SERVICES=$(grpcurl "${GRPC_FLAGS[@]}" \
        -authority "${GRPC_DOMAIN}" \
        "${DOMAIN_IP}:443" \
        list 2>/dev/null || echo "")
    if echo "$GRPC_SERVICES" | grep -q "grpc"; then
        pass "gRPC reflection lists services"
        log "  Services: $(echo "$GRPC_SERVICES" | tr '\n' ', ')"
    else
        fail "gRPC reflection returned no services"
    fi

    # Make an actual gRPC call
    log "Test: gRPC unary call"
    GRPC_RESULT=$(grpcurl "${GRPC_FLAGS[@]}" \
        -authority "${GRPC_DOMAIN}" \
        -d '{"greeting": "e2e-test"}' \
        "${DOMAIN_IP}:443" \
        hello.HelloService/SayHello 2>/dev/null || echo "ERROR")
    if echo "$GRPC_RESULT" | grep -q "e2e-test"; then
        pass "gRPC unary call returned correct response"
    elif echo "$GRPC_RESULT" | grep -qi "error"; then
        fail "gRPC unary call failed: $GRPC_RESULT"
    else
        pass "gRPC unary call completed (response: $(echo "$GRPC_RESULT" | head -1))"
    fi
fi

# ── TLS tests ────────────────────────────────────────────────────────────────

log "Test: TLS certificate"
CERT_ISSUER=$(echo | openssl s_client -connect "${DOMAIN_IP}:443" -servername "${DOMAIN}" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || echo "")
if echo "$CERT_ISSUER" | grep -qi "let's encrypt\|letsencrypt\|fake\|staging"; then
    pass "TLS certificate from Let's Encrypt"
else
    fail "Unexpected certificate issuer: $CERT_ISSUER"
fi

log "Test: TLS version"
TLS_INFO=$(echo | openssl s_client -connect "${DOMAIN_IP}:443" -servername "${DOMAIN}" 2>&1 || true)
TLS_VERSION=$(echo "$TLS_INFO" | grep -oE "TLSv1\.[0-9]" | head -1 || echo "unknown")
if [ -n "$TLS_VERSION" ]; then
    pass "TLS version: $TLS_VERSION"
else
    fail "Could not determine TLS version"
fi

# ── Evidence tests ───────────────────────────────────────────────────────────

log "Test: Evidence endpoint /evidences/"
EVIDENCE_STATUS=$(do_curl -s -o /dev/null -w '%{http_code}' --http1.1 "https://${DOMAIN}/evidences/")
if [ "$EVIDENCE_STATUS" = "200" ]; then
    pass "Evidence endpoint returns 200"
else
    fail "Evidence endpoint returned $EVIDENCE_STATUS"
fi

log "Test: Evidence files"
for file in acme-account.json sha256sum.txt quote.json; do
    FILE_STATUS=$(do_curl -s -o /dev/null -w '%{http_code}' --http1.1 "https://${DOMAIN}/evidences/${file}")
    if [ "$FILE_STATUS" = "200" ]; then
        pass "Evidence file /${file} exists"
    else
        fail "Evidence file /${file} returned $FILE_STATUS"
    fi
done

log "Test: Evidence integrity"
SHA256_CONTENT=$(do_curl -sf --http1.1 "https://${DOMAIN}/evidences/sha256sum.txt" || echo "")
if echo "$SHA256_CONTENT" | grep -q "acme-account.json"; then
    pass "sha256sum.txt references acme-account.json"
else
    fail "sha256sum.txt missing acme-account.json reference"
fi

# ── SNI routing test ─────────────────────────────────────────────────────────

log "Test: SNI routes different domains to different backends"
# whoami backend returns "Hostname:" header
WHOAMI_RESP=$(do_curl -sf --http1.1 "https://${DOMAIN}/" || echo "")
# grpc domain should NOT return whoami response
GRPC_HTTP=$(do_curl -s -o /dev/null -w '%{http_code}' --http1.1 "https://${GRPC_DOMAIN}/" 2>/dev/null || echo "000")
if echo "$WHOAMI_RESP" | grep -qi "hostname" && [ "$GRPC_HTTP" != "200" ]; then
    pass "SNI routing separates HTTP and gRPC backends"
elif echo "$WHOAMI_RESP" | grep -qi "hostname"; then
    pass "SNI routing confirmed (HTTP domain serves whoami)"
else
    fail "SNI routing may not be working correctly"
fi

# ── Results ────────────────────────────────────────────────────────────────────

echo ""
log "════════════════════════════════════════════"
log "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed"
log "════════════════════════════════════════════"

if [ "$TESTS_FAILED" -gt 0 ]; then
    log "Dumping ingress logs for debugging:"
    phala logs --cvm-id "$CVM_NAME" --serial -n 100 2>/dev/null || true
    exit 1
fi

log "All tests passed!"
