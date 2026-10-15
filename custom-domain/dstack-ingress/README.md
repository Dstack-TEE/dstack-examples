# dstack-ingress

TCP proxy with automatic TLS termination for dstack applications.

## Overview

dstack-ingress is a HAProxy-based L4 (TCP) proxy that provides:

- Automatic SSL certificate provisioning and renewal via Let's Encrypt
- Multi-provider DNS support (Cloudflare, Linode DNS, Namecheap, Route53)
- Pure TCP proxying — all protocols (HTTP, WebSocket, gRPC, arbitrary TCP) work transparently
- Wildcard domain support
- SNI-based multi-domain routing
- Certificate evidence generation for TEE attestation verification
- Strong TLS configuration (TLS 1.2+, AES-GCM, ChaCha20-Poly1305)

## How It Works

1. **Bootstrap**: On first start, obtains SSL certificates from Let's Encrypt using DNS-01 validation and configures DNS records (CNAME, TXT, optional CAA).

2. **TLS Termination**: HAProxy terminates TLS and forwards the decrypted TCP stream to your backend. No HTTP inspection — the proxy operates entirely at L4.

3. **Certificate Renewal**: A background daemon checks for renewal every 12 hours. On renewal, HAProxy is gracefully reloaded with zero downtime.

4. **Evidence Generation**: Generates cryptographically linked attestation evidence (ACME account, certificates, TDX quote / dstack attestation) for TEE verification.

### Wildcard Domain Support

You can use a wildcard domain (e.g. `*.myapp.com`) to route all subdomains to a single dstack application:

