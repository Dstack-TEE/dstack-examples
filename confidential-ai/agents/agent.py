#!/usr/bin/env python3
"""
Secure AI Agent with TEE Key Derivation

This agent demonstrates:
- TEE-derived Ethereum wallet (deterministic, persistent)
- Protected API credentials (encrypted at deploy)
- Confidential LLM calls via redpill.ai
- Attestation proof for execution verification
"""

import os

from dstack_sdk import DstackClient
from dstack_sdk.ethereum import to_account
from eth_account.messages import encode_defunct
from flask import Flask, jsonify, request
from langchain_classic.agents import AgentExecutor, create_react_agent
from langchain_classic.tools import Tool
from langchain_openai import ChatOpenAI
from langchain_core.prompts import PromptTemplate

app = Flask(__name__)

# Lazy initialization - only connect when needed
_client = None
_account = None


def get_client():
    """Get dstack client (lazy initialization)."""
    global _client
    if _client is None:
        _client = DstackClient()
    return _client


def get_account():
    """Get Ethereum account (lazy initialization)."""
    global _account
    if _account is None:
        client = get_client()
        eth_key = client.get_key("agent/wallet", "mainnet")
        _account = to_account(eth_key)
        print(f"Agent wallet address: {_account.address}")
    return _account


def get_wallet_address(_: str = "") -> str:
    """Get the agent's wallet address."""
    return f"Agent wallet: {get_account().address}"


def get_attestation(nonce: str = "default") -> str:
    """Get TEE attestation quote."""
    quote = get_client().get_quote(nonce.encode()[:64])
    return f"TEE Quote (first 100 chars): {quote.quote[:100]}..."


def sign_message(message: str) -> str:
    """Sign a message with the agent's wallet."""
    signable = encode_defunct(text=message)
    signed = get_account().sign_message(signable)
    return f"Signature: {signed.signature.hex()}"


# Define agent tools
tools = [
    Tool(
        name="GetWallet",
        func=get_wallet_address,
        description="Get the agent's Ethereum wallet address",
    ),
    Tool(
        name="GetAttestation",
        func=get_attestation,
        description="Get TEE attestation quote to prove secure execution",
    ),
    Tool(
        name="SignMessage",
        func=sign_message,
        description="Sign a message with the agent's wallet. Input: the message to sign",
    ),
]

# LangChain agent (lazy initialization)
_agent_executor = None


def get_agent_executor():
    """Get LangChain agent executor (lazy initialization)."""
    global _agent_executor
    if _agent_executor is None:
        template = """You are a secure AI agent running in a Trusted Execution Environment (TEE).
You have access to a deterministic Ethereum wallet derived from TEE keys.
Your wallet address and signing capabilities are protected by hardware.

You have access to the following tools:
{tools}

Use the following format:
Question: the input question
Thought: think about what to do
Action: the action to take, should be one of [{tool_names}]
Action Input: the input to the action
Observation: the result of the action
... (repeat Thought/Action/Action Input/Observation as needed)
Thought: I now know the final answer
Final Answer: the final answer

Question: {input}
{agent_scratchpad}"""

        prompt = PromptTemplate.from_template(template)

        # Use redpill.ai for confidential LLM calls (OpenAI-compatible API)
        llm = ChatOpenAI(
            model=os.environ.get("LLM_MODEL", "openai/gpt-4o-mini"),
            base_url=os.environ.get("LLM_BASE_URL", "https://api.redpill.ai/v1"),
            api_key=os.environ.get("LLM_API_KEY", ""),
            temperature=0,
        )

        agent = create_react_agent(llm, tools, prompt)
        _agent_executor = AgentExecutor(
            agent=agent, tools=tools, verbose=True, handle_parsing_errors=True
        )
    return _agent_executor


@app.route("/")
def index():
    """Agent info endpoint."""
    try:
        info = get_client().info()
        return jsonify(
            {
                "status": "running",
                "wallet": get_account().address,
                "app_id": info.app_id,
            }
        )
    except Exception as e:
        return jsonify({"status": "running", "error": str(e)})


@app.route("/attestation")
def attestation():
    """Get TEE attestation."""
    nonce = request.args.get("nonce", "default")
    quote = get_client().get_quote(nonce.encode()[:64])
    return jsonify({"quote": quote.quote, "nonce": nonce})


@app.route("/chat", methods=["POST"])
def chat():
    """Chat with the agent."""
    data = request.get_json()
    message = data.get("message", "")

    if not message:
        return jsonify({"error": "No message provided"}), 400

    try:
        result = get_agent_executor().invoke({"input": message})
        return jsonify(
            {
                "response": result["output"],
                "wallet": get_account().address,
            }
        )
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/sign", methods=["POST"])
def sign():
    """Sign a message with the agent's wallet."""
    data = request.get_json()
    message = data.get("message", "")

    if not message:
        return jsonify({"error": "No message provided"}), 400

    signable = encode_defunct(text=message)
    signed = get_account().sign_message(signable)
    return jsonify(
        {
            "message": message,
            "signature": signed.signature.hex(),
            "signer": get_account().address,
        }
    )


if __name__ == "__main__":
    print("Starting agent server...")
    app.run(host="0.0.0.0", port=8080)
