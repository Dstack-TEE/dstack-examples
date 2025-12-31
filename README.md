# dstack Examples

<div align="center">

[![GitHub Stars](https://img.shields.io/github/stars/Dstack-TEE/dstack?style=flat-square)](https://github.com/Dstack-TEE/dstack-examples/stargazers)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg?style=flat-square)](LICENSE)
[![Telegram](https://img.shields.io/badge/Telegram-Community-blue?style=flat-square&logo=telegram)](https://t.me/+UO4bS4jflr45YmUx)
[![Documentation](https://img.shields.io/badge/Documentation-Phala%20Network-green?style=flat-square)](https://docs.phala.network/dstack)

**Example applications for [dstack](https://github.com/Dstack-TEE/dstack) - Deploy containerized apps to TEEs with end-to-end security in minutes**

[Getting Started](#getting-started) • [Confidential AI](#confidential-ai) • [Tutorials](#tutorials) • [Use Cases](#use-cases) • [Core Patterns](#core-patterns) • [Dev Tools](#dev-scaffolding) • [Starter Packs](#starter-packs)

</div>

---

## Overview

This repository contains ready-to-deploy examples demonstrating how to build and run applications on [dstack](https://github.com/Dstack-TEE/dstack), the developer-friendly SDK for deploying containerized apps in Trusted Execution Environments (TEE).

## Getting Started

### Prerequisites

- Docker and Docker Compose
- Node.js (for Phala CLI)
- Git

### Setup

```bash
# Clone the repo
git clone https://github.com/Dstack-TEE/dstack-examples.git
cd dstack-examples

# Install Phala CLI
npm install -g phala

# Start the local simulator (no TEE hardware needed)
phala simulator start
```

### Run an Example Locally

```bash
cd tutorial/01-attestation
docker compose run --rm \
  -v ~/.phala-cloud/simulator/0.5.3/dstack.sock:/var/run/dstack.sock \
  app
```

### Deploy to Phala Cloud

```bash
phala auth login
phala deploy -n my-app -c docker-compose.yaml
```

See [Phala Cloud](https://cloud.phala.com) for production TEE deployment.

---

## Confidential AI

Run AI workloads where prompts, model weights, and inference stay encrypted in hardware.

| Example | Description |
|---------|-------------|
| [confidential-ai/inference](./confidential-ai/inference) | Private LLM inference with vLLM on Confidential GPU |
| [confidential-ai/training](./confidential-ai/training) | Confidential fine-tuning on sensitive data using Unsloth |
| [confidential-ai/agents](./confidential-ai/agents) | Secure AI agent with TEE-derived wallet keys using LangChain and Confidential AI models |

GPU deployments require: `--instance-type h200.small --region US-EAST-1 --image dstack-nvidia-dev-0.5.4.1`

See [Confidential AI Guide](https://github.com/Dstack-TEE/dstack/blob/master/docs/confidential-ai.md) for concepts and security model.

---

## Tutorials

Step-by-step guides covering core dstack concepts.

| Tutorial | Description |
|----------|-------------|
| [01-attestation](./tutorial/01-attestation) | Build an oracle, bind data to TDX quotes via `report_data`, verify with local scripts |
| [02-kms-and-signing](./tutorial/02-kms-and-signing) | Deterministic key derivation from KMS — persistent wallets, same key across restarts |
| [03-gateway-and-tls](./tutorial/03-gateway-and-tls) | Custom domains with automatic SSL, certificate evidence chain |
| [04-onchain-oracle](./tutorial/04-onchain-oracle) | AppAuth contracts, on-chain signature verification, multi-device deployment |

---

## Use Cases

Real-world applications you can build with dstack.

| Example | Description | Status |
|---------|-------------|--------|
| [8004-agent](./8004-agent) | Trustless AI agent with on-chain attestation and LLM access | Coming Soon |
| [oracle](./oracle) | TEE oracle returning JSON + signature + attestation bundle | Coming Soon |
| [mcp-server](./mcp-server) | Attested MCP tool server behind gateway | Coming Soon |
| [telegram-agent](./telegram-agent) | Telegram bot with TEE wallet and verified execution | Coming Soon |

---

## Core Patterns

Key building blocks for dstack applications.

### Attestation

Request TEE attestations via the SDK. Mount `/var/run/dstack.sock` in your compose file to access the TEE.

```javascript
import { DstackClient } from '@phala/dstack-sdk'
const client = new DstackClient()
const info = await client.info()              // app_id, instance_id, tcb_info
const quote = await client.getQuote(data)     // TDX quote with custom report_data
const key = await client.getKey('/my/path')   // deterministic key derivation
```

```yaml
volumes:
  - /var/run/dstack.sock:/var/run/dstack.sock
```

| Example | Description | Status |
|---------|-------------|--------|
| [timelock-nts](./timelock-nts) | Raw socket usage (what the SDK wraps) | Available |
| [attestation/configid-based](./attestation/configid-based) | ConfigID-based verification | Available |

### Gateway & Domains

TLS termination, custom domains, external connectivity.

| Example | Description |
|---------|-------------|
| [dstack-ingress](./custom-domain/dstack-ingress) | **Complete ingress solution** — auto SSL via Let's Encrypt, multi-domain, DNS validation, evidence generation with TDX quote chain |

### On-Chain Interaction

Light client for reading chain state, anchoring outputs.

| Example | Description |
|---------|-------------|
| [lightclient](./lightclient) | Ethereum light client (Helios) running in enclave |

---

## Dev Scaffolding

Development and debugging tools. **Not for production.**

| Example | Description |
|---------|-------------|
| [webshell](./webshell) | Web-based shell access for debugging |
| [ssh-over-gateway](./ssh-over-gateway) | SSH tunneling through dstack gateway |
| [tcp-port-forwarding](./tcp-port-forwarding) | Arbitrary TCP port forwarding |

---

## Tech Demos

Interesting demonstrations.

| Example | Description |
|---------|-------------|
| [tor-hidden-service](./tor-hidden-service) | Run Tor hidden services in TEEs |

---

## Starter Packs

Full-stack templates with SDK integration. These demonstrate attestation, key derivation, and wallet generation.

| Template | Stack | Link |
|----------|-------|------|
| **Next.js Starter** | Next.js + TypeScript | [phala-cloud-nextjs-starter](https://github.com/Phala-Network/phala-cloud-nextjs-starter) |
| **Python Starter** | FastAPI + Python | [phala-cloud-python-starter](https://github.com/Phala-Network/phala-cloud-python-starter) |
| **Bun Starter** | Bun + TypeScript | [phala-cloud-bun-starter](https://github.com/Phala-Network/phala-cloud-bun-starter) |
| **Node.js Starter** | Express + TypeScript | [phala-cloud-node-starter](https://github.com/Gldywn/phala-cloud-node-starter) |

Features: `/api/tdx_quote` (attestation), `/api/eth_account` (derived wallet), `/api/info` (TCB info)

---

## Other Use Cases

External projects and templates worth exploring. These are maintained elsewhere but demonstrate interesting TEE patterns.

| Project | Description | Link |
|---------|-------------|------|
| **Oracle Template** | Price aggregator with verifiable networking (hardened TLS) and multi-source validation | [Gldywn/phala-cloud-oracle-template](https://github.com/Gldywn/phala-cloud-oracle-template) |
| **VRF Template** | Verifiable Random Function — hardware-backed cryptographic randomness | [Phala-Network/phala-cloud-vrf-template](https://github.com/Phala-Network/phala-cloud-vrf-template) |
| **Open WebUI** | Self-hosted AI chat interface in TEE | [phala-cloud/templates/openwebui](https://github.com/Phala-Network/phala-cloud/tree/main/templates/prebuilt/openwebui) |
| **n8n Automation** | Workflow automation (400+ integrations) with OAuth in TEE | [Marvin-Cypher/phala-n8n-template](https://github.com/Marvin-Cypher/phala-n8n-template) |
| **Primus Attestor** | zkTLS node — TEE + zero-knowledge proofs | [primus-labs/primus-network-startup](https://github.com/primus-labs/primus-network-startup) |
| **NEAR Shade Agent** | Blockchain oracle/agent for NEAR with TEE attestation | [phala-cloud/templates/near-shade-agent](https://github.com/Phala-Network/phala-cloud/tree/main/templates/prebuilt/near-shade-agent) |
| **Presidio** | Microsoft's PII de-identification running in TEE | [HashWarlock/presidio](https://github.com/HashWarlock/presidio/tree/phala-cloud) |
| **ByteBot** | AI desktop agent — computer control in isolated TEE sandbox | [phala-cloud/templates/bytebot](https://github.com/Phala-Network/phala-cloud/tree/main/templates/prebuilt/bytebot) |

> **Note**: These templates use pre-built Docker images. For full auditability, review their source repos before deployment.

See the full [Phala Cloud templates](https://github.com/Phala-Network/phala-cloud#templates) for more options.

---

## Details

Implementation details and infrastructure patterns.

| Example | Description |
|---------|-------------|
| [launcher](./launcher) | Generic launcher pattern for Docker Compose apps |
| [prelaunch-script](./prelaunch-script) | Pre-launch script patterns (Phala Cloud) |
| [private-docker-image-deployment](./private-docker-image-deployment) | Using private Docker registries |
| [attestation/rtmr3-based](./attestation/rtmr3-based) | RTMR3-based attestation (legacy) |

---

## Documentation

- **[dstack Documentation](https://docs.phala.network/dstack)** - Official platform documentation
- **[Main Repository](https://github.com/Dstack-TEE/dstack)** - Core dstack framework
- **[Contributing Guide](CONTRIBUTING.md)** - How to contribute

## Development

```bash
./dev.sh help              # Show available commands
./dev.sh validate <example> # Validate a specific example
./dev.sh validate-all      # Validate all examples
```

## Community

- **Telegram**: [Join our community](https://t.me/+UO4bS4jflr45YmUx)
- **Issues**: [GitHub Issues](https://github.com/Dstack-TEE/dstack-examples/issues)

## License

Apache 2.0 — see [LICENSE](LICENSE).

---

<div align="center">

**[⬆ Back to top](#dstack-examples)**

</div>
