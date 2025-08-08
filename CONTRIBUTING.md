# Contributing to dstack Examples

Thank you for your interest in contributing to dstack Examples! This guide will help you contribute new examples or improve existing ones.

## Types of Contributions

We welcome:
- **New Examples** - Demonstrate new dstack features or use cases
- **Example Improvements** - Enhance existing examples with better practices
- **Documentation** - Improve READMEs and inline documentation
- **Bug Fixes** - Fix issues in existing examples

## Creating a New Example

### 1. Choose Your Example Type

Consider what your example will demonstrate:
- **Security & Attestation** - TEE verification, remote attestation patterns
- **Networking & Domains** - Custom domains, port forwarding, gateway patterns
- **Development Tools** - Debugging, deployment utilities
- **Advanced Use Cases** - Complex integrations, blockchain, cryptography

### 2. Set Up Your Example Directory

```bash
# Create your example directory
mkdir my-example-name
cd my-example-name

# Create required files
touch README.md
touch docker-compose.yaml
touch .env.example  # If environment variables are needed
```

### 3. Create docker-compose.yaml

Your `docker-compose.yaml` should follow these patterns:

```yaml
services:
  your-service:
    image: your-image@sha256:1234abcd  # Use specific image digest to pin the image (not tags)
    restart: unless-stopped
    environment:
      - SOME_API_KEY=${SOME_API_KEY}  # Use encrypted secrets when passing sensitive info
    ports:
      - "8080:80"  # Only expose necessary ports
    volumes:
      - data:/app/data:  # Use persistent storage
    # Add health checks for production readiness
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/health"]
      interval: 30s
      timeout: 10s
      retries: 3
volumes:
  data:
```

### 4. Write a Comprehensive README.md

Every example MUST include a README.md. Suggested format:

```markdown
# Example Name

## Description
Brief description of what this example demonstrates and why it's useful.

## Prerequisites
- List any required knowledge
- Required dstack features
- External services needed

## Quick Start
Step-by-step deployment instructions:
1. Copy docker-compose.yaml to your dstack deployment
2. Configure environment variables
3. Deploy through dstack interface

## Configuration
### Environment Variables
| Variable | Description | Required | Default |
|----------|-------------|----------|---------|
| API_KEY | Your api key | Yes | - |

## How It Works
Explain the technical implementation and what makes this example special.

## Security Considerations
- TEE-specific security features used
- Any security best practices demonstrated
- Important security notes

## Troubleshooting
Common issues and solutions.
```

## Improving Existing Examples

When improving existing examples:

1. **Maintain Compatibility** - Don't break existing deployments
2. **Update Documentation** - Reflect all changes in README
3. **Test Thoroughly** - Ensure improvements work correctly

## Development Workflow

### 1. Fork and Clone

```bash
git clone https://github.com/YOUR-USERNAME/dstack-examples.git
cd dstack-examples
```

### 2. Create Feature Branch

```bash
git checkout -b feat/add-awesome-example
```

### 3. Develop Your Example

Follow the patterns above and use an existing example as a reference.

### 4. Commit Your Changes

Use conventional commits:

```bash
# For new examples
git commit -m "feat: add blockchain verification example"

# For improvements
git commit -m "fix: resolve port conflict in webshell example"
git commit -m "docs: improve attestation example README"
git commit -m "refactor: simplify launcher deployment"
```

### 5. Push and Create PR

```bash
git push origin feat/add-awesome-example
```

Then create a Pull Request with:
- Clear description of what the example demonstrates
- Any special considerations for reviewers
- Testing steps followed

## Commit Convention

- `feat`: New example or major feature addition to existing example
- `fix`: Bug fixes in examples
- `docs`: Documentation improvements
- `refactor`: Code improvements without changing functionality
- `test`: Adding tests or test scripts
- `ci`: CI/CD related changes
- `chore`: Maintenance tasks
```

## Getting Help

- **Technical Questions**: [GitHub Discussions](https://github.com/Dstack-TEE/dstack-examples/discussions)
- **Bug Reports**: [GitHub Issues](https://github.com/Dstack-TEE/dstack-examples/issues)
- **Real-time Chat**: [Telegram Community](https://t.me/+UO4bS4jflr45YmUx)

## Recognition

Contributors are recognized in:
- Repository contributors list
- Release notes
- Special mentions for significant contributions

Thank you for contributing to dstack Examples! 🎉
