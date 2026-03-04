# Custom Domain Setup for dstack Applications

This repository provides a solution for setting up custom domains with automatic SSL certificate management for dstack applications using various DNS providers and Let's Encrypt.

## Overview

This project enables you to run dstack applications with your own custom domain, complete with:

- Automatic SSL certificate provisioning and renewal via Let's Encrypt
- Multi-provider DNS support (Cloudflare, Linode DNS, more to come)
- Automatic DNS configuration for CNAME, TXT, and CAA records
- Nginx reverse proxy to route traffic to your application
- Certificate evidence generation for verification
- Strong SSL/TLS configuration with modern cipher suites (AES-GCM and ChaCha20-Poly1305)

## How It Works

The dstack-ingress system provides a seamless way to set up custom domains for dstack applications with automatic SSL certificate management. Here's how it works:

1. **Initial Setup**:

   - When first deployed, the container automatically obtains SSL certificates from Let's Encrypt using DNS validation
   - It configures your DNS provider by creating necessary CNAME, TXT, and optional CAA records
   - Nginx is configured to use the obtained certificates and proxy requests to your application

2. **DNS Configuration**:

   - A CNAME record is created to point your custom domain to the dstack gateway domain
   - A TXT record is added with application identification information to help dstack-gateway to route traffic to your application
   - If enabled, CAA records are set to restrict which Certificate Authorities can issue certificates for your domain
   - The system automatically detects your DNS provider based on environment variables

3. **Certificate Management**:

   - SSL certificates are automatically obtained during initial setup
   - A simple background daemon checks for certificate renewal every 12 hours
   - When certificates are renewed, Nginx is automatically reloaded to use the new certificates
   - Uses a simple sleep loop instead of cron for reliability and easier debugging in containers

4. **Evidence Generation**:
   - The system generates evidence files for verification purposes
   - These include the ACME account information and certificate data
   - Evidence files are accessible through a dedicated endpoint

## Features

### Multi-Domain Support (New!)

The dstack-ingress now supports multiple domains in a single container:

- **Single Domain Mode** (backward compatible): Use `DOMAIN` and `TARGET_ENDPOINT` environment variables
- **Multi-Domain Mode**: Use `DOMAINS` environment variable with custom nginx configurations in `/etc/nginx/conf.d/`
- Each domain gets its own SSL certificate
- Flexible nginx configuration per domain

## Usage

### Prerequisites

- Host your domain on one of the supported DNS providers
- Have appropriate API credentials for your DNS provider (see [DNS Provider Configuration](DNS_PROVIDERS.md) for details)

### Deployment

You can either build the ingress container and push it to docker hub, or use the prebuilt image at `dstacktee/dstack-ingress:20250924`.

#### Option 1: Use the Pre-built Image

The fastest way to get started is to use our pre-built image. Simply use the following docker-compose configuration:

```yaml
services:
  dstack-ingress:
    image: dstacktee/dstack-ingress:20250929@sha256:2b47b3e538df0b3e7724255b89369194c8c83a7cfba64d2faf0115ad0a586458
    ports:
      - "443:443"
    environment:
      # DNS Provider
      - DNS_PROVIDER=cloudflare

      # Cloudflare example
      - CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}

      # Common configuration
      - DOMAIN=${DOMAIN}
      - GATEWAY_DOMAIN=${GATEWAY_DOMAIN}
      - CERTBOT_EMAIL=${CERTBOT_EMAIL}
      - SET_CAA=true
      - TARGET_ENDPOINT=http://app:80
    volumes:
      - /var/run/dstack.sock:/var/run/dstack.sock
      - /var/run/tappd.sock:/var/run/tappd.sock
      - cert-data:/etc/letsencrypt
    restart: unless-stopped
  app:
    image: nginx # Replace with your application image
    restart: unless-stopped
volumes:
  cert-data: # Persistent volume for certificates
```

### Multi-Domain Configuration

