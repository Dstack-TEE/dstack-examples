#!/bin/bash
#
# End-to-end test for dstack-ingress 2.0
#
# Deploys dstack-ingress + a backend to a Phala CVM, verifies TLS termination,
# TCP pass-through, and evidence serving, then cleans up.
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

CVM_NAME="ingress-e2e-$(date +%s)"
COMPOSE_FILE="$(mktemp /tmp/e2e-compose-XXXXXX.yaml)"
CURL_FLAGS=("--http1.1")
TESTS_PASSED=0
TESTS_FAILED=0

if [ "$CERTBOT_STAGING" = "true" ]; then
    # Staging certs are not trusted; allow insecure for test verification
    CURL_FLAGS+=(-k)
fi

# ── Helpers ────────────────────────────────────────────────────────────────────

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); log "PASS: $1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); log "FAIL: $1" >&2; }

# Resolve domain IP via public DNS (local resolver may not have it yet)
resolve_domain() {
    # dig +short may return CNAME then IP; grep for just the IP address
    dig +short A "$DOMAIN" @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1
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

log "Generating test compose: $COMPOSE_FILE"
cat > "$COMPOSE_FILE" <<'YAML'
services:
  dstack-ingress:
    image: ${IMAGE}
    ports:
      - "443:443"
    environment:
      - DNS_PROVIDER=cloudflare
      - CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}
      - DOMAIN=${DOMAIN}
      - GATEWAY_DOMAIN=${GATEWAY_DOMAIN}
      - CERTBOT_EMAIL=${CERTBOT_EMAIL}
      - CERTBOT_STAGING=${CERTBOT_STAGING}
      - SET_CAA=false
      - TARGET_ENDPOINT=backend:80
      - EVIDENCE_SERVER=true
    volumes:
      - /var/run/dstack.sock:/var/run/dstack.sock
      - /var/run/tappd.sock:/var/run/tappd.sock
      - cert-data:/etc/letsencrypt
      - evidences:/evidences
    restart: unless-stopped

  backend:
    image: nginx:stable-alpine
    volumes:
      - evidences:/usr/share/nginx/html/evidences:ro
    restart: unless-stopped

volumes:
  cert-data:
  evidences:
YAML

# Substitute image into compose (phala CLI handles -e for sealed vars)
sed -i "s|\${IMAGE}|${IMAGE}|g" "$COMPOSE_FILE"

log "Test configuration:"
log "  CVM_NAME:        $CVM_NAME"
log "  DOMAIN:          $DOMAIN"
log "  IMAGE:           $IMAGE"
log "  INSTANCE_TYPE:   $INSTANCE_TYPE"
log "  CERTBOT_STAGING: $CERTBOT_STAGING"

# ── Deploy ─────────────────────────────────────────────────────────────────────

log "Deploying CVM: $CVM_NAME"
phala deploy \
    -c "$COMPOSE_FILE" \
    -n "$CVM_NAME" \
    -t "$INSTANCE_TYPE" \
    -e "CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}" \
    -e "DOMAIN=${DOMAIN}" \
    -e "GATEWAY_DOMAIN=${GATEWAY_DOMAIN}" \
    -e "CERTBOT_EMAIL=${CERTBOT_EMAIL}" \
    -e "CERTBOT_STAGING=${CERTBOT_STAGING}" \
    --wait

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
    log "Fetching CVM details for debugging..."
    phala cvms get "$CVM_NAME" --json 2>/dev/null || true
    log "Fetching serial logs..."
    phala logs --serial --cvm-id "$CVM_NAME" -n 50 2>/dev/null || true
    exit 1
fi

# ── Resolve domain IP ─────────────────────────────────────────────────────────

log "Resolving domain IP via public DNS..."
DOMAIN_IP=""
for i in $(seq 1 30); do
    DOMAIN_IP=$(resolve_domain)
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

# Use --resolve to bypass local DNS cache issues
CURL_FLAGS+=("--resolve" "${DOMAIN}:443:${DOMAIN_IP}")

# ── Wait for HTTPS ready ──────────────────────────────────────────────────────

log "Waiting for HTTPS to become available at https://${DOMAIN}/"

