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
    image: dstacktee/dstack-ingress:2.3@sha256:527c53523b9226782a11dbd800a3ff55e8a1f0b88e6224e8f7e4db7419769fbe
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
    image: dstacktee/dstack-ingress:2.3@sha256:527c53523b9226782a11dbd800a3ff55e8a1f0b88e6224e8f7e4db7419769fbe
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
    image: dstacktee/dstack-ingress:2.3@sha256:527c53523b9226782a11dbd800a3ff55e8a1f0b88e6224e8f7e4db7419769fbe
    ports:
      - "443:443"
    environment:
      DNS_PROVIDER: cloudflare
      CLOUDFLARE_API_TOKEN: ${CLOUDFLARE_API_TOKEN}
      CERTBOT_EMAIL: ${CERTBOT_EMAIL}
      GATEWAY_DOMAIN: _.dstack-prod5.phala.network
      SET_CAA: true
      DOMAINS: |
        app.example.com
        api.example.com
      ROUTING_MAP: |
        app.example.com=app-main:80
        api.example.com=app-api:8080
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
| `ACME_EMAIL` | *(optional)* ACME contact address, in either mode. `CERTBOT_EMAIL` is the historical name and still works. See below — it is optional, and published |
| `DNS_PROVIDER` | DNS provider (`cloudflare`, `linode`, `namecheap`) |

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `443` | HAProxy listen port |
| `DOMAINS` | | Multiple domains, one per line |
| `ROUTING_MAP` | | Multi-domain routing: `domain=host:port` per line |
| `SET_CAA` | `false` | Enable CAA DNS record (dns-01 only; tls-alpn-01 cannot write DNS) |
| `TXT_PREFIX` | `_dstack-app-address` | DNS TXT record prefix |
| `ACME_STAGING` | `false` | Use Let's Encrypt staging, in either mode. `CERTBOT_STAGING` is the historical name and still works |
| `CHALLENGE_TYPE` | `dns-01` | `dns-01` (certbot + DNS credentials) or `tls-alpn-01` (lego, no DNS credentials) |
| `DNS_SETUP_MODE` | `wait` | How to handle operator-managed records: `wait`, `print` or `webhook` — see below. Applies to tls-alpn-01 and to dns-01 challenge delegation |
| `DNS_SETUP_TIMEOUT` | `1800` | Seconds to wait for those records to appear |
| `DNS_SETUP_INTERVAL` | `15` | Seconds between DNS checks |
| `DNS_WEBHOOK_URL` | | tls-alpn-01 + `DNS_SETUP_MODE=webhook`: endpoint to notify |
| `DNS_WEBHOOK_TOKEN` | | Shared secret; the payload is HMAC-SHA256 signed with it |
| `DOH_RESOLVERS` | Google + Cloudflare | Comma-separated DoH endpoints used to verify records |
| `TLSALPN_PORT` | `9443` | Loopback port lego's ACME responder binds to |
| `TLS_TERMINATE_PORT` | `9444` | Loopback port the TLS frontend moves to in tls-alpn-01 mode |
| `RENEW_DAYS_BEFORE` | client default | Days of remaining lifetime that trigger renewal. Applies to both modes: passed to lego as `--renew-days`, and written to certbot's `renew_before_expiry`. Unsetting it removes that setting again, so the client's own default applies |
| `RENEW_INTERVAL` | `43200` | Seconds between successful certificate passes |
| `DNS_SETTLE_SECONDS` | `30` | Wait after DNS verifies, so the gateway's own TXT cache expires |
| `MAXCONN` | `4096` | HAProxy max connections |
| `TIMEOUT_CONNECT` | `10s` | Backend connect timeout |
| `TIMEOUT_CLIENT` | `86400s` | Client-side timeout (24h for long-lived connections) |
| `TIMEOUT_SERVER` | `86400s` | Server-side timeout |
| `EVIDENCE_SERVER` | `true` | Serve evidence files at `/evidences/` on the TLS port |
| `EVIDENCE_PORT` | `80` | Internal port for evidence HTTP server |
| `ALPN` | | TLS ALPN protocols (e.g. `h2,http/1.1`). Only set if backends support h2c |
| `DELEGATION_ZONE` | | Zone this container writes into, so the DNS token needs no access to the served domain's own zone (see below) |
| `DELEGATION_PROPAGATION_SECONDS` | `120` | Wait after writing the delegated challenge TXT before validation. Must outlast the record TTL (60s), or a resolver still serving the previous attempt's value fails validation. The certbot run timeout is sized from this, so raising it is safe |
| `CERTBOT_TIMEOUT` | propagation wait + 180s | Seconds a single certbot run may take. The default is derived from the provider's propagation wait (or `DELEGATION_PROPAGATION_SECONDS`), which is what dominates it; set this only if a run needs longer still |

For DNS provider credentials, see [DNS_PROVIDERS.md](DNS_PROVIDERS.md).

### ACME challenge delegation (least-privilege DNS token)