```yaml
services:
  ingress:
    image: dstacktee/dstack-ingress:20250929@sha256:2b47b3e538df0b3e7724255b89369194c8c83a7cfba64d2faf0115ad0a586458
    ports:
      - "443:443"
    environment:
      DNS_PROVIDER: cloudflare
      CLOUDFLARE_API_TOKEN: ${CLOUDFLARE_API_TOKEN}
      CERTBOT_EMAIL: ${CERTBOT_EMAIL}
      GATEWAY_DOMAIN: _.dstack-prod5.phala.network
      SET_CAA: true
      DOMAINS: |
        ${APP_DOMAIN}
        ${API_DOMAIN}

    volumes:
      - /var/run/tappd.sock:/var/run/tappd.sock
      - letsencrypt:/etc/letsencrypt

    configs:
      - source: app_conf
        target: /etc/nginx/conf.d/app.conf
        mode: 0444
      - source: api_conf
        target: /etc/nginx/conf.d/api.conf
        mode: 0444

    restart: unless-stopped

  app-main:
    image: nginx
    restart: unless-stopped

  app-api:
    image: nginx
    restart: unless-stopped

volumes:
  letsencrypt:

configs:
  app_conf:
    content: |
      server {
          listen 443 ssl;
          server_name ${APP_DOMAIN};
          ssl_certificate /etc/letsencrypt/live/${APP_DOMAIN}/fullchain.pem;
          ssl_certificate_key /etc/letsencrypt/live/${APP_DOMAIN}/privkey.pem;
          location / {
              proxy_pass http://app-main:80;
          }
      }
  api_conf:
    content: |
      server {
          listen 443 ssl;
          server_name ${API_DOMAIN};
          ssl_certificate /etc/letsencrypt/live/${API_DOMAIN}/fullchain.pem;
          ssl_certificate_key /etc/letsencrypt/live/${API_DOMAIN}/privkey.pem;
          location / {
              proxy_pass http://app-api:80;
          }
      }
```

**Core Environment Variables:**

