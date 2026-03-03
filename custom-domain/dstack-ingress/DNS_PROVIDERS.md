# DNS Provider Configuration Guide

This guide explains how to configure dstack-ingress to work with different DNS providers for managing custom domains and SSL certificates.

## Supported DNS Providers

- **Cloudflare** - The original and default provider
- **Linode DNS** - For Linode-hosted domains
- **Namecheap** - For Namecheap-hosted domains
- **Route53** - For AWS hosted domains

## Environment Variables

### Common Variables (Required for all providers)

- `DOMAIN` - Your custom domain (e.g., `app.example.com`)
- `GATEWAY_DOMAIN` - dstack gateway domain (e.g., `_.dstack-prod5.phala.network`)
- `CERTBOT_EMAIL` - Email for Let's Encrypt registration
- `TARGET_ENDPOINT` - Backend application endpoint to proxy to
- `DNS_PROVIDER` - DNS provider to use (`cloudflare`, `linode`, `namecheap`)

### Optional Variables

- `SET_CAA` - Enable CAA record setup (default: false)
- `PORT` - HTTPS port (default: 443)
- `TXT_PREFIX` - Prefix for TXT records (default: "_tapp-address")

## Provider-Specific Configuration

### Cloudflare

```bash
DNS_PROVIDER=cloudflare
CLOUDFLARE_API_TOKEN=your-api-token
```

**Required Permissions:**
- Zone:Read
- DNS:Edit

### Linode DNS

```bash
DNS_PROVIDER=linode
LINODE_API_TOKEN=your-api-token
```

**Required Permissions:**
- Domains: Read/Write access

