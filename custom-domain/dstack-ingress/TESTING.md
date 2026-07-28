# Testing dstack-ingress

This component's entire job is to obtain and serve TLS certificates. Almost
everything that can go wrong involves a party we do not control — a CA, a DNS
resolver, a gateway, a TEE — so a test that mocks those tests very little. What
follows is how to exercise it against the real things, cheaply enough to do
routinely.

Use **Let's Encrypt staging** throughout (`CERTBOT_STAGING=true` /
`ACME_STAGING=true`). Its rate limits are generous and its certificates are
untrusted, which is exactly what you want: a test certificate that browsers
reject cannot be mistaken for a production one.

## Three tiers, in increasing cost

Pick the cheapest tier that can actually observe what you changed.

| Tier | Setup | Can test | Cannot test |
|---|---|---|---|
| **1. Container + simulator** | Docker, dstack simulator | dns-01 end to end, config generation, negative paths, `DNS_SETUP_MODE`, evidence, webhook | Anything needing inbound traffic |
| **2. Tier 1 + real DNS credentials** | + a zone you control | Everything the DNS provider code does | Same |
| **3. Real CVM behind a gateway** | + TDX host, `dstack-vmm`, `dstack-gateway`, public port 443 | tls-alpn-01, ALPN routing, real TDX quotes, gateway interaction | — |

dns-01 needs no inbound connection: the CA reads a TXT record and never talks to
you. That is why the whole dns-01 path fits in tier 1/2. tls-alpn-01 is the
opposite — the CA connects to port 443 and completes a TLS handshake — so it can
only be tested for real in tier 3.

## Tier 1/2: containers

The container asks the guest agent for its app and instance ID and for TDX
quotes, so it needs a socket at `/var/run/dstack.sock`. Outside a CVM, use the
simulator:

```bash
cd dstack/sdk/simulator && ./build.sh && ./dstack-simulator &
```

Then mount its socket:

```yaml
volumes:
  - /path/to/sdk/simulator/dstack.sock:/var/run/dstack.sock
```

Keep provider credentials out of the compose file — put them in a `.env` that
compose reads, and `chmod 600` it:

```bash
umask 077 && printf 'CLOUDFLARE_API_TOKEN=%s\n' "$TOKEN" > .env
```

Give each scenario its own project name and its own volumes
(`docker compose -p <name>`), so a leftover certificate from a previous run
cannot make the next one pass for the wrong reason. This matters more than it
sounds — see "Start from a clean zone" below.

## Tier 3: a real CVM

You need a TDX host running `dstack-vmm`, `dstack-kms` and `dstack-gateway`, and
the gateway must be reachable from the internet on **port 443** — the CA picks
that port and RFC 8737 gives you no say. If the gateway listens elsewhere,
redirect:

```bash
sudo iptables -t nat -A PREROUTING -d <public-ip> -p tcp --dport 443 \
     -m comment --comment 'ingress-lab' -j REDIRECT --to-ports <gateway-port>
```

Tag every rule with a `--comment` so teardown can find them all later.

Point the test hostname at the gateway (an `A` record works; the container's
CNAME check compares resolved addresses, not record types), then publish the
routing TXT:

```
_dstack-app-address.<domain>  TXT  "<instance_id>:443"
```

**Instance ID, not app ID.** In tls-alpn-01 mode the challenge is answered by
whichever instance holds the ACME order, while the gateway load-balances across
every instance of the app and the CA validates from several vantage points at
once — five distinct source IPs within ~2 seconds, in practice. Publishing the
app ID sends the challenge to the wrong replica almost every time.

Reading container logs inside a CVM: with `--public-logs`, the guest agent serves
them over the gateway's WireGuard network.

```bash
curl -s 'http://10.44.0.<n>:8090/logs/dstack-dstack-ingress-1?text&bare&tail=500'
```