- `DNS_PROVIDER`: DNS provider to use (cloudflare, linode)
- `DOMAIN`: Your custom domain (for single domain mode)
- `DOMAINS`: Multiple domains, one per line (supports environment variable substitution like `${APP_DOMAIN}`)
- `GATEWAY_DOMAIN`: The dstack gateway domain (e.g. `_.dstack-prod5.phala.network` for Phala Cloud)
- `CERTBOT_EMAIL`: Your email address used in Let's Encrypt certificate requests
- `TARGET_ENDPOINT`: The plain HTTP endpoint of your dstack application (for single domain mode)
- `SET_CAA`: Set to `true` to enable CAA record setup
- `CLIENT_MAX_BODY_SIZE`: Optional value for nginx `client_max_body_size` (numeric with optional `k|m|g` suffix, e.g. `50m`) in single-domain mode
- `PROXY_READ_TIMEOUT`: Optional value for nginx `proxy_read_timeout` (numeric with optional `s|m|h` suffix, e.g. `30s`) in single-domain mode
- `PROXY_SEND_TIMEOUT`: Optional value for nginx `proxy_send_timeout` (numeric with optional `s|m|h` suffix, e.g. `30s`) in single-domain mode
- `PROXY_CONNECT_TIMEOUT`: Optional value for nginx `proxy_connect_timeout` (numeric with optional `s|m|h` suffix, e.g. `10s`) in single-domain mode
- `PROXY_BUFFER_SIZE`: Optional value for nginx `proxy_buffer_size` (numeric with optional `k|m` suffix, e.g. `128k`) in single-domain mode
- `PROXY_BUFFERS`: Optional value for nginx `proxy_buffers` (format: `number size`, e.g. `4 256k`) in single-domain mode
- `PROXY_BUSY_BUFFERS_SIZE`: Optional value for nginx `proxy_busy_buffers_size` (numeric with optional `k|m` suffix, e.g. `256k`) in single-domain mode
- `CERTBOT_STAGING`: Optional; set this value to the string `true` to set the `--staging` server option on the [`certbot` cli](https://eff-certbot.readthedocs.io/en/stable/using.html#certbot-command-line-options)
- `ALIAS_DOMAIN`: Optional; a shared domain that acts as a load-balanced entry point across multiple Phala nodes (e.g. `app.example.com`). Each node automatically joins the upstream pool on boot — users hit one address while traffic is distributed across however many nodes are running. See [Multi-Node Weighted Routing](#multi-node-weighted-routing-with-alias_domain).

**Backward Compatibility:**

- If both `DOMAIN` and `TARGET_ENDPOINT` are set, the system operates in single-domain mode with auto-generated nginx config
- If `DOMAINS` is set, the system operates in multi-domain mode and expects custom nginx configs in `/etc/nginx/conf.d/`
- You can use both modes simultaneously

For provider-specific configuration details, see [DNS Provider Configuration](DNS_PROVIDERS.md).

#### Option 2: Build Your Own Image

If you prefer to build the image yourself:

1. Clone this repository
2. Build the Docker image using the provided build script:

```bash
./build-image.sh yourusername/dstack-ingress:tag
```

**Important**: You must use the `build-image.sh` script to build the image. This script ensures reproducible builds with:

- Specific buildkit version (v0.20.2)
- Deterministic timestamps (`SOURCE_DATE_EPOCH=0`)
- Package pinning for consistency
- Git revision tracking

Direct `docker build` commands will not work properly due to the specialized build requirements.

3. Push to your registry (optional):

```bash
docker push yourusername/dstack-ingress:tag
```

4. Update the docker-compose.yaml file with your image name and deploy

#### gRPC Support

If your dstack application uses gRPC, you can set `TARGET_ENDPOINT` to `grpc://app:50051`.

example:

```yaml
services:
  dstack-ingress:
    image: dstacktee/dstack-ingress:20250929@sha256:2b47b3e538df0b3e7724255b89369194c8c83a7cfba64d2faf0115ad0a586458
    ports:
      - "443:443"
    environment:
      - CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}
      - DOMAIN=${DOMAIN}
      - GATEWAY_DOMAIN=${GATEWAY_DOMAIN}
      - CERTBOT_EMAIL=${CERTBOT_EMAIL}
      - SET_CAA=true
      - TARGET_ENDPOINT=grpc://app:50051
    volumes:
      - /var/run/dstack.sock:/var/run/dstack.sock
      - /var/run/tappd.sock:/var/run/tappd.sock
      - cert-data:/etc/letsencrypt
    restart: unless-stopped
  app:
    image: your-grpc-app
    restart: unless-stopped
volumes:
  cert-data:
```

## Multi-Node Weighted Routing with ALIAS_DOMAIN

`ALIAS_DOMAIN` enables a pattern where multiple independent TEE nodes share a single public-facing domain via DNS weighted routing, while each node maintains its own Phala-verified identity.

### How It Works

Each node has a **node domain** (`DOMAIN`, e.g. `node1.app.example.com`) used for its individual Phala-verified identity. Issuing certificates against per-node domains also avoids Let's Encrypt's duplicate-certificate rate limits that would occur if every node requested a cert for the same shared domain. A single **public domain** (`ALIAS_DOMAIN`, e.g. `app.example.com`) is shared across all nodes as the user-facing address and is added as a SAN on each node's certificate. The Phala gateway validates traffic to the alias domain via a shared TXT record that accumulates an entry for every node in the pool — each node appends its own `APP_ID` on boot rather than replacing the existing values.

```
                         ┌─────────────────────────────────────────┐
Users                    │         Route53 Weighted CNAMEs          │
  │                      │                                          │
  └─► app.example.com ───┼──► node1.app.example.com  (weight=100) ─┼──► <appid1>.dstack.phala.network
                         │                                          │
                         └──► node2.app.example.com  (weight=0)  ──┼──► <appid2>.dstack.phala.network
                                                                    │
                         ┌─────────────────────────────────────────┘
                         │         Phala Gateway TXT Routing
                         │
                         │  _dstack-app-address.node1.app.example.com → <appid1>:443
                         │  _dstack-app-address.node2.app.example.com → <appid2>:443
                         │
                         │  _dstack-app-address.app.example.com → <appid1>:443  ← one entry per node
                         │                                         <appid2>:443  ← appended on each boot
                         │
                         │         TLS Certificate (on each node)
                         │
                         │  node1.app.example.com  ← primary
                         │  app.example.com         ← SAN
                         └─────────────────────────────────────────
```

### What dstack-ingress Does Automatically

When `ALIAS_DOMAIN` is set:

1. **Certificate** — issues a SAN cert covering both `DOMAIN` and `ALIAS_DOMAIN`, so nginx can serve TLS regardless of which hostname the client connected through.
2. **Nginx** — adds `ALIAS_DOMAIN` to `server_name` so requests arriving via the public domain are accepted.
3. **Weighted CNAME** *(Route53 only, requires `ROUTE53_INITIAL_WEIGHT`)* — creates a weighted CNAME record `ALIAS_DOMAIN → DOMAIN` at **weight 0**, registering this node in the pool without routing any traffic to it yet. The `SetIdentifier` is set to `DOMAIN` so each node occupies a unique, stable slot.

### Lifecycle

```
Node starts
    │
    ├── CNAME:   node1.app.example.com → <appid>.dstack.phala.network  (weight=ROUTE53_INITIAL_WEIGHT)
    ├── TXT:     _dstack-app-address.node1.app.example.com → <appid>:443
    ├── CNAME:   app.example.com → node1.app.example.com               (weight=0)  ← new node, dark
    └── CERT:    node1.app.example.com + app.example.com (SAN)

Operator promotes node
    └── Update Route53: app.example.com → node1.app.example.com weight 0 → desired weight
```

The node is fully provisioned and verified before receiving any user traffic. Traffic is enabled by a deliberate operator action (bumping the weight in Route53), not automatically.

### Configuration

| Variable | Required | Description |
|---|---|---|
| `ALIAS_DOMAIN` | No | Public-facing domain shared across nodes (e.g. `app.example.com`) |
| `ROUTE53_INITIAL_WEIGHT` | No | Weight for this node's primary CNAME. When combined with `ALIAS_DOMAIN`, also triggers creation of the weight-0 CNAME for the public domain. |

For a complete production-ready reference that includes a dynamic nginx upstream manager (automatically enrolling and unenrolling backend containers as they start and stop), see [`docker-compose.loadbalanced.yaml`](docker-compose.loadbalanced.yaml) in this repository. For full DNS configuration details, see [DNS Provider Configuration](DNS_PROVIDERS.md#weighted-routing-with-alias_domain-route53).

## Domain Attestation and Verification

The dstack-ingress system provides mechanisms to verify and attest that your custom domain endpoint is secure and properly configured. This comprehensive verification approach ensures the integrity and authenticity of your application.

### Evidence Collection

When certificates are issued or renewed, the system automatically generates a set of cryptographically linked evidence files:

1. **Access Evidence Files**:

   - Evidence files are accessible at `https://your-domain.com/evidences/`
   - Key files include `acme-account.json`, `cert.pem`, `sha256sum.txt`, and `quote.json`

2. **Verification Chain**:

   - `quote.json` contains a TDX quote with the SHA-256 digest of `sha256sum.txt` embedded in the report_data field
   - `sha256sum.txt` contains cryptographic checksums of both `acme-account.json` and `cert.pem`
   - When the TDX quote is verified, it cryptographically proves the integrity of the entire evidence chain

3. **Certificate Authentication**:
   - `acme-account.json` contains the ACME account credentials used to request certificates
   - When combined with the CAA DNS record, this provides evidence that certificates can only be requested from within this specific TEE application
   - `cert.pem` is the Let's Encrypt certificate currently serving your custom domain

### CAA Record Verification

If you've enabled CAA records (`SET_CAA=true`), you can verify that only authorized Certificate Authorities can issue certificates for your domain:

```bash
dig CAA your-domain.com
```

The output will display CAA records that restrict certificate issuance exclusively to Let's Encrypt with your specific account URI, providing an additional layer of security.

### TLS Certificate Transparency

All Let's Encrypt certificates are logged in public Certificate Transparency (CT) logs, enabling independent verification:

**CT Log Verification**:

- Visit [crt.sh](https://crt.sh/) and search for your domain
- Confirm that the certificates match those issued by the dstack-ingress system
- This public logging ensures that all certificates are visible and can be monitored for unauthorized issuance

## License

MIT License

Copyright (c) 2025

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