- The TXT record is automatically set as `_dstack-app-address-wildcard.myapp.com` (instead of `_dstack-app-address.*.myapp.com`)
- CAA records use both the `issuewild` and `issue` tags on the base domain: `issuewild` alone would leave other CAs free to issue for non-wildcard subdomains
- If the base domain is a zone apex (`*.myapp.com` served off the `myapp.com` zone), that `issue` record replaces any existing `issue` values there and governs every name in the zone without its own CAA record, so other CAs or ACME accounts can no longer issue for them. The container warns about this; give those names their own CAA records, or set `SET_CAA=false`. On Route53 this also removes the Amazon `issue` values that older versions wrongly added at the apex
- Two deployments with different ACME accounts, one serving `myapp.com` and one `*.myapp.com`, both write the `issue` record at `myapp.com` and overwrite each other's on every pass. Serve both names from one deployment, or set `SET_CAA=false` on one of them
- Requires dstack-gateway with wildcard TXT resolution support ([dstack#545](https://github.com/Dstack-TEE/dstack/pull/545))

```yaml
services:
  dstack-ingress:
    image: ghcr.io/dstack-tee/dstack-ingress:2.6@sha256:c212abb7bedec4d7b54a82bcf9972e58e39a4757cc811faeb6017eee6c0673b0
    ports:
      - "443:443"
    environment:
      - CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}
      - DOMAIN=*.myapp.com
      - GATEWAY_DOMAIN=gateway.dstack-prod5.phala.network
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
    image: ghcr.io/dstack-tee/dstack-ingress:2.6@sha256:c212abb7bedec4d7b54a82bcf9972e58e39a4757cc811faeb6017eee6c0673b0
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
    image: ghcr.io/dstack-tee/dstack-ingress:2.6@sha256:c212abb7bedec4d7b54a82bcf9972e58e39a4757cc811faeb6017eee6c0673b0
    ports:
      - "443:443"
    environment:
      DNS_PROVIDER: cloudflare
      CLOUDFLARE_API_TOKEN: ${CLOUDFLARE_API_TOKEN}
      CERTBOT_EMAIL: ${CERTBOT_EMAIL}
      GATEWAY_DOMAIN: gateway.dstack-prod5.phala.network
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
| `DOMAIN` or `DOMAINS` | The domain to serve, or several in `DOMAINS`; both may be set. `DOMAINS` takes one domain per line, or a single comma-separated line (commas in a multi-line value are not separators). Supports wildcards (`*.example.com`) |
| `TARGET_ENDPOINT` | Backend address, e.g. `app:80` or `http://app:80`. Not needed with `ROUTING_MAP` |
| `GATEWAY_DOMAIN` | dstack gateway domain (e.g. `gateway.dstack-prod5.phala.network`) |

`GATEWAY_DOMAIN` is published as your domain's CNAME target, so its first label
must start with a letter or digit. Android's resolver rejects a leading
underscore in an address lookup, CNAME target included, so the older
`_.<gateway-domain>` form resolves everywhere except Android. The label is
otherwise arbitrary — the gateway answers every name under its domain.

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `443` | HAProxy listen port |
| `DOMAINS` | | Multiple domains, one per line or one comma-separated line. Without `ROUTING_MAP`, all of them go to `TARGET_ENDPOINT` |
| `ROUTING_MAP` | | Multi-domain routing: `domain=host:port` per line. A wildcard entry (`*.example.com=host:port`) matches one label, and exact entries take precedence over it. Unmatched names go to the first entry |
| `SET_CAA` | `false` | Enable CAA DNS record (dns-01 only; tls-alpn-01 cannot write DNS). Replaces existing values with the same tag; for a wildcard whose base is a zone apex this restricts the whole zone (see [Wildcard Domain Support](#wildcard-domain-support)). Except on Cloudflare, a non-wildcard domain is then published as an A record to the gateway's current address instead of a CNAME, because a CNAME would hide the CAA beside it; the address is refreshed every `RENEW_INTERVAL`. Turning `SET_CAA` off later leaves the CAA record in place, so the A record stays until you delete the CAA |
| `TXT_PREFIX` | `_dstack-app-address` | DNS TXT record prefix |
| `ACME_EMAIL` | | ACME contact address, in either mode. `CERTBOT_EMAIL` is the historical name and still works. See [below](#the-acme-contact-address-is-optional-and-public) — it is optional, and published |
| `ACME_STAGING` | `false` | Use Let's Encrypt staging, in either mode. `CERTBOT_STAGING` is the historical name and still works |
| `ACME_DIRECTORY_URL` | | ACME directory of a test server such as Pebble, used instead of Let's Encrypt in either mode (CAA records always name `letsencrypt.org`, so other public CAs are not supported); takes precedence over `ACME_STAGING` |
| `CHALLENGE_TYPE` | `dns-01` | `dns-01` (certbot + DNS credentials) or `tls-alpn-01` (lego, no DNS credentials) |
| `DNS_PROVIDER` | detected | dns-01: `cloudflare`, `linode`, `namecheap` or `route53`. Detected from the provider's credential variable when unset; set it explicitly for `route53`, whose role setup depends on it |
| `DNS_SETUP_MODE` | `wait` | How to handle operator-managed records: `wait`, `print` or `webhook` — see below. Applies to tls-alpn-01 and to dns-01 challenge delegation |
| `DNS_SETUP_TIMEOUT` | `1800` | Seconds to wait for those records to appear |
| `DNS_SETUP_INTERVAL` | `15` | Seconds between DNS checks |
| `DNS_WEBHOOK_URL` | | `DNS_SETUP_MODE=webhook`: endpoint to notify |
| `DNS_WEBHOOK_TOKEN` | | Shared secret; the payload is HMAC-SHA256 signed with it |
| `DNS_WEBHOOK_TIMEOUT` | `15` | Seconds per webhook POST attempt |
| `DOH_RESOLVERS` | Google + Cloudflare | Comma-separated DoH endpoints used to verify records |
| `TLSALPN_ADDRESS` | `127.0.0.1` | Address lego's ACME responder binds to, and haproxy forwards `acme-tls/1` connections to |
| `TLSALPN_PORT` | `9443` | Loopback port lego's ACME responder binds to |
| `TLS_TERMINATE_PORT` | `9444` | Loopback port the TLS frontend moves to in tls-alpn-01 mode |
| `RENEW_DAYS_BEFORE` | client default | Days of remaining lifetime that trigger renewal. Applies to both modes: passed to lego as `--renew-days`, and written to certbot's `renew_before_expiry`. Unsetting it removes that setting again, so the client's own default applies |
| `DETERMINISTIC_TLS_KEY` | `false` | Derive a stable TLS key from the dstack KMS so clients can pin it; see [Deterministic TLS keys](#deterministic-tls-keys-spki-pinning) |
| `RENEW_INTERVAL` | `43200` | Seconds between successful certificate passes |
| `DNS_SETTLE_SECONDS` | `30` | tls-alpn-01: wait after DNS verifies, so the gateway's own TXT cache expires |
| `MAXCONN` | `4096` | HAProxy max connections |
| `TIMEOUT_CONNECT` | `10s` | Backend connect timeout |
| `TIMEOUT_CLIENT` | `86400s` | Client-side timeout (24h for long-lived connections) |
| `TIMEOUT_SERVER` | `86400s` | Server-side timeout |
| `EVIDENCE_SERVER` | `true` | Serve evidence files at `/evidences/` on the TLS port. Set `false` for backends whose server speaks first — see [Evidence & Attestation](#evidence--attestation) |
| `EVIDENCE_PORT` | `80` | Internal port for evidence HTTP server |
| `ALPN` | | TLS ALPN protocols (e.g. `h2,http/1.1`). Only set if backends support h2c |
| `ACCEPT_PROXY_PROTOCOL` | `false` | Read the client's address from a PROXY protocol header (v1 or v2) on every connection to `PORT`, as the dstack gateway sends when the app's `port_policy` sets `pp` for it. A connection without one is refused. See [Client address](#client-address-proxy-protocol) |
| `SEND_PROXY_PROTOCOL` | `false` | Pass the client's address to the backends (`TARGET_ENDPOINT`, `ROUTING_MAP`) with PROXY protocol v2. Only for backends that read it |
| `DELEGATION_ZONE` | | Zone this container writes into, so the DNS token needs no access to the served domain's own zone (see below) |
| `DELEGATION_PROPAGATION_SECONDS` | `120` | Wait after writing the delegated challenge TXT before validation. Must outlast the record TTL (60s), or a resolver still serving the previous attempt's value fails validation. The certbot run timeout is sized from this, so raising it is safe |
| `CERTBOT_TIMEOUT` | propagation wait + 180s, never below 300s | Seconds a single certbot run may take. The default is derived from the provider's propagation wait (or `DELEGATION_PROPAGATION_SECONDS`), which is what dominates it. Set this only if a run needs longer still; an explicit value is used as given, floor included |

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
svc.example.com.deleg.example.net                      A      <address of GATEWAY_DOMAIN>
svc.example.com.deleg.example.net                      CAA    0 issue "letsencrypt.org;validationmethods=dns-01;accounturi=…"
_dstack-app-address.svc.example.com.deleg.example.net  TXT    "<app-id>:<port>"
_acme-challenge.svc.example.com.deleg.example.net      TXT    <challenge>   (transient)
```

The gateway pointer and the CAA share a name. Cloudflare answers a CAA query
with the CAA beside a CNAME, so the pointer stays a CNAME there. Elsewhere it is
an A record: by the DNS rules resolvers follow a CNAME without looking beside it,
and Route53 and Linode refuse the pair. The address
is the one `GATEWAY_DOMAIN` resolves to when the container writes it, and it is
refreshed every `RENEW_INTERVAL`, so a gateway move reaches DNS only then, and
only one of the gateway's addresses is published.

**A wildcard needs a fourth CNAME.** RFC 8659 evaluates `*.app.example.com` at
`app.example.com`, so the base gets its own alias and the container publishes
`issuewild` and `issue` CAA records behind it:

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

## Client address (PROXY protocol)

The gateway relays TCP, so haproxy sees each connection come from the gateway, and the backend sees it come from
haproxy. To give the backend the client's address instead (requires dstack-gateway 0.5.9 or later):

1. Have the gateway send it: in the app compose, set `"port_policy": {"ports": [{"port": <PORT>, "pp": true}]}`,
   with `PORT` as configured for this container (on Phala Cloud, the port policy's "Proxy protocol (pp)" switch).
   Guest OS 0.5.9+ reports the policy when the CVM registers with the gateway; older images need `public_tcbinfo`
   on so the gateway can read it from the TCB info.
2. Set `ACCEPT_PROXY_PROTOCOL=true`, so haproxy reads that header. Change both in the same deployment: a header
   haproxy does not expect, or one it expects and does not get, fails every connection. This includes anything
   that reaches `PORT` without the gateway, such as a host port mapping or another container in the CVM.
3. Set `SEND_PROXY_PROTOCOL=true`, and have the backend accept PROXY protocol v2 from haproxy only, for example
   Caddy's `proxy_protocol` listener wrapper or nginx's `listen ... proxy_protocol` with `set_real_ip_from`. With
   `ROUTING_MAP`, this applies to every backend.

In tls-alpn-01 mode the address also survives the hop to the TLS frontend on loopback, which already uses the PROXY
protocol internally. The ACME responder never sees the header.

If the gateway itself sits behind an L4 load balancer, the gateway operator must enable `inbound_pp_enabled` on it
(and PROXY protocol on the load balancer), or the address passed on is the load balancer's.

## Deterministic TLS keys (SPKI pinning)

Set `DETERMINISTIC_TLS_KEY=true` to derive a P-256 TLS key per domain from the dstack
`/GetKey` endpoint instead of generating a random one. The key depends only on the app's
KMS-derived key and the domain, so every instance, restart, upgrade and certificate
renewal serves the same public key, and clients can pin its SPKI. Works in both challenge
modes; turning it on for an existing deployment re-issues the certificate with the
derived key on the next pass.

The SPKI stays the same only as long as the app ID and the KMS do. It changes when the app
is deployed under a new app ID, when it moves to a different KMS, or when it runs without
a KMS (the local key provider ties keys to the host). There is no rotation: if the key has
to be replaced, so do the pins. The derived key is not covered by the agent's signature
chain; bind it to the app through the attested evidence instead.

In dns-01 mode certbot cannot keep a lineage for a key it did not generate, so these
certificates live under `/etc/letsencrypt/deterministic/` and are renewed by the container
at the same point certbot would (two thirds into the lifetime, or `RENEW_DAYS_BEFORE`),
without ARI. In tls-alpn-01 mode lego renews them on its normal schedule.

## Evidence & Attestation

Evidence files are served at `https://your-domain.com/evidences/` by default (via payload inspection in HAProxy's TCP mode). They can also be accessed by the backend application through the shared `/evidences` volume.

To disable the built-in evidence endpoint and serve evidence files only through your backend, set `EVIDENCE_SERVER=false`.

The endpoint matches the first bytes of an HTTP/1.x request, so:

- With `ALPN` including `h2`, clients that negotiate HTTP/2 (curl's default) send their evidence requests to the
  backend instead. Use `curl --http1.1`, or serve `/evidences` from the backend too.
- haproxy waits up to 5 seconds for a request that could start with `GET` or `HEAD`. A backend whose server speaks
  first (SMTP, MySQL, ...), or whose client's first message starts with `G` or `H` and is shorter than 16 bytes,
  sees that delay on every connection. Set `EVIDENCE_SERVER=false` for such backends.

### Evidence Files

| File | Description |
|------|-------------|
| `acme-account.json` | ACME account used to request certificates |
| `cert-{domain}.pem` | Let's Encrypt certificate for each domain |
| `sha256sum.txt` | SHA-256 checksums of all evidence files |
| `quote.json` | TDX quote with `sha256sum.txt` digest in report_data (TDX only) |
| `attestation.json` | dstack attestation (`/v1/Attest`) with the same report_data, on dstack 0.6+ on every platform |

### Verification Chain

The attestation's 64-byte `report_data` is the SHA-256 of `sha256sum.txt` followed by 32 zero bytes, and
`sha256sum.txt` lists `acme-account.json` and every `cert-<domain>.pem`. That is all it covers: no nonce, no
timestamp, no TLS key, nothing about the connection. Anyone can fetch these files and relay them, so an
attestation that matches the files only proves that *some* CVM published them. All of the following are needed:

1. **The attestation is genuine.** POST `attestation.json` (or `quote.json`) to
   [dstack-verifier](https://github.com/Dstack-TEE/dstack/tree/HEAD/dstack/verifier)'s `/verify`, or check a
   `quote.json` quote against Intel collateral with `dcap-qvl`. The verifier's `is_valid` must be `true`; take
   `report_data` from its `details.report_data`, not from the `report_data` field in `quote.json`, which the agent
   echoes back.
2. **It is your app.** The verifier replays the event log into `details.app_info`; check that `app_id` and
   `compose_hash` there are the app you expect, and `os_image_hash` a known dstack OS image. A genuine attestation
   from someone else's CVM proves nothing about yours.
3. **The files are the attested ones.** `sha256(sha256sum.txt)` is the first 32 bytes of `report_data`, and
   `sha256sum -c sha256sum.txt` passes.
4. **The connection uses the attested certificate.** The leaf certificate served on your TLS connection is the
   first certificate in `cert-<domain>.pem` (compare fingerprints, or the SPKI hash to tolerate renewals with
   `DETERMINISTIC_TLS_KEY=true`). Otherwise a man in the middle can serve its own certificate and relay the real
   `/evidences`.
5. **No one else can get a certificate.** The CAA records the container publishes for the domain (at the base
   name for a wildcard) pin `accounturi` to the account URI in `acme-account.json` — `.uri` for certbot,
   `.registration.uri` or `.registration.accountURL` for lego — and no other `issue`/`issuewild` record at that
   name allows another CA or account. The account key never leaves the CVM, so while these records are in place
   only the CVM can obtain a certificate for the domain, and step 4 holds for every client, not just the one that
   checked. A CAA lookup only shows the current state: whoever controls the DNS zone can remove the pin, get a
   certificate and put it back. Monitor Certificate Transparency logs (e.g. crt.sh) for certificates of the
   domain that are not in the evidence.
   Without the pin (`SET_CAA=false`, or tls-alpn-01 without the printed CAA record) anyone who can pass ACME
   validation for the domain — whoever controls its DNS or the route to it — can get a valid certificate, and
   the evidence cannot rule that out.

## Building

```bash
./build-image.sh
# Or push directly:
./build-image.sh --push yourusername/dstack-ingress:tag
```

The build script ensures reproducibility via pinned packages, deterministic timestamps, and specific buildkit version. Building the same commit from a clean checkout produces the same image digest; CI runs the same script with `--require-clean`.

### Where the images live

Releases from 2.6 on are published to `ghcr.io/dstack-tee/dstack-ingress`, using the workflow's own `GITHUB_TOKEN`. 2.5 and earlier are on Docker Hub as `dstacktee/dstack-ingress` and stay there; they are not being mirrored.

### Image metadata

Every image records where it came from, using the standard [OCI image annotation keys](https://github.com/opencontainers/image-spec/blob/main/annotations.md). The values are derived from the git checkout only (commit, the `VERSION` file, the Dockerfile base image), so they do not disturb reproducibility. The same key/value set is written to three places:

| Location | How to read it |
|---|---|
| Image config labels | `skopeo inspect docker://ghcr.io/dstack-tee/dstack-ingress:<tag> \| jq .Labels` or `docker inspect --format '{{json .Config.Labels}}' <image>` |
| Image manifest annotations | `skopeo inspect --raw docker://ghcr.io/dstack-tee/dstack-ingress:<tag> \| jq .annotations` |
| `/etc/dstack-ingress/build-info` inside the image | `docker run --rm --entrypoint cat <image> /etc/dstack-ingress/build-info`; also printed as the first line of the container log |

| Key | Value |
|---|---|
| `org.opencontainers.image.source` | Repository URL (`SOURCE_URL` env when building from a fork) |
| `org.opencontainers.image.revision` | Git commit; suffixed with `-dirty` when built from an unclean tree |
| `org.opencontainers.image.version` | Contents of `VERSION`; the release tag `dstack-ingress-v<version>` must match |
| `org.opencontainers.image.url` / `.documentation` | The release page, `releases/tag/dstack-ingress-v<version>` (see below) |
| `org.opencontainers.image.base.name` / `.base.digest` | The pinned haproxy base image |

`url` and `documentation` are derived from `VERSION` rather than from the commit, and that is deliberate. The examples in this repository pin the image by digest, so they can only be updated one commit *after* the one that was built — a link to the build commit's tree or README therefore always lands on a page telling the reader to deploy the previous release. The release page is the one document written after the digest is known, so it is the only one that can describe the image it ships with. Exact source stays available through `source` + `revision`.

To reproduce a published image, check out the commit from its `revision` label and run `./build-image.sh` on a native Linux amd64 host with Docker Buildx, Skopeo, jq and Git installed; the digest printed at the end must match the registry. Releases are additionally signed with SLSA provenance, verifiable with `gh attestation verify oci://ghcr.io/dstack-tee/dstack-ingress:<tag> --owner Dstack-TEE`.

### Releasing

A release is not finished when the image is pushed. The compose files and the snippets above are what people deploy, so they have to point at the new image; 2.4 and 2.5 were tagged and published without that step, and every example kept deploying 2.3.

1. Update `VERSION` and commit it. Bumping the version is a source change: the release workflow refuses to build unless the tag matches this file.

   If the base image or the installed packages changed since the last release, run `./build-image.sh` locally first and commit the regenerated `pinned-packages.txt` in the same batch. The build refuses to publish an image whose packages that file does not record, so a stale one fails the release after a full CI build.
2. Tag that commit `dstack-ingress-v<version>` and push the tag. CI builds with `--require-clean`, pushes the image, and reports the digest in the run summary and the release notes.
3. Merge the pin pull request. The release workflow opens it against the default branch as its last step, with every digest-pinned reference — `docker-compose.yaml`, `docker-compose.multi.yaml`, three snippets in this README, and `k3s/docker-compose.yaml` — set to the digest it just published.

   Review it like any other: the digest in the diff must match the one in the release notes. Checks declared on `pull_request` do not start for a pull request opened with `GITHUB_TOKEN`, so its check list will be empty even though `./dev.sh check-all` ran on that tree in the release job; close and reopen it to run them.

   If that job failed, do the same thing by hand:

   ```bash
   # from anywhere in the repository
   ./custom-domain/dstack-ingress/pin-release.sh ghcr.io/dstack-tee/dstack-ingress:<version>@sha256:<digest>
   ```

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
    image: ghcr.io/dstack-tee/dstack-ingress:<tag>
    environment:
      - CHALLENGE_TYPE=tls-alpn-01
      - DOMAIN=app.example.com
      - TARGET_ENDPOINT=http://app:80
      # Printed as the CNAME target, and used to verify that the hostname
      # really resolves to the gateway before issuance starts.
      - GATEWAY_DOMAIN=gateway.dstack-prod5.phala.network
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
         -> gateway.dstack-prod5.phala.network
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
  "attestation": { "quote": "…", "event_log": "…", "attestation": "…", "report_data": "…" }
}
```

`attestation` holds the `GetQuote` response (TDX only) and, on dstack 0.6+, the
`/v1/Attest` response's `attestation` field.

`payload` is a *string* so you sign and hash exactly the bytes you received.
Verify `hmac_sha256` with `DNS_WEBHOOK_TOKEN`, and — since this request asks you
to point a hostname at the instance it names — verify `attestation` too (dstack-verifier `/verify` takes it as is): its
`report_data` is `sha256(payload)`, so it proves which enclave produced
those records. Check the app ID and measurements in it before changing DNS.
Take `report_data` from the verified result — `sha256(payload)` in its first
32 bytes, then 32 zero bytes — not from `attestation.report_data`, which the
container fills in itself.

Neither the HMAC nor the attestation expires, so a captured envelope stays valid forever; replaying an old one
would point the hostname back at an instance that no longer serves it. The `timestamp` inside `payload` is covered
by both, so use it: reject envelopes more than a few minutes old, and remember, per `domain`, the `timestamp` of
the last one you applied. Reject anything older. A failed POST is retried with the identical envelope, so treat a
byte-identical `payload` as a retry of the one already applied rather than a new request.

`records` can hold several records with the same type and name: a wildcard asks
for both an `issue` and an `issuewild` CAA at its base. Create each one; do not
replace by type and name alone.

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