The container name is the compose-mangled one (`dstack-<service>-1`), not the
service name. Find the instance's WireGuard address by probing the peers listed
in `wg show <interface> allowed-ips`; stale peers from removed VMs stay in the
list, so probe for an open port rather than trusting it.

## Exercising each area

### Issuance

Nothing special — start the container and wait. What to assert:

- the certificate is served on port 443 and its issuer is a staging CA;
- SAN matches the requested name;
- for `ROUTING_MAP`, each hostname reaches *its own* backend. Routing is by SNI,
  so send the SNI, not just a `Host` header.

### The ALPN split (tls-alpn-01)

The peek frontend forwards `acme-tls/1` to lego and everything else to the TLS
frontend. You can drive both sides by hand:

```bash
openssl s_client -connect <domain>:443 -servername <domain> -alpn acme-tls/1
openssl s_client -connect <domain>:443 -servername <domain> -alpn h2,http/1.1
```

and then confirm in the container's haproxy log that they took different paths:

```
tls_peek be_acme/lego              ← the ACME probe
tls_peek be_tls_terminate/local    ← normal traffic
```

This is the mechanism the whole mode rests on, and it is worth checking directly
rather than inferring it from "issuance worked".

### Renewal — both branches

Renewal is the part most likely to break in production and the least likely to be
covered, because a fresh certificate is not due for ~60 days. Both clients take a
renewal window, and `RENEW_DAYS_BEFORE` sets it in either mode:

- **not due**: leave `RENEW_DAYS_BEFORE` unset and restart the container. Expect
  lego `Skip renewal` / certbot `No certificates need renewal`, **no haproxy
  reload, and no new evidence**. A pass that reloads on every check is a bug —
  it means the renewal decision is not being read correctly.
- **due**: set `RENEW_DAYS_BEFORE=365` and restart. Expect a new certificate,
  a reload, and regenerated evidence.

Then check the certificate actually changed on the wire — the serial number, not
just the log line:

```bash
openssl s_client -connect <domain>:443 -servername <domain> </dev/null 2>/dev/null \
  | openssl x509 -noout -serial -dates
```

Shorten `RENEW_INTERVAL` (default 43200s) if you want the loop to come round
again without restarting — but note that `RENEW_DAYS_BEFORE=365` makes the
certificate *permanently* due, so every pass renews. Combined with a short
interval that is a loop issuing certificates as fast as the CA will allow. Set
one or the other, unset it once you have seen the branch you came for, and never
carry it into production.

Do not assert on the ACME client's log wording. lego 4.x wrote `no renewal` and
5.x writes `Skip renewal`; certbot's phrasing has moved too. The container uses
lego's `--deploy-hook`, which fires only on an actual renewal, and certbot's exit
behaviour — test the observable effect (reload / no reload), not the prose.

### Evidence

`/evidences/` is served on the TLS port. The chain to verify:

```
quote.report_data == sha256(sha256sum.txt)
sha256sum.txt     covers acme-account.json and every cert-<domain>.pem
cert-<domain>.pem == the certificate actually served
```

so:

```bash
curl -sk https://<domain>/evidences/sha256sum.txt -o s.txt && sha256sum -c s.txt
python3 -c "import json,hashlib;print(json.load(open('quote.json'))['report_data'][:64] \
  == hashlib.sha256(open('s.txt','rb').read()).hexdigest())"
```

Compare the evidence copy against a live `openssl s_client` fingerprint — the
point of the chain is that the quote commits to what is *being served*, and only
that comparison tests it.

To verify the quote itself rather than trusting it, run it through `dcap-qvl`
against Intel collateral and expect `status = UpToDate`. Re-run the whole chain
after a renewal: the evidence must track the new certificates, not go stale at
first issuance.

### DNS setup modes (tls-alpn-01)

- `wait` — the default. Start the container *before* creating the records and
  confirm it blocks and says which record is missing. Then create them and
  confirm it proceeds. This is also the only mode that runs the CAA
  compatibility check.
- `print` — skips all verification, including CAA. Confirm it continues
  immediately.
