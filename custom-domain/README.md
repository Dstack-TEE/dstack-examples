# Custom Domain

This example demonstrates how to setup custom domains that point to a service running in a Tapp behind a Tproxy.

## Overview

This setup allows you to:
1. Create and automatically renew SSL certificates for your custom domain
2. Set up a CNAME record in Cloudflare for your custom domain pointing to the Tproxy server
3. Set up a TXT record in Cloudflare for your custom domain pointing to the destination App address and port.
4. Serve a simple HTML page in the destination App over HTTPS

### Note on Tproxy trust model and CA Authorization
This example points your custom domain to a Tproxy domain, which means that the Tproxy domain owner or its host owner will have the opportunity to request certificates for your custom domain through HTTP-01 challenge.
To avoid this situation, please set up [CAA](https://letsencrypt.org/docs/caa/) for your domain to prohibit CA authorities from using challenges other than DNS-01.

### Note on Cloudflare
Cloudflare is used here just as an example DNS service with an API. You could adapt this to whatever you use for managing your domain name.

## Environment Variables

The following environment variables must be set before running the service:

| Variable | Description |
|----------|-------------|
| `DOMAIN` | Your custom domain that used to access the example service |
| `TPROXY_DOMAIN` | The domain of the Tproxy server (e.g., `tproxy.dstack-prod2.phala.network`) that your instance is using |
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token with permissions to edit DNS records for your zone |
| `CLOUDFLARE_ZONE_ID` | The Zone ID for your domain in Cloudflare |
| `CERTBOT_EMAIL` | Email address used for Let's Encrypt certificate registration |

## Usage

Deploy the docker compose file to your dstack instance or Phala Cloud with the required environment variables.

Wait for the service to start and access your domain in the browser. You should see a "Hello" page.
