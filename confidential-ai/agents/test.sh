#!/bin/bash
# Test the AI agent
#
# Prerequisites:
# - docker compose up (running in background)

set -e

BASE_URL="${BASE_URL:-http://localhost:8080}"

echo "Testing AI Agent at $BASE_URL"
echo "=============================="

# Wait for service to be ready
echo "Waiting for service..."
for i in {1..30}; do
    if curl -s "$BASE_URL/" > /dev/null 2>&1; then
        echo "Service ready"
        break
    fi
    sleep 2
done

# Test info endpoint
echo -e "\n1. Testing info endpoint..."
INFO=$(curl -s "$BASE_URL/")
echo "Wallet: $(echo "$INFO" | jq -r '.wallet')"
echo "App ID: $(echo "$INFO" | jq -r '.app_id')"

# Test attestation
echo -e "\n2. Testing attestation..."
ATTESTATION=$(curl -s "$BASE_URL/attestation?nonce=test-123")
QUOTE=$(echo "$ATTESTATION" | jq -r '.quote')
echo "TEE Quote (first 100 chars): ${QUOTE:0:100}..."

# Test signing
echo -e "\n3. Testing message signing..."
SIG=$(curl -s -X POST "$BASE_URL/sign" \
    -H "Content-Type: application/json" \
    -d '{"message": "Hello from TEE"}')
echo "Signer: $(echo "$SIG" | jq -r '.signer')"
echo "Signature: $(echo "$SIG" | jq -r '.signature' | head -c 66)..."

# Test chat (requires OPENAI_API_KEY)
if [ -n "$OPENAI_API_KEY" ]; then
    echo -e "\n4. Testing chat..."
    CHAT=$(curl -s -X POST "$BASE_URL/chat" \
        -H "Content-Type: application/json" \
        -d '{"message": "What is your wallet address?"}')
    echo "Response: $(echo "$CHAT" | jq -r '.response')"
else
    echo -e "\n4. Skipping chat test (OPENAI_API_KEY not set)"
fi

echo -e "\n=============================="
echo "Tests completed!"
echo "Verify attestation at: https://proof.t16z.com"
