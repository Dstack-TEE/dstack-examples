# DNS Provider Configuration Guide

This guide explains how to configure dstack-ingress to work with different DNS providers for managing custom domains and SSL certificates.

## Supported DNS Providers

- **Cloudflare** - The original and default provider
- **Linode DNS** - For Linode-hosted domains
- **Namecheap** - For Namecheap-hosted domains
- **Route53** - For AWS hosted domains

## Environment Variables

### Common Variables (Required for all providers)

- `DOMAIN` or `DOMAINS` - Your custom domain(s) (e.g., `app.example.com`)
- `GATEWAY_DOMAIN` - dstack gateway domain (e.g., `gateway.dstack-prod5.phala.network`)
- `TARGET_ENDPOINT` - Backend application endpoint to proxy to, unless `ROUTING_MAP` is set

### Optional Variables

- `DNS_PROVIDER` - DNS provider to use (`cloudflare`, `linode`, `namecheap`, `route53`). Detected from the provider's credential variable when unset; set it explicitly for `route53`
- `ACME_EMAIL` - Contact address for the ACME account (`CERTBOT_EMAIL` still works). Published in the evidence, so leave it unset unless you want one
- `SET_CAA` - Enable CAA record setup: `true` or `false` (default `false`; `true` with `DELEGATION_ZONE`). Except on Cloudflare, this makes a non-wildcard domain's pointer an A record; see the README
- `PORT` - HTTPS port (default: 443)
- `TXT_PREFIX` - Prefix for TXT records (default: "_dstack-app-address")

See the [README](README.md#environment-variables) for the full list.

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
- To work around this, the system uses A records instead of CNAME records
- The gateway domain is resolved to an IP and an A record is created for it
- If resolution fails, the alias step fails and the existing records are left untouched
- Route53 refuses the pair too, and on every provider except Cloudflare a name that carries a CAA gets an A record. Linode is the one that uses an A record even without a CAA

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
- `NAMECHEAP_CLIENT_IP` - The IP address of the node, whitelisted for the Namecheap API. Defaults to `127.0.0.1`, which Namecheap rejects, so set it
- `NAMECHEAP_SANDBOX` - Set to `true` to use the Namecheap sandbox API (default: false)

**Important Notes for Namecheap:**
- Namecheap API requires node IP address for authentication, and you need add it to whitelist IP first.
- Every record write goes through `setHosts`, which replaces the whole zone. The zone is read first and written back with only the intended change, including its `EmailType`; if the read fails, nothing is written.
- With `SET_CAA=true` on a non-wildcard domain, or any CAA already at the name, the pointer is an A record instead of a CNAME.
- The zone is taken to be the last two labels of the name, so domains under a public suffix like `co.uk` are not supported.
- The certbot plugin uses the format `certbot-dns-namecheap` package

### Route53

```bash
DNS_PROVIDER=route53
AWS_ACCESS_KEY_ID=service-account-key-that-can-assume-role
AWS_SECRET_ACCESS_KEY=service-account-secret-that-can-assume-role
AWS_ROLE_ARN=role-that-can-mod-route53
AWS_REGION=your-closest-region   # default: us-east-1
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
      Resource: "*"
```

**Important Notes for Route53:**
- The certbot plugin uses the format `certbot-dns-route53` package
- CAA values are merged into the existing record set at the name: only values with the same tag are replaced, so `iodef` and other tags are kept
- Where a CAA record shares the name (`SET_CAA=true` under `DELEGATION_ZONE`, where it is the default, or on a non-wildcard domain, or any CAA already there), the gateway pointer is an A record to the resolved gateway IP instead of a CNAME, replacing any CNAME or AAAA in the same change. It is refreshed every `RENEW_INTERVAL`
- Wildcard record names are listed by Route53 as `\052.<domain>`; they are matched as `*.<domain>`
- It is essential that the AWS service account used can only assume the limited role. See cloudformation example.

## Docker Compose Examples

### Linode Example

```yaml
services:
  ingress:
    image: ghcr.io/dstack-tee/dstack-ingress:<version>
    ports:
      - "443:443"
    environment:
      # Common configuration
      - DNS_PROVIDER=linode
      - DOMAIN=app.example.com
      - GATEWAY_DOMAIN=gateway.dstack-prod5.phala.network
      - CERTBOT_EMAIL=admin@example.com
      - TARGET_ENDPOINT=http://backend:8080

      # Linode specific
      - LINODE_API_TOKEN=your-api-token
    volumes:
      - /var/run/dstack.sock:/var/run/dstack.sock
      - ./letsencrypt:/etc/letsencrypt
      - ./evidences:/evidences
```

### Namecheap Example

```yaml
services:
  ingress:
    image: ghcr.io/dstack-tee/dstack-ingress:<version>
    ports:
      - "443:443"
    environment:
      # Common configuration
      - DNS_PROVIDER=namecheap
      - DOMAIN=app.example.com
      - GATEWAY_DOMAIN=gateway.dstack-prod5.phala.network
      - CERTBOT_EMAIL=admin@example.com
      - TARGET_ENDPOINT=http://backend:8080

      # Namecheap specific
      - NAMECHEAP_USERNAME=your-username
      - NAMECHEAP_API_KEY=your-api-key
      - NAMECHEAP_CLIENT_IP=your-public-ip
    volumes:
      - /var/run/dstack.sock:/var/run/dstack.sock
      - ./letsencrypt:/etc/letsencrypt
      - ./evidences:/evidences
```

### Route53 Example

```yaml
services:
  dstack-ingress:
    image: ghcr.io/dstack-tee/dstack-ingress:<version>
    restart: unless-stopped
    volumes:
    - /var/run/dstack.sock:/var/run/dstack.sock
    - cert-data:/etc/letsencrypt
    ports:
    - 443:443
    environment:
      DNS_PROVIDER: route53
      DOMAIN: app.example.com
      GATEWAY_DOMAIN: gateway.${DSTACK_GATEWAY_DOMAIN}

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

Different providers may have different propagation times. certbot waits 120 seconds after writing the challenge record (300 for Linode); Route53 instead waits until the change has synced. With `DELEGATION_ZONE`, the wait is `DELEGATION_PROPAGATION_SECONDS`.

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