- `webhook` — set `DNS_WEBHOOK_URL` and `DNS_WEBHOOK_TOKEN` and point them at a
  throwaway HTTP server. The body carries the records, an HMAC-SHA256 over the
  payload, and a TDX quote whose `report_data` is `sha256(payload)`. Verify both:
  the HMAC proves the shared secret, the quote proves the enclave.

### Negative paths

These fail fast and are cheap, so run them on every change:

| Scenario | Expected |
|---|---|
| tls-alpn-01 + a wildcard domain | Refused before any ACME call, citing RFC 8737 |
| A CAA record with `validationmethods=dns-01`, mode tls-alpn-01 | Blocked with the restriction quoted back |
| TXT holding the wrong value | Reported as `want <x>, saw <y>`, not "missing" |
| An instance ID the gateway does not know | The CA reports a connection error — the gateway will not route to it |

The last one is worth keeping: it is the cross-tenant impersonation defence, and
it is observable rather than merely argued.

## Traps

**Start from a clean zone.** Records left over from an earlier run change which
branch executes. A stale CAA record naming a previous ACME account makes dns-01's
first issuance attempt fail and the second succeed — which happens to be the path
where the code was correct, hiding a bug in the ordinary path where the first
attempt succeeds. Delete test records between runs and verify against the
authoritative nameserver, not a cached resolver.

**One resolver is not enough to trust either answer.** Public resolvers cache
negative answers for the zone's SOA minimum, so a resolver queried before a
record existed can keep saying "no such record" for up to an hour. They also
disagree on wire format: Cloudflare returns CAA in RFC 3597 generic hex
(`\# 47 00 05 69 73 73 75 65 ...`), Google in presentation form. The container
queries two resolvers with deliberately opposite quorums — propagation needs all
of them to agree, CAA takes the union so any resolver seeing a restriction stops
issuance — and if you are checking DNS by hand you should do the same.

**Public DNS being correct is not the same as the gateway acting on it.** The
gateway caches the app-address TXT for its TTL, so immediately after the value
changes it can still route to the previous target. `DNS_SETTLE_SECONDS`
(default 30, first pass only) covers this. A challenge that fails with
`Error getting validation data` right after a DNS change is usually this, not a
broken challenge.

**lego buffers its output until it exits.** A renewal can show nothing at all in
the log for several minutes. Check whether the process is still running before
concluding it hung.

**`ALPN` is not validated against the backend.** Advertising `h2` in front of an
HTTP/1.1-only backend makes haproxy negotiate HTTP/2 on its behalf and the
connection then breaks. If a test client fails but `--http1.1` works, suspect
this before suspecting the proxy.

## Unit tests

```bash
python3 scripts/tests/test_dnsguide.py     # DNS/CAA parsing and record building
bash    scripts/tests/test_sanitizers.sh   # env var validation
```

The parsing tests are built from rdata real resolvers actually returned, in both
encodings. When you touch DNS handling, add the real string you saw rather than
one you composed — the encodings are the part that surprises people.

## haproxy config equivalence

The proxy config is assembled by `haproxy-lib.sh` and composed differently by
each mode. When refactoring that assembly, generate the config both before and
after your change for all four combinations — `dns-01` and `tls-alpn-01`, each
with a single domain and with `ROUTING_MAP` — and diff them. Byte-identical
output is a much stronger statement than "the tests still pass", and it is easy
to obtain because the emitters only write to stdout.

## Cleanup

Leftovers from a certificate test are unusually annoying: a stray CAA record can
block issuance for a domain weeks later, and a stray DNAT rule silently
intercepts port 443. Tear down in this order and verify each:

1. containers and volumes (`docker compose -p <name> down -v`);
2. the CVM (`vmm-cli remove`);
3. iptables rules — delete by comment tag, in a loop, until none match;
4. DNS records — list them from the provider API afterwards, not by `dig`,
   which can serve a cached answer for a record you already deleted;
5. the credentials file, the simulator, and any images built for the test.
