#!/usr/bin/env python3
"""
Verify LLM responses from vllm-proxy.

This script demonstrates how to:
1. Send chat completions to the TEE-hosted LLM
2. Retrieve and verify response signatures
3. Fetch TEE attestation quotes
"""

import argparse
import hashlib
import json
import sys

import requests


def chat_completion(base_url: str, message: str) -> dict:
    """Send a chat completion request."""
    response = requests.post(
        f"{base_url}/v1/chat/completions",
        json={
            "model": "Qwen/Qwen2.5-1.5B-Instruct",
            "messages": [{"role": "user", "content": message}],
            "max_tokens": 256,
        },
        headers={"Content-Type": "application/json"},
    )
    response.raise_for_status()
    return response.json()


def get_signature(base_url: str, chat_id: str) -> dict:
    """Retrieve the signature for a chat completion."""
    response = requests.get(f"{base_url}/v1/signature/{chat_id}")
    response.raise_for_status()
    return response.json()


def get_attestation(base_url: str, nonce: str = "verification-nonce") -> dict:
    """Fetch TEE attestation quote."""
    response = requests.get(f"{base_url}/v1/attestation", params={"nonce": nonce})
    response.raise_for_status()
    return response.json()


def verify_response_hash(response_content: str, expected_hash: str) -> bool:
    """Verify response content matches the signed hash."""
    computed = hashlib.sha256(response_content.encode()).hexdigest()
    return computed == expected_hash


def main():
    parser = argparse.ArgumentParser(description="Verify vllm-proxy responses")
    parser.add_argument(
        "--url",
        default="http://localhost:8000",
        help="vllm-proxy URL (default: http://localhost:8000)",
    )
    parser.add_argument(
        "--message",
        default="What is confidential computing?",
        help="Message to send",
    )
    parser.add_argument(
        "--attestation-only",
        action="store_true",
        help="Only fetch attestation, skip chat",
    )
    args = parser.parse_args()

    if args.attestation_only:
        print("Fetching attestation...")
        attestation = get_attestation(args.url)
        print(f"\nTEE Quote (first 200 chars):\n{attestation.get('quote', '')[:200]}...")
        if attestation.get("gpu_evidence"):
            print(f"\nGPU Evidence: {attestation['gpu_evidence'][:100]}...")
        print("\nVerify at: https://proof.t16z.com")
        return

    # Send chat completion
    print(f"Sending message: {args.message}")
    completion = chat_completion(args.url, args.message)

    chat_id = completion["id"]
    response_text = completion["choices"][0]["message"]["content"]

    print(f"\nResponse:\n{response_text}")
    print(f"\nChat ID: {chat_id}")

    # Get signature
    print("\nFetching signature...")
    sig = get_signature(args.url, chat_id)

    print(f"Request hash:  {sig.get('request_hash', 'N/A')}")
    print(f"Response hash: {sig.get('response_hash', 'N/A')}")
    print(f"ECDSA sig:     {sig.get('ecdsa_signature', 'N/A')[:64]}...")
    print(f"Signing addr:  {sig.get('signing_address', 'N/A')}")

    # Get attestation
    print("\nFetching attestation...")
    attestation = get_attestation(args.url)

    quote = attestation.get("quote", "")
    print(f"TEE Quote:     {quote[:64]}..." if quote else "No quote available")

    # Summary
    print("\n" + "=" * 60)
    print("VERIFICATION CHECKLIST")
    print("=" * 60)
    print("1. [  ] TEE quote is valid (verify at proof.t16z.com)")
    print("2. [  ] Signing address in quote matches response signer")
    print("3. [  ] Response hash matches actual response content")
    print(f"\nPaste this quote at https://proof.t16z.com for verification:")
    print(quote[:200] + "..." if len(quote) > 200 else quote)


if __name__ == "__main__":
    main()
