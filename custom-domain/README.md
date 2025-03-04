# Custom Domain

This example demonstrates how to setup custom domains that points to a service running in Tapp behind a Tproxy.

## Overview

This setup allows you to:
1. Create and automatically renew SSL certificates for your custom domain
2. Set up a CNAME record in Cloudflare pointing your custom domain to the Tproxy server
3. Serve a simple HTML page over HTTPS

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
