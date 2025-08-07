# dstack Examples

<div align="center">

[![GitHub Stars](https://img.shields.io/github/stars/Dstack-TEE/dstack?style=flat-square)](https://github.com/Dstack-TEE/dstack-examples/stargazers)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg?style=flat-square)](LICENSE)
[![Telegram](https://img.shields.io/badge/Telegram-Community-blue?style=flat-square&logo=telegram)](https://t.me/+UO4bS4jflr45YmUx)
[![Documentation](https://img.shields.io/badge/Documentation-Phala%20Network-green?style=flat-square)](https://docs.phala.network/dstack)

**Example applications for [dstack](https://github.com/Dstack-TEE/dstack) - Deploy containerized apps to TEEs with end-to-end security in minutes**

[Getting Started](#getting-started) • [Examples](#examples) • [Contributing](CONTRIBUTING.md) • [Documentation](#documentation) • [Community](#community)

</div>

---

## Overview

This repository contains ready-to-deploy examples demonstrating how to build and run applications on [dstack](https://github.com/Dstack-TEE/dstack), the developer-friendly SDK for deploying containerized apps in Trusted Execution Environments (TEE).

### What You'll Find Here

- **Security Features** - Remote attestation, verification, and privacy-preserving apps
- **Secret Management** - Secure handling of credentials and sensitive data in TEE environments
- **Networking Patterns** - HTTPS termination, custom domains, port forwarding in the cloud
- **Best Practices** - Production-ready implementations following TEE security principles

## Prerequisites

Before you begin, ensure you have:

- Access to a dstack environment
- Basic understanding of [TEE concepts](https://docs.phala.network/dstack)
- Basic familiarity with Docker Compose configuration files
- Git for cloning the repository

You can deploy dstack on your own server, or use [Phala Cloud](https://cloud.phala.network).

## Getting Started

### Quick Start

```bash
# Clone the repository
git clone https://github.com/Dstack-TEE/dstack-examples.git
cd dstack-examples

# Choose an example
cd attestation/configid-based

# Copy the docker-compose.yaml content to your dstack deployment
# Follow the example-specific README for deployment instructions
```

## Examples

### Security & Attestation
| Example | Description |
|---------|-------------|
| [attestation/configid-based](./attestation/configid-based) | ConfigID-based remote attestation verification |
| [attestation/rtmr3-based](./attestation/rtmr3-based) | RTMR3-based attestation (legacy) |

### Networking & Domains
| Example | Description |
|---------|-------------|
| [custom-domain](./custom-domain) | Set up custom domain with automatic TLS certificate management via zt-https |
| [ssh-over-gateway](./ssh-over-gateway) | SSH tunneling through dstack gateway |
| [tcp-port-forwarding](./tcp-port-forwarding) | Arbitrary TCP port forwarding |
| [tor-hidden-service](./tor-hidden-service) | Run Tor hidden services in TEEs |

### Development Tools
| Example | Description |
|---------|-------------|
| [launcher](./launcher) | Generic launcher pattern for Docker Compose apps |
| [webshell](./webshell) | Web-based shell access for debugging |
| [prelaunch-script](./prelaunch-script) | Pre-launch script patterns used by Phala Cloud |

### Advanced Use Cases
| Example | Description |
|---------|-------------|
| [lightclient](./lightclient) | Blockchain light client integration |
| [timelock-nts](./timelock-nts) | Timelock decryption with NTS |
| [private-docker-image-deployment](./private-docker-image-deployment) | Using private Docker registries |

## Documentation

- **[dstack Documentation](https://docs.phala.network/dstack)** - Official platform documentation
- **[Main Repository](https://github.com/Dstack-TEE/dstack)** - Core dstack framework
- **[Security Guide](SECURITY.md)** - Security best practices
- **[Contributing Guide](CONTRIBUTING.md)** - How to contribute

## Development

Use the `dev.sh` script for validation and development tasks:

```bash
./dev.sh help              # Show available commands
./dev.sh validate <example> # Validate a specific example
./dev.sh validate-all      # Validate all examples
./dev.sh security          # Run security checks
./dev.sh lint              # Run linting checks
./dev.sh check-all         # Run all checks
```

## Contributing

We welcome contributions! Please see our [Contributing Guidelines](CONTRIBUTING.md) for details.

## Community

### Getting Help

- **Telegram**: [Join our community](https://t.me/+UO4bS4jflr45YmUx)
- **Issues**: [GitHub Issues](https://github.com/Dstack-TEE/dstack-examples/issues)

### Reporting Issues

When reporting issues, please include:

1. Example name and version
2. Steps to reproduce
3. Expected vs actual behavior
4. Relevant logs and error messages

## License

This project is licensed under the Apache 2.0 License - see the [LICENSE](LICENSE) file for details.

---

<div align="center">

**[⬆ Back to top](#dstack-examples)**

</div>
