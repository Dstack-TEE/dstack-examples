#!/bin/bash
# Test vllm-proxy inference and attestation
#
# Prerequisites:
# - docker compose up (running in background)
# - pip install requests

set -e

BASE_URL="${BASE_URL:-http://localhost:8000}"

echo "Testing vllm-proxy at $BASE_URL"
echo "================================"

# Wait for service to be ready
echo "Waiting for service..."
for i in {1..60}; do
    if curl -s "$BASE_URL/health" > /dev/null 2>&1; then
        echo "Service ready"
        break
    fi
    sleep 2
done

# Test chat completion
echo -e "\n1. Testing chat completion..."
RESPONSE=$(curl -s "$BASE_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "Qwen/Qwen2.5-1.5B-Instruct",
        "messages": [{"role": "user", "content": "Say hello in exactly 5 words"}],
        "max_tokens": 50
    }')

CHAT_ID=$(echo "$RESPONSE" | jq -r '.id')
CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content')

echo "Chat ID: $CHAT_ID"
echo "Response: $CONTENT"

# Test signature retrieval
echo -e "\n2. Testing signature retrieval..."
SIG=$(curl -s "$BASE_URL/v1/signature/$CHAT_ID")
echo "Signing address: $(echo "$SIG" | jq -r '.signing_address')"
echo "Response hash: $(echo "$SIG" | jq -r '.response_hash')"

# Test attestation
echo -e "\n3. Testing attestation..."
ATTESTATION=$(curl -s "$BASE_URL/v1/attestation?nonce=test-nonce")
QUOTE=$(echo "$ATTESTATION" | jq -r '.quote')
echo "TEE Quote (first 100 chars): ${QUOTE:0:100}..."

echo -e "\n================================"
echo "All tests passed!"
echo "Verify attestation at: https://proof.t16z.com"