By default the DNS token must be able to edit the **served domain's own zone**
(to write `_acme-challenge`, and — with `SET_CAA` — the CAA record). If the
served name lives under a shared production zone (e.g. `svc.example.com` under
`example.com`), that token can edit every record in the zone, which may be more
privilege than you want.

> **Renamed.** This was `ACME_CHALLENGE_ALIAS`, from when the challenge was the
> only thing delegated. The old name is **not** accepted — a deployment still
> setting it silently leaves delegation mode and starts writing to the served
> domain's zone, which is what delegation exists to avoid. Rename it when
> upgrading.

Set `DELEGATION_ZONE=<delegation-zone>` to move every name this deployment
needs into a zone your token controls. You create three CNAMEs in the served
domain's zone **once, before deploying**, and then never touch DNS again — not
when the app id moves, not when the ACME account is recreated, not when the
gateway moves:

```
svc.example.com                      CNAME  svc.example.com.deleg.example.net
_dstack-app-address.svc.example.com  CNAME  _dstack-app-address.svc.example.com.deleg.example.net
_acme-challenge.svc.example.com      CNAME  _acme-challenge.svc.example.com.deleg.example.net
```

dstack-ingress publishes what they point at, in the delegation zone:

```
svc.example.com.deleg.example.net                      CNAME  <GATEWAY_DOMAIN>
svc.example.com.deleg.example.net                      CAA    0 issue "letsencrypt.org;validationmethods=dns-01;accounturi=…"
_dstack-app-address.svc.example.com.deleg.example.net  TXT    "<app-id>:<port>"
_acme-challenge.svc.example.com.deleg.example.net      TXT    <challenge>   (transient)
```

The gateway pointer and the CAA share a name, which DNS does not allow for a
CNAME. Which form works is a property of the provider — Cloudflare tolerates the
pair, Linode publishes an address record instead — and `set_alias_record` in the
provider layer is where that choice is made. Delegation asks for an alias and
takes what it gets. A provider that needs a form other than CNAME overrides that
method, as Linode does.

**A wildcard needs a fourth CNAME.** RFC 8659 evaluates `*.app.example.com` at
`app.example.com`, so the base gets its own alias and the container publishes an
`issuewild` CAA behind it:

```
*.app.example.com                            CNAME  app.example.com.deleg.example.net
app.example.com                              CNAME  app.example.com.deleg.example.net
_dstack-app-address-wildcard.app.example.com CNAME  _dstack-app-address-wildcard.app.example.com.deleg.example.net
_acme-challenge.app.example.com              CNAME  _acme-challenge.app.example.com.deleg.example.net
```

The base has to be a name you can alias, which rules out a zone apex — an apex
carries SOA and NS records and a CNAME excludes them. `*.example.com` served
straight off the `example.com` zone is therefore not a fit for delegation; a
label down, `*.app.example.com`, is.

The records above are checked the same way tls-alpn-01 checks its own: two DoH
resolvers, both CAA wire formats, and `DNS_SETUP_MODE` deciding what happens
while they are missing.

Only the `_acme-challenge` CNAME is checked on later passes. Under dns-01 the CA
reads a TXT record and never connects here, so the other two records are about
serving rather than issuance, and a renewal is not blocked on them — a routing
problem can be fixed at any time, an expired certificate cannot. They are still
checked on the first pass, where the point is to tell you whether you created
them correctly. `wait` (the default) blocks until they appear, so you can
start the container and create the records afterwards; `print` lists them and
continues without checking; `webhook` POSTs them to `DNS_WEBHOOK_URL` for an
operator service to create automatically.

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

## Certificates without DNS credentials (tls-alpn-01)

The default `dns-01` flow needs a DNS API token inside the CVM: the container
creates the CNAME, TXT and CAA records itself. `CHALLENGE_TYPE=tls-alpn-01`
removes that requirement — nothing in the container can touch your DNS zone —
at the cost of you creating three records by hand (or via a webhook).

```yaml
services:
  dstack-ingress:
    image: dstacktee/dstack-ingress:<tag>
    environment:
      - CHALLENGE_TYPE=tls-alpn-01
      - DOMAIN=app.example.com
      - TARGET_ENDPOINT=http://app:80
      # Printed as the CNAME target, and used to verify that the hostname
      # really resolves to the gateway before issuance starts.
      - GATEWAY_DOMAIN=_.dstack-prod5.phala.network
      # - ACME_EMAIL=you@example.com   # optional, and published (see below)
      # - DNS_SETUP_MODE=wait          # default; blocks until the records exist
    ports:
      - "443:443"
    volumes:
      - /var/run/dstack.sock:/var/run/dstack.sock
      - cert-data:/etc/letsencrypt
      - evidences:/evidences
```

On first start the container prints the exact records to create, then polls
public DNS until they are visible:

```
==========================================================================
  DNS records required for app.example.com
==========================================================================
  CNAME  app.example.com
         -> _.dstack-prod5.phala.network
  TXT    _dstack-app-address.app.example.com
         -> b1ea785543bbbb19ce9de33744321360992bf63b:443
  CAA    app.example.com
         -> 0 issue "letsencrypt.org;validationmethods=tls-alpn-01;accounturi=https://..."
==========================================================================
```

`DNS_SETUP_MODE` picks what happens after printing: `wait` (default) blocks
until the records resolve or `DNS_SETUP_TIMEOUT` elapses; `print` continues
immediately; `webhook` POSTs the records to `DNS_WEBHOOK_URL` first and then
waits, so a service of yours can create them automatically.

### The TXT record names an *instance*, not an app

Under `dns-01` the TXT record carries the **app ID** and the gateway
load-balances across every instance of the app. tls-alpn-01 cannot work that
way. The challenge is answered by whichever instance holds the ACME order, and
Let's Encrypt validates from several vantage points at once (5 distinct source
IPs within ~2 seconds, measured), while the gateway races connections across the
app's instances. The challenge would land on the wrong replica almost every
time. So this mode publishes the **instance ID** instead, pinning the hostname
to one instance.

Two consequences:

- **tls-alpn-01 mode is effectively single-instance.** All traffic for the
  hostname goes to the pinned instance; you lose the gateway's failover.
- **The TXT record changes when the CVM instance is replaced.** Redeploying
  means updating DNS. `DNS_SETUP_MODE=webhook` exists so this can be automated;
  doing it by hand means downtime on every redeploy.

## The ACME contact address is optional, and public

`ACME_EMAIL` (or `CERTBOT_EMAIL`) may be left unset in **either** mode. RFC 8555
makes the ACME `contact` field optional, and Let's Encrypt stopped sending expiry
notification mail in 2025, so setting one buys little.

It also does not stay private. The ACME account document is published as
attestation evidence at `/evidences/acme-account.json`, so an address set here is
readable by anyone who fetches the evidence endpoint. Leave it unset unless you
specifically want a contact on the account.

Under the hood the two clients differ: lego simply omits the flag, while certbot
needs `--register-unsafely-without-email` — its "unsafely" naming predates Let's
Encrypt dropping expiry mail, and the container passes it for you.

### Limitations

- **No wildcards.** RFC 8737 forbids tls-alpn-01 for wildcard identifiers, and
  the CA will not offer the challenge. The container refuses to start rather
  than serve a name it can never obtain a certificate for, so a wildcard
  anywhere in `DOMAIN`/`DOMAINS` is a startup error even if the other names are
  fine. Use `dns-01` for `*.example.com`.
- **The gateway must be reachable on port 443.** The CA connects to port 443 of
  whatever the CNAME resolves to; the port is fixed by the protocol.
- **CAA must permit `tls-alpn-01`.** A record left over from a `dns-01`
  deployment says `validationmethods=dns-01` and will make the CA refuse. The
  container checks this before asking for a certificate, so you get a clear
  message instead of a failed validation.
- **Losing the `cert-data` volume changes the account URI.** With `dns-01` the
  container just rewrites the CAA record; here it cannot, so a pinned
  `accounturi` would start rejecting issuance until you update it by hand.

### Webhook payload

`DNS_SETUP_MODE=webhook` POSTs this envelope to `DNS_WEBHOOK_URL`:

```json
{
  "payload": "{\"app_id\":\"…\",\"challenge\":\"tls-alpn-01\",\"domain\":\"app.example.com\",\"instance_id\":\"…\",\"records\":[…],\"timestamp\":1234567890,\"version\":1}",
  "hmac_sha256": "…",
  "attestation": { "quote": "…", "report_data": "…" }
}
```

`payload` is a *string* so you sign and hash exactly the bytes you received.
Verify `hmac_sha256` with `DNS_WEBHOOK_TOKEN`, and — since this request asks you
to point a hostname at the instance it names — verify `attestation` too: the
quote's `report_data` is `sha256(payload)`, so it proves which enclave produced
those records. Check the app ID and measurements in it before changing DNS.

### Why lego and not certbot

certbot cannot do tls-alpn-01. Its standalone plugin is HTTP-01 only, the
maintainers declined to implement the challenge
([certbot#6724](https://github.com/certbot/certbot/issues/6724)), and the `acme`
library removed it outright in 4.2.0 — the last release carrying
`acme.standalone.TLSALPN01Server` is 4.1.1, where it is already marked
deprecated. This path therefore runs [lego](https://github.com/go-acme/lego),
pinned by checksum in the Dockerfile. The `dns-01` path still uses certbot and
is untouched.

Because haproxy owns the public port, the proxy peeks at each ClientHello and
forwards only connections advertising the `acme-tls/1` ALPN protocol to lego's
responder on loopback; everything else goes to the normal TLS frontend. Issuance
and renewal therefore never interrupt serving traffic. In this mode haproxy
starts on a self-signed placeholder certificate — it has to be listening before
the first certificate can be issued — and reloads onto the real one as soon as
it arrives.
