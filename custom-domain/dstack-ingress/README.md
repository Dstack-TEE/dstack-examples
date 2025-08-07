# Custom Domain Setup for dstack Applications

This repository provides a solution for setting up custom domains with automatic SSL certificate management for dstack applications using Cloudflare DNS and Let's Encrypt.

## Overview

This project enables you to run dstack applications with your own custom domain, complete with:

- Automatic SSL certificate provisioning and renewal via Let's Encrypt
- Cloudflare DNS configuration for CNAME, TXT, and CAA records
- Nginx reverse proxy to route traffic to your application
- Certificate evidence generation for verification
- Strong SSL/TLS configuration with modern cipher suites (AES-GCM and ChaCha20-Poly1305)

## How It Works

The dstack-ingress system provides a seamless way to set up custom domains for dstack applications with automatic SSL certificate management. Here's how it works:

1. **Initial Setup**:
   - When first deployed, the container automatically obtains SSL certificates from Let's Encrypt using DNS validation
   - It configures Cloudflare DNS by creating necessary CNAME, TXT, and optional CAA records
   - Nginx is configured to use the obtained certificates and proxy requests to your application

2. **DNS Configuration**:
   - A CNAME record is created to point your custom domain to the dstack gateway domain
   - A TXT record is added with application identification information to help dstack-gateway to route traffic to your application
   - If enabled, CAA records are set to restrict which Certificate Authorities can issue certificates for your domain

3. **Certificate Management**:
   - SSL certificates are automatically obtained during initial setup
   - A scheduled task runs twice daily to check for certificate renewal
   - When certificates are renewed, Nginx is automatically reloaded to use the new certificates

4. **Evidence Generation**:
   - The system generates evidence files for verification purposes
   - These include the ACME account information and certificate data
   - Evidence files are accessible through a dedicated endpoint

## Usage

### Prerequisites

- Host your domain on Cloudflare and have access to the Cloudflare account with API token

### Deployment

You can either build the ingress container and push it to docker hub, or use the prebuilt image at `kvin/dstack-ingress`.

#### Option 1: Use the Pre-built Image

The fastest way to get started is to use our pre-built image. Simply use the following docker-compose configuration:

```yaml
services:
  dstack-ingress:
    image: kvin/dstack-ingress@sha256:b61d50360c7a4e5ab7d22f5ce87677714f3f64a65db34ee5eebcc54683950c89
    ports:
      - "443:443"
    environment:
      - CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}
      - DOMAIN=${DOMAIN}
      - GATEWAY_DOMAIN=${GATEWAY_DOMAIN}
      - CERTBOT_EMAIL=${CERTBOT_EMAIL}
      - SET_CAA=true
      - TARGET_ENDPOINT=http://app:80
    volumes:
      - /var/run/tappd.sock:/var/run/tappd.sock
      - cert-data:/etc/letsencrypt
    restart: unless-stopped
  app:
    image: nginx  # Replace with your application image
    restart: unless-stopped
volumes:
  cert-data:  # Persistent volume for certificates
```

Explanation of environment variables:

- `CLOUDFLARE_API_TOKEN`: Your Cloudflare API token
- `DOMAIN`: Your custom domain
- `GATEWAY_DOMAIN`: The dstack gateway domain. (e.g. `_.dstack-prod5.phala.network` for Phala Cloud)
- `CERTBOT_EMAIL`: Your email address used in Let's Encrypt certificate requests
- `TARGET_ENDPOINT`: The plain HTTP endpoint of your dstack application
- `SET_CAA`: Set to `true` to enable CAA record setup

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
    image: kvin/dstack-ingress@sha256:b61d50360c7a4e5ab7d22f5ce87677714f3f64a65db34ee5eebcc54683950c89
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
      - /var/run/tappd.sock:/var/run/tappd.sock
      - cert-data:/etc/letsencrypt
    restart: unless-stopped
  app:
    image: your-grpc-app
    restart: unless-stopped
volumes:
  cert-data:
```

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
