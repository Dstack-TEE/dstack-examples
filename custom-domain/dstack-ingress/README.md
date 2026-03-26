# dstack-ingress

TCP proxy with automatic TLS termination for dstack applications.

## Overview

dstack-ingress is a HAProxy-based L4 (TCP) proxy that provides:

- Automatic SSL certificate provisioning and renewal via Let's Encrypt
- Multi-provider DNS support (Cloudflare, Linode DNS, Namecheap)
- Pure TCP proxying — all protocols (HTTP, WebSocket, gRPC, arbitrary TCP) work transparently
- Wildcard domain support
- SNI-based multi-domain routing
- Certificate evidence generation for TEE attestation verification
- Strong TLS configuration (TLS 1.2+, AES-GCM, ChaCha20-Poly1305)

## How It Works

1. **Bootstrap**: On first start, obtains SSL certificates from Let's Encrypt using DNS-01 validation and configures DNS records (CNAME, TXT, optional CAA).

2. **TLS Termination**: HAProxy terminates TLS and forwards the decrypted TCP stream to your backend. No HTTP inspection — the proxy operates entirely at L4.

3. **Certificate Renewal**: A background daemon checks for renewal every 12 hours. On renewal, HAProxy is gracefully reloaded with zero downtime.

4. **Evidence Generation**: Generates cryptographically linked attestation evidence (ACME account, certificates, TDX quote) for TEE verification.

### Wildcard Domain Support

You can use a wildcard domain (e.g. `*.myapp.com`) to route all subdomains to a single dstack application:

- The TXT record is automatically set as `_dstack-app-address-wildcard.myapp.com` (instead of `_dstack-app-address.*.myapp.com`)
- CAA records use the `issuewild` tag on the base domain
- Requires dstack-gateway with wildcard TXT resolution support ([dstack#545](https://github.com/Dstack-TEE/dstack/pull/545))

```yaml
services:
  dstack-ingress:
    image: dstacktee/dstack-ingress:latest
    ports:
      - "443:443"
    environment:
      - CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}
      - DOMAIN=*.myapp.com
      - GATEWAY_DOMAIN=_.dstack-prod5.phala.network
      - CERTBOT_EMAIL=${CERTBOT_EMAIL}
      - SET_CAA=true
      - TARGET_ENDPOINT=http://app:80
    volumes:
      - /var/run/dstack.sock:/var/run/dstack.sock
      - /var/run/tappd.sock:/var/run/tappd.sock
      - cert-data:/etc/letsencrypt
    restart: unless-stopped
  app:
    image: nginx
    restart: unless-stopped
volumes:
  cert-data:
```

## Usage

### Single Domain

```yaml
services:
  dstack-ingress:
    image: dstacktee/dstack-ingress:latest
    ports:
      - "443:443"
    environment:
      - DNS_PROVIDER=cloudflare
      - CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}
      - DOMAIN=${DOMAIN}
      - GATEWAY_DOMAIN=${GATEWAY_DOMAIN}
      - CERTBOT_EMAIL=${CERTBOT_EMAIL}
      - SET_CAA=true
      - TARGET_ENDPOINT=app:80
    volumes:
      - /var/run/dstack.sock:/var/run/dstack.sock
      - /var/run/tappd.sock:/var/run/tappd.sock
      - cert-data:/etc/letsencrypt
      - evidences:/evidences
    restart: unless-stopped

  app:
    image: your-app
    volumes:
      - evidences:/evidences:ro
    restart: unless-stopped

volumes:
  cert-data:
  evidences:
```

`TARGET_ENDPOINT` accepts bare `host:port` (preferred) or with protocol prefix (`http://app:80`, `grpc://app:50051`). The protocol prefix is stripped — HAProxy forwards raw TCP regardless of protocol.

### Multi-Domain with Routing

Use `ROUTING_MAP` to route different domains to different backends via SNI:

```yaml
services:
  ingress:
    image: dstacktee/dstack-ingress:latest
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
      ROUTING_MAP: |
        ${APP_DOMAIN}=app-main:80
        ${API_DOMAIN}=app-api:8080
    volumes:
      - /var/run/tappd.sock:/var/run/tappd.sock
      - letsencrypt:/etc/letsencrypt
      - evidences:/evidences
    restart: unless-stopped

  app-main:
    image: nginx
    volumes:
      - evidences:/evidences:ro
    restart: unless-stopped

  app-api:
    image: your-api
    volumes:
      - evidences:/evidences:ro
    restart: unless-stopped

volumes:
  letsencrypt:
  evidences:
```

### Wildcard Domains

Wildcard certificates work out of the box with DNS-01 validation:

```yaml
environment:
  - DOMAIN=*.example.com
  - TARGET_ENDPOINT=app:80
```

## Environment Variables

### Required

| Variable | Description |
|----------|-------------|
| `DOMAIN` | Your domain (single-domain mode). Supports wildcards (`*.example.com`) |
| `TARGET_ENDPOINT` | Backend address, e.g. `app:80` or `http://app:80` |
| `GATEWAY_DOMAIN` | dstack gateway domain (e.g. `_.dstack-prod5.phala.network`) |
| `CERTBOT_EMAIL` | Email for Let's Encrypt registration |
| `DNS_PROVIDER` | DNS provider (`cloudflare`, `linode`, `namecheap`) |

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `443` | HAProxy listen port |
| `DOMAINS` | | Multiple domains, one per line |
| `ROUTING_MAP` | | Multi-domain routing: `domain=host:port` per line |
| `SET_CAA` | `false` | Enable CAA DNS record |
| `TXT_PREFIX` | `_dstack-app-address` | DNS TXT record prefix |
| `CERTBOT_STAGING` | `false` | Use Let's Encrypt staging server |
| `MAXCONN` | `4096` | HAProxy max connections |
| `TIMEOUT_CONNECT` | `10s` | Backend connect timeout |
| `TIMEOUT_CLIENT` | `86400s` | Client-side timeout (24h for long-lived connections) |
| `TIMEOUT_SERVER` | `86400s` | Server-side timeout |
| `EVIDENCE_SERVER` | `true` | Serve evidence files at `/evidences/` on the TLS port |
| `EVIDENCE_PORT` | `80` | Internal port for evidence HTTP server |

For DNS provider credentials, see [DNS_PROVIDERS.md](DNS_PROVIDERS.md).

## Evidence & Attestation

Evidence files are served at `https://your-domain.com/evidences/` by default (via payload inspection in HAProxy's TCP mode). They can also be accessed by the backend application through the shared `/evidences` volume.

To disable the built-in evidence endpoint and serve evidence files only through your backend, set `EVIDENCE_SERVER=false`.

### Evidence Files

| File | Description |
|------|-------------|
| `acme-account.json` | ACME account used to request certificates |
| `cert-{domain}.pem` | Let's Encrypt certificate for each domain |
| `sha256sum.txt` | SHA-256 checksums of all evidence files |
| `quote.json` | TDX quote with `sha256sum.txt` digest in report_data |

### Verification Chain

1. Verify the TDX quote in `quote.json`
2. Extract `report_data` — it contains the SHA-256 of `sha256sum.txt`
3. Verify checksums in `sha256sum.txt` against `acme-account.json` and `cert-*.pem`
4. This proves the certificates were obtained within the TEE

## Building

```bash
./build-image.sh
# Or push directly:
./build-image.sh --push yourusername/dstack-ingress:tag
```

The build script ensures reproducibility via pinned packages, deterministic timestamps, and specific buildkit version.

## License

MIT License

Copyright (c) 2025

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
