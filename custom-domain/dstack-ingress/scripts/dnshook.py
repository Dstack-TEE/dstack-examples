#!/usr/bin/env python3
"""Push the required DNS records to an operator-supplied webhook.

Because the instance ID is baked into the TXT record in tls-alpn-01 mode, that
record changes every time the CVM instance is replaced. Doing that by hand means
downtime on every redeploy, so this hook exists to let the operator automate it.

That makes the hook security-relevant: whoever receives it is being asked to
point a hostname at whatever instance the caller names. An unauthenticated hook
would hand domain hijacking to anyone who can reach the endpoint. So every
request carries:

  * an HMAC-SHA256 over the exact payload string, keyed by a shared secret; and
  * optionally a TDX quote whose report_data commits to that same payload.

Verify both on the receiving end. The HMAC alone only proves the caller knows
the secret; the quote proves the caller is the enclave you expect, so check the
app_id / measurements in it before touching DNS.

Payload is sent as a *string* field rather than a nested object on purpose: the
receiver signs and hashes exactly the bytes it was given, with no JSON
re-canonicalisation to disagree about.
"""

import argparse
import hashlib
import hmac
import json
import os
import subprocess
import sys
import time
from dataclasses import asdict
from typing import Any, Dict, List, Optional, Sequence

import requests

DEFAULT_TIMEOUT = 15
DEFAULT_RETRIES = 3
DSTACK_SOCKETS = (
    ("/var/run/dstack.sock", "http://localhost/GetQuote?report_data={rd}"),
    ("/var/run/tappd.sock", "http://localhost/prpc/Tappd.RawQuote?report_data={rd}"),
)


def _canonical(payload: Dict[str, Any]) -> str:
    return json.dumps(payload, sort_keys=True, separators=(",", ":"))


def _sign(payload_str: str, secret: str) -> str:
    return hmac.new(secret.encode(), payload_str.encode(), hashlib.sha256).hexdigest()


def get_quote(payload_str: str) -> Optional[Dict[str, Any]]:
    """Fetch a TDX quote committing to payload_str, or None if unavailable."""
    report_data = hashlib.sha256(payload_str.encode()).hexdigest()
    for sock, url_tpl in DSTACK_SOCKETS:
        if not os.path.exists(sock):
            continue
        try:
            out = subprocess.run(
                ["curl", "-s", "--unix-socket", sock, url_tpl.format(rd=report_data)],
                capture_output=True,
                text=True,
                timeout=30,
            )
            if out.returncode != 0 or not out.stdout.strip():
                print(
                    f"Warning: quote fetch via {sock} failed (rc={out.returncode})",
                    file=sys.stderr,
                )
                continue
            quote = json.loads(out.stdout)
            quote["report_data"] = report_data
            return quote
        except (subprocess.SubprocessError, ValueError) as exc:
            print(f"Warning: quote fetch via {sock} failed: {exc}", file=sys.stderr)
    return None


def build_envelope(
    records: Sequence[Any],
    domain: str,
    challenge: str,
    with_quote: bool = True,
) -> Dict[str, Any]:
    payload = {
        "version": 1,
        "domain": domain,
        "challenge": challenge,
        "app_id": os.environ.get("DSTACK_APP_ID", ""),
        "instance_id": os.environ.get("DSTACK_INSTANCE_ID", ""),
        "timestamp": int(time.time()),
        "records": [asdict(r) if hasattr(r, "__dataclass_fields__") else dict(r) for r in records],
    }
    payload_str = _canonical(payload)
    envelope: Dict[str, Any] = {"payload": payload_str}

    secret = os.environ.get("DNS_WEBHOOK_TOKEN", "")
    if secret:
        envelope["hmac_sha256"] = _sign(payload_str, secret)
    else:
        print(
            "Warning: DNS_WEBHOOK_TOKEN is unset, so the webhook request is "
            "unauthenticated. Anyone who can reach your endpoint could redirect "
            "your domain. Set a secret.",
            file=sys.stderr,
        )

    if with_quote:
        quote = get_quote(payload_str)
        if quote is not None:
            envelope["attestation"] = quote
    return envelope


def notify(
    records: Sequence[Any],
    domain: str,
    challenge: str,
    url: Optional[str] = None,
    retries: int = DEFAULT_RETRIES,
) -> None:
    url = url or os.environ.get("DNS_WEBHOOK_URL", "")
    if not url:
        raise RuntimeError("DNS_SETUP_MODE=webhook but DNS_WEBHOOK_URL is not set")

    envelope = build_envelope(records, domain, challenge)
    timeout = int(os.environ.get("DNS_WEBHOOK_TIMEOUT", DEFAULT_TIMEOUT))
    last_error: Optional[str] = None

    for attempt in range(1, retries + 1):
        try:
            resp = requests.post(
                url,
                json=envelope,
                timeout=timeout,
                headers={"user-agent": "dstack-ingress/dnshook"},
            )
            if 200 <= resp.status_code < 300:
                print(f"DNS webhook accepted (HTTP {resp.status_code})", flush=True)
                return
            body = resp.text[:512]
            last_error = f"HTTP {resp.status_code}: {body}"
        except requests.RequestException as exc:
            last_error = str(exc)

        print(
            f"DNS webhook attempt {attempt}/{retries} failed: {last_error}",
            file=sys.stderr,
            flush=True,
        )
        if attempt < retries:
            time.sleep(2**attempt)

    raise RuntimeError(f"DNS webhook failed after {retries} attempts: {last_error}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="", help="override DNS_WEBHOOK_URL")
    parser.add_argument("--domain", required=True)
    parser.add_argument("--challenge", default="tls-alpn-01")
    parser.add_argument(
        "--records",
        required=True,
        help="JSON array of {type,name,value} objects",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="print the envelope instead of sending"
    )
    args = parser.parse_args()

    records: List[Dict[str, str]] = json.loads(args.records)
    if args.dry_run:
        print(json.dumps(build_envelope(records, args.domain, args.challenge), indent=2))
        return 0
    notify(records, args.domain, args.challenge, url=args.url or None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
