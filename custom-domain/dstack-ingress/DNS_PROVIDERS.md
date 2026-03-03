# DNS Provider Configuration Guide

This guide explains how to configure dstack-ingress to work with different DNS providers for managing custom domains and SSL certificates.

## Supported DNS Providers

- **Cloudflare** - The original and default provider
- **Linode DNS** - For Linode-hosted domains
- **Namecheap** - For Namecheap-hosted domains
- **Route53** - For AWS hosted domains

## Environment Variables

### Common Variables (Required for all providers)

- `DOMAIN` - Your node-specific domain (e.g., `node1.app.example.com`)
- `GATEWAY_DOMAIN` - dstack gateway domain (e.g., `_.dstack-prod5.phala.network`)
- `CERTBOT_EMAIL` - Email for Let's Encrypt registration
- `TARGET_ENDPOINT` - Backend application endpoint to proxy to
- `DNS_PROVIDER` - DNS provider to use (`cloudflare`, `linode`, `namecheap`, `route53`)

### Optional Variables

- `SET_CAA` - Enable CAA record setup (default: false)
- `PORT` - HTTPS port (default: 443)
- `TXT_PREFIX` - Prefix for TXT records (default: "_tapp-address")
- `ALIAS_DOMAIN` - Public-facing domain shared across multiple nodes (e.g., `app.example.com`). Added as a SAN on the TLS certificate and to nginx `server_name`. When set alongside `ROUTE53_INITIAL_WEIGHT` (Route53 only), also creates a weight-0 weighted CNAME `ALIAS_DOMAIN → DOMAIN` to register this node in the pool without routing traffic to it. See [Weighted Routing with ALIAS_DOMAIN](#weighted-routing-with-alias_domain-route53).

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
- `ROUTE53_INITIAL_WEIGHT` - Enables [Weighted Routing](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-policy-weighted.html) on the CNAME record created for `DOMAIN` (e.g. `node1.app.example.com → phala gateway`). Set to an integer (e.g., `100`) to assign that weight to the record. A unique `SetIdentifier` is generated automatically. TXT records are never weighted. Omit to create a standard non-weighted CNAME. When `ALIAS_DOMAIN` is also set, this variable additionally triggers creation of a weight-0 weighted CNAME `ALIAS_DOMAIN → DOMAIN` — see below.
- `ALIAS_DOMAIN` - See [Weighted Routing with ALIAS_DOMAIN](#weighted-routing-with-alias_domain-route53).

**Important Notes for Route53:**
- The certbot plugin uses the `certbot-dns-route53` package
- CAA will merge AWS & Let's Encrypt CA domains into existing records if they exist
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

### Route53 Example (single node, no weighted routing)

```yaml
services:
  dstack-ingress:
    image: dstacktee/dstack-ingress:20250929@sha256:2b47b3e538df0b3e7724255b89369194c8c83a7cfba64d2faf0115ad0a586458
    restart: unless-stopped
    volumes:
      - /var/run/tappd.sock:/var/run/tappd.sock
      - cert-data:/etc/letsencrypt
    ports:
      - "443:443"
    environment:
      DNS_PROVIDER: route53
      DOMAIN: app.example.com
      GATEWAY_DOMAIN: _.dstack-prod5.phala.network

      AWS_REGION: ${AWS_REGION}
      AWS_ROLE_ARN: ${AWS_ROLE_ARN}
      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}

      CERTBOT_EMAIL: ${CERTBOT_EMAIL}
      TARGET_ENDPOINT: http://backend:8080
      SET_CAA: 'true'
volumes:
  cert-data:
```

For multi-node weighted routing, see [Weighted Routing with ALIAS_DOMAIN](#weighted-routing-with-alias_domain-route53).

## Weighted Routing with ALIAS_DOMAIN (Route53)

This pattern lets you run multiple independent TEE nodes behind a single public domain using Route53 weighted routing. Each node manages its own Phala identity (TXT record, CNAME to gateway) while also being registered as a weighted target for the shared public domain.

### DNS Record Layout

```
Public domain (shared across nodes)
────────────────────────────────────────────────────────────────
  app.example.com  CNAME  node1.app.example.com  weight=100  id=node1.app.example.com
  app.example.com  CNAME  node2.app.example.com  weight=0    id=node2.app.example.com  ← new, dark

Per-node records (managed by each node's dstack-ingress)
────────────────────────────────────────────────────────────────
  node1.app.example.com   CNAME  <appid1>.dstack-prod5.phala.network  weight=100
  node2.app.example.com   CNAME  <appid2>.dstack-prod5.phala.network  weight=100

  _dstack-app-address.node1.app.example.com  TXT  <appid1>:443
  _dstack-app-address.node2.app.example.com  TXT  <appid2>:443

TLS certificate (on each node)
────────────────────────────────────────────────────────────────
  Subject:  node1.app.example.com
  SAN:      app.example.com
```

### Variable Interactions

| `ALIAS_DOMAIN` | `ROUTE53_INITIAL_WEIGHT` | Cert SAN | Nginx server_name | Weight-0 CNAME for ALIAS_DOMAIN |
|---|---|---|---|---|
| not set | any | no | no | no |
| set | not set | yes | yes | no |
| set | set | yes | yes | yes |

### Node Startup Sequence

When a new node starts with both variables set, dstack-ingress performs these steps automatically:

```
1. CNAME  node2.app.example.com → <appid2>.dstack.phala.network  (weighted, ROUTE53_INITIAL_WEIGHT)
2. TXT    _dstack-app-address.node2.app.example.com → <appid2>:443
3. CNAME  app.example.com → node2.app.example.com                (weight=0, SetIdentifier=node2.app.example.com)
4. Obtain TLS cert for node2.app.example.com + app.example.com (SAN)
```

The node is fully verified and ready before step 3 introduces it to the pool. Traffic only starts flowing after an operator explicitly sets the weight above 0 in Route53.

### Docker Compose Example (weighted, two-node setup)

Node 1 (`node1.app.example.com`):

```yaml
services:
  dstack-ingress:
    image: dstacktee/dstack-ingress:20250929@sha256:2b47b3e538df0b3e7724255b89369194c8c83a7cfba64d2faf0115ad0a586458
    restart: unless-stopped
    ports:
      - "443:443"
    environment:
      DNS_PROVIDER: route53
      DOMAIN: node1.app.example.com
      ALIAS_DOMAIN: app.example.com
      GATEWAY_DOMAIN: _.dstack-prod5.phala.network
      CERTBOT_EMAIL: ${CERTBOT_EMAIL}
      TARGET_ENDPOINT: http://app:80
      SET_CAA: 'true'
      ROUTE53_INITIAL_WEIGHT: '100'

      AWS_REGION: ${AWS_REGION}
      AWS_ROLE_ARN: ${AWS_ROLE_ARN}
      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}
    volumes:
      - /var/run/tappd.sock:/var/run/tappd.sock
      - cert-data:/etc/letsencrypt
volumes:
  cert-data:
```

Node 2 (`node2.app.example.com`) uses identical config with `DOMAIN: node2.app.example.com`. On first boot it registers itself at weight 0. To promote it, update the record weight in Route53.

### Important Notes

- The weight-0 CNAME for `ALIAS_DOMAIN` uses `DOMAIN` as the `SetIdentifier`, so each node has a stable, unique slot in the weighted record set that survives restarts without creating duplicates.
- For non-Route53 providers (Cloudflare, Linode, Namecheap), `ALIAS_DOMAIN` still adds the SAN and updates nginx, but those providers do not support weighted CNAME records at the DNS level. You would need to manage traffic distribution through the provider's own load balancing features.
- `ALIAS_DOMAIN` must be in the same Route53 hosted zone as `DOMAIN`, or at least a zone your credentials can write to.

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