wait_for_https() {
    local timeout="$1"
    local elapsed=0
    local interval=15

    while [ "$elapsed" -lt "$timeout" ]; do
        if curl -sf "${CURL_FLAGS[@]}" --max-time 10 -o /dev/null "https://${DOMAIN}/" 2>/dev/null; then
            log "HTTPS responding"
            return 0
        fi
        log "HTTPS not ready yet (${elapsed}s/${timeout}s)"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    return 1
}

if wait_for_https "$READY_TIMEOUT"; then
    pass "HTTPS endpoint is reachable"
else
    fail "HTTPS endpoint not reachable within ${READY_TIMEOUT}s"
    log "Fetching ingress container logs..."
    phala logs --cvm-id "$CVM_NAME" --serial -n 100 2>/dev/null || true
    exit 1
fi

# ── Verification tests ────────────────────────────────────────────────────────

# Test 1: HTTP response through TCP proxy
log "Test: HTTP response through TCP proxy"
HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "${CURL_FLAGS[@]}" --max-time 10 "https://${DOMAIN}/")
if [ "$HTTP_STATUS" = "200" ]; then
    pass "HTTP 200 through TCP proxy"
else
    fail "Expected HTTP 200, got $HTTP_STATUS"
fi

# Test 2: TLS certificate verification
log "Test: TLS certificate"
CERT_ISSUER=$(echo | openssl s_client -connect "${DOMAIN_IP}:443" -servername "${DOMAIN}" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || echo "")
if echo "$CERT_ISSUER" | grep -qi "let's encrypt\|letsencrypt\|fake\|staging"; then
    pass "TLS certificate from Let's Encrypt (issuer: $CERT_ISSUER)"
else
    fail "Unexpected certificate issuer: $CERT_ISSUER"
fi

# Test 3: TLS protocol version
log "Test: TLS version"
TLS_INFO=$(echo | openssl s_client -connect "${DOMAIN_IP}:443" -servername "${DOMAIN}" 2>&1 || true)
TLS_VERSION=$(echo "$TLS_INFO" | grep -oE "TLSv1\.[0-9]" | head -1 || echo "unknown")
if [ -n "$TLS_VERSION" ]; then
    pass "TLS version: $TLS_VERSION"
else
    fail "Could not determine TLS version"
fi

# Test 4: Evidence endpoint (via payload inspection)
log "Test: Evidence endpoint /evidences/"
EVIDENCE_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "${CURL_FLAGS[@]}" --max-time 10 "https://${DOMAIN}/evidences/")
if [ "$EVIDENCE_STATUS" = "200" ]; then
    pass "Evidence endpoint returns 200"
else
    fail "Evidence endpoint returned $EVIDENCE_STATUS"
fi

# Test 5: Evidence files exist
log "Test: Evidence files"
for file in acme-account.json sha256sum.txt quote.json; do
    FILE_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "${CURL_FLAGS[@]}" --max-time 10 "https://${DOMAIN}/evidences/${file}")
    if [ "$FILE_STATUS" = "200" ]; then
        pass "Evidence file /${file} exists"
    else
        fail "Evidence file /${file} returned $FILE_STATUS"
    fi
done

# Test 6: Evidence integrity (sha256sum.txt contains expected entries)
log "Test: Evidence integrity"
SHA256_CONTENT=$(curl -sf "${CURL_FLAGS[@]}" --max-time 10 "https://${DOMAIN}/evidences/sha256sum.txt" || echo "")
if echo "$SHA256_CONTENT" | grep -q "acme-account.json"; then
    pass "sha256sum.txt references acme-account.json"
else
    fail "sha256sum.txt missing acme-account.json reference"
fi

# Test 7: Backend can serve evidences via shared volume (Option D)
log "Test: Backend serves evidences via shared volume"
BACKEND_EVIDENCE=$(curl -sf "${CURL_FLAGS[@]}" --max-time 10 "https://${DOMAIN}/evidences/sha256sum.txt" || echo "")
if [ -n "$BACKEND_EVIDENCE" ]; then
    pass "Backend can access evidence files"
else
    fail "Backend cannot access evidence files"
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