**Important Note for Linode:**
- Linode has a limitation where CAA and CNAME records cannot coexist on the same subdomain
- To work around this, the system will attempt to use A records instead of CNAME records
- If the gateway domain can be resolved to an IP, an A record will be created
- If resolution fails, it falls back to CNAME (but CAA records won't work on that subdomain)
- This is a Linode-specific limitation not present in other providers

### Namecheap

```bash
DNS_PROVIDER=namecheap
NAMECHEAP_USERNAME=your-username
NAMECHEAP_API_KEY=your-api-key
NAMECHEAP_CLIENT_IP=your-client-ip
```

**Required Credentials:**
- `NAMECHEAP_USERNAME` - Your Namecheap account username
- `NAMECHEAP_API_KEY` - Your Namecheap API key (from https://ap.www.namecheap.com/settings/tools/apiaccess/)
- `NAMECHEAP_CLIENT_IP` - The IP address of the node (required for Namecheap API authentication)

**Important Notes for Namecheap:**
- Namecheap API requires node IP address for authentication, and you need add it to whitelist IP first.
- Namecheap doesn't support CAA records through their API currently
- The certbot plugin uses the format `certbot-dns-namecheap` package

### Route53

```bash
DNS_PROVIDER=route53
AWS_ACCESS_KEY_ID=service-account-key-that-can-assume-role
AWS_SECRET_ACCESS_KEY=service-account-secret-that-can-assume-role
AWS_ROLE_ARN=role-that-can-mod-route53
AWS_REGION=your-closest-region
```

**Required Permissions:**
```yaml
PolicyDocument:
  Version: '2012-10-17'
  Statement:
    - Sid: AllowDnsChallengeChanges
      Effect: Allow
      Action:
        - route53:ChangeResourceRecordSets
      Resource: !Sub arn:aws:route53:::hostedzone/${HostedZoneId}
    - Sid: AllowListingForDnsChallenge
      Effect: Allow
      Action:
        - route53:ListHostedZonesByName
        - route53:ListHostedZones
        - route53:GetChange
        - route53:ListResourceRecordSets
```

**Optional Variables for Route53:**
- `ROUTE53_INITIAL_WEIGHT` - Enables [Weighted Routing](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-policy-weighted.html) on the CNAME record created for your domain. Set to an integer (e.g., `100`) to assign that weight to the record. A unique `SetIdentifier` is generated automatically. TXT records (used for Certbot DNS challenges) are never weighted. Omit this variable to create a standard non-weighted CNAME record.

**Important Notes for Route53:**
- The certbot plugin uses the format `certbot-dns-route53` package
- CAA will merge AWS & Let's Encrypt CA domains to existing records if they exist
- It is essential that the AWS service account used can only assume the limited role. See cloudformation example.

## Docker Compose Examples

### Linode Example

```yaml
version: '3.8'

services:
  ingress:
    image: dstack-ingress:latest
    ports:
      - "443:443"
    environment:
      # Common configuration
      - DNS_PROVIDER=linode
      - DOMAIN=app.example.com
      - GATEWAY_DOMAIN=_.dstack-prod5.phala.network
      - CERTBOT_EMAIL=admin@example.com
      - TARGET_ENDPOINT=http://backend:8080

      # Linode specific
      - LINODE_API_TOKEN=your-api-token
    volumes:
      - ./letsencrypt:/etc/letsencrypt
      - ./evidences:/evidences
```

### Namecheap Example

```yaml
version: '3.8'

services:
  ingress:
    image: dstack-ingress:latest
    ports:
      - "443:443"
    environment:
      # Common configuration
      - DNS_PROVIDER=namecheap
      - DOMAIN=app.example.com
      - GATEWAY_DOMAIN=_.dstack-prod5.phala.network
      - CERTBOT_EMAIL=admin@example.com
      - TARGET_ENDPOINT=http://backend:8080

      # Namecheap specific
      - NAMECHEAP_USERNAME=your-username
      - NAMECHEAP_API_KEY=your-api-key
      - NAMECHEAP_CLIENT_IP=your-public-ip
    volumes:
      - ./letsencrypt:/etc/letsencrypt
      - ./evidences:/evidences
```

### Route53 Example

```yaml
services:
  dstack-ingress:
    image: dstack-ingress:latest
    restart: unless-stopped
    volumes:
    - /var/run/dstack.sock:/var/run/dstack.sock
    - cert-data:/etc/letsencrypt
    ports:
    - 443:443
    environment:
      DNS_PROVIDER: route53
      DOMAIN: app.example.com
      GATEWAY_DOMAIN: _.${DSTACK_GATEWAY_DOMAIN}

      AWS_REGION: ${AWS_REGION}
      AWS_ROLE_ARN: ${AWS_ROLE_ARN}
      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}

      CERTBOT_EMAIL: ${CERTBOT_EMAIL}
      TARGET_ENDPOINT: http://backend:8080
      SET_CAA: 'true'

```

## Migration from Cloudflare-only Setup

If you're currently using the Cloudflare-only version:

1. **No changes needed for Cloudflare users** - The default behavior remains Cloudflare
2. **For other providers** - Add the `DNS_PROVIDER` environment variable and provider-specific credentials

## Troubleshooting

### DNS Provider Detection

If you see "Could not detect DNS provider type", ensure you have either:
- Set `DNS_PROVIDER` environment variable explicitly, OR
- Set provider-specific credential environment variables (e.g., `CLOUDFLARE_API_TOKEN`)

### Certificate Generation Issues

Different providers may have different propagation times. The default is 120 seconds, but you may need to adjust based on your provider's behavior.

### Permission Errors

Ensure your API tokens/credentials have the necessary permissions listed above for your provider.

## API Token Generation

### Cloudflare
1. Go to https://dash.cloudflare.com/profile/api-tokens
2. Create token with Zone:Read and DNS:Edit permissions
3. Scope to specific zones if desired

### Linode
1. Go to https://cloud.linode.com/profile/tokens
2. Create a Personal Access Token
3. Grant "Domains" Read/Write access

### Namecheap
1. Go to https://ap.www.namecheap.com/settings/tools/api-access/
2. Enable API access for your account
3. Note down your API key and username
4. Make sure your IP address is whitelisted in the API settings
