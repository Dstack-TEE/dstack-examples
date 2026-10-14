#!/usr/bin/env python3
"""Certificate management for the tls-alpn-01 path, backed by lego.

certbot is not usable here. Its standalone plugin is HTTP-01 only, the
maintainers declined to add tls-alpn-01 (certbot/certbot#6724), and the acme
library dropped the challenge entirely in 4.2.0 -- the last release carrying
`acme.standalone.TLSALPN01Server` is 4.1.1, where it is already marked
deprecated. Building on that would mean pinning both `certbot` and `acme` to a
deleted, unmaintained API inside a component whose whole job is TLS.

lego implements tls-alpn-01 as a first-class challenge and ships as a single
static binary. It binds a loopback address (`--tls.address`); haproxy forwards
only `acme-tls/1` ClientHellos there, so issuance never disturbs serving
traffic.

Targets the lego 5.x CLI, which differs from 4.x in ways that matter here:
`renew` folded into `run --renew-days`, `--tls.port` became `--tls.address`,
flags moved from global to per-command, and the account document renamed
`registration.uri` to `registration.accountURL`. 5.x also added
`accounts register`, which lets us create the account -- and therefore know its
URI -- before the first certificate exists, so the CAA record can be printed
with `accounturi` up front.

The dns-01 path still runs certbot via certman.py; nothing here touches it.
"""

import argparse
import json
import os
import subprocess
import sys
from typing import List, Optional, Tuple
from urllib.parse import urlparse

import deterministic_key

LEGO_BIN = os.environ.get("LEGO_BIN", "/usr/local/bin/lego")
LEGO_PATH = os.environ.get("LEGO_PATH", "/etc/letsencrypt/lego")
ACME_PROD = "https://acme-v02.api.letsencrypt.org/directory"
ACME_STAGING = "https://acme-staging-v02.api.letsencrypt.org/directory"
# lego's account directory name when there is no email.
NO_EMAIL_ACCOUNT = "noemail@example.com"

# Exit codes: 0 changed, 2 nothing to do, 1 failed. The caller reloads on 0.
EXIT_CHANGED = 0
EXIT_ERROR = 1
EXIT_UNCHANGED = 2

RUN_TIMEOUT = 600
REGISTER_TIMEOUT = 120


def acme_server() -> str:
    # Same override as certman.py, for local test servers such as Pebble.
    custom = os.environ.get("ACME_DIRECTORY_URL", "").strip()
    if custom:
        return custom
    # CERTBOT_STAGING is the historical name and still works, but there is no
    # certbot on this path: the ACME client here is lego.
    staging = os.environ.get("ACME_STAGING") or os.environ.get("CERTBOT_STAGING", "false")
    return ACME_STAGING if staging == "true" else ACME_PROD


def server_dir() -> str:
    """lego namespaces account storage by the CA host (plus port, if any)."""
    parsed = urlparse(acme_server())
    host = parsed.hostname or "acme"
    return f"{host}_{parsed.port}" if parsed.port else host


def account_file(email: str) -> str:
    """The account `lego run` uses: lego keys accounts by server and email, with
    a placeholder of its own when there is no email.

    Any other account in the directory -- one for a previous ACME_EMAIL, say --
    is not the one issuing, so publishing it would name the wrong account.
    """
    return os.path.join(LEGO_PATH, "accounts", server_dir(),
                        email or NO_EMAIL_ACCOUNT, "account.json")


def account_uri(email: str) -> Optional[str]:
    path = account_file(email)
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as exc:
        print(f"Warning: cannot read lego account file {path}: {exc}", file=sys.stderr)
        return None
    registration = data.get("registration") or {}
    # lego 5.x renamed this from "uri"; accept both so a directory written by an
    # older binary still resolves.
    return registration.get("accountURL") or registration.get("uri")


def cert_paths(domain: str) -> Tuple[str, str]:
    base = os.path.join(LEGO_PATH, "certificates", domain)
    return f"{base}.crt", f"{base}.key"


def certificate_exists(domain: str) -> bool:
    crt, key = cert_paths(domain)
    return os.path.isfile(crt) and os.path.isfile(key)


def _renewed_marker(domain: str) -> str:
    return os.path.join(LEGO_PATH, f".renewed-{domain}")


def _common_flags(email: str) -> List[str]:
    flags = ["--path", LEGO_PATH, "--server", acme_server(), "--accept-tos"]
    # The ACME contact address is optional (RFC 8555 §7.3), and Let's Encrypt
    # stopped sending expiry notifications in 2025, so it buys little. It is
    # also published: the account document is served as evidence, so an address
    # set here becomes public. Omit it unless the operator wants it.
    if email:
        flags += ["--email", email]
    return flags


def _run(cmd: List[str], timeout: int = RUN_TIMEOUT) -> Tuple[int, str]:
    masked = [
        arg if not (i > 0 and cmd[i - 1] in ("--email", "-m")) else "<email>"
        for i, arg in enumerate(cmd)
    ]
    print(f"Executing: {' '.join(masked)}", flush=True)
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"lego timed out after {timeout}s", file=sys.stderr)
        return 124, ""
    output = (result.stdout or "") + (result.stderr or "")
    for line in output.strip().splitlines():
        print(f"  lego| {line}", flush=True)
    return result.returncode, output


def register(email: str) -> int:
    """Create the ACME account without issuing anything."""
    if os.path.isfile(account_file(email)):
        print("ACME account already exists")
        return EXIT_UNCHANGED

    print("Registering ACME account")
    code, _ = _run(
        [LEGO_BIN, "accounts", "register"] + _common_flags(email),
        timeout=REGISTER_TIMEOUT,
    )
    if code == 0 and os.path.isfile(account_file(email)):
        print("✓ ACME account registered")
        return EXIT_CHANGED
    print(f"✗ ACME account registration failed (exit code {code})", file=sys.stderr)
    return EXIT_ERROR


def _challenge_flags() -> List[str]:
    address = os.environ.get("TLSALPN_ADDRESS", "127.0.0.1")
    port = os.environ.get("TLSALPN_PORT", "9443")
    return ["--tls", "--tls.address", f"{address}:{port}"]


def run_cert(domain: str, email: str) -> int:
    """`lego run` both obtains and renews, deciding by remaining lifetime."""
    if domain.startswith("*."):
        print(
            f"Error: cannot issue a wildcard certificate for {domain} with tls-alpn-01. "
            f"RFC 8737 forbids it; use CHALLENGE_TYPE=dns-01 for wildcards.",
            file=sys.stderr,
        )
        return EXIT_ERROR

    # Let lego decide whether a renewal is due: it consults the CA's ARI
    # endpoint (RFC 9773) as well as the local window, and the CA can ask for
    # early renewal during an incident. Deciding here from notAfter would
    # override that.
    #
    # We only need to know whether it acted, and lego says so itself:
    # --deploy-hook runs "in cases where a certificate is successfully
    # created/renewed" and stays silent otherwise. That beats inferring it --
    # matching log text is not stable (4.x wrote "no renewal", 5.x writes
    # "Skip renewal"), and the exit code is 0 either way.
    marker = _renewed_marker(domain)
    if os.path.exists(marker):
        os.remove(marker)

    crt, key_file = cert_paths(domain)
    key = None
    target = ["--domains", domain]
    if deterministic_key.enabled():
        # With --csr lego renews on its usual schedule but never rewrites the
        # .key file, so it is kept in step below.
        key = deterministic_key.private_key(domain)
        base = os.path.join(LEGO_PATH, "deterministic", domain)
        deterministic_key.write_file(f"{base}.csr", deterministic_key.csr_pem(key, domain))
        deterministic_key.write_file(f"{base}.key", deterministic_key.key_pem(key))
        target = ["--csr", f"{base}.csr", "--private-key", f"{base}.key"]
        if certificate_exists(domain) and not deterministic_key.cert_matches(crt, key):
            print(f"Certificate for {domain} does not carry the derived key, re-issuing")
            target.append("--renew-force")

    cmd = (
        [LEGO_BIN, "run"]
        + _common_flags(email)
        + target
        + _challenge_flags()
        + ["--deploy-hook", f"touch {marker}"]
    )
    renew_days = os.environ.get("RENEW_DAYS_BEFORE", "")
    if renew_days:
        cmd += ["--renew-days", renew_days]

    print(f"{'Renewing' if certificate_exists(domain) else 'Obtaining'} certificate for {domain} via tls-alpn-01")
    code, _ = _run(cmd)
    if code != 0:
        print(f"✗ lego failed for {domain} (exit code {code})", file=sys.stderr)
        return EXIT_ERROR
    if not certificate_exists(domain):
        print(f"✗ lego reported success but no certificate for {domain}", file=sys.stderr)
        return EXIT_ERROR

    key_rewritten = False
    if key is not None:
        if not deterministic_key.cert_matches(crt, key):
            print(f"✗ Certificate for {domain} does not carry the derived key", file=sys.stderr)
            return EXIT_ERROR
        pem = deterministic_key.key_pem(key)
        with open(key_file, "rb") as fh:
            key_rewritten = fh.read() != pem
        if key_rewritten:
            deterministic_key.write_file(key_file, pem)

    renewed = os.path.exists(marker)
    if renewed:
        os.remove(marker)
    if not renewed and not key_rewritten:
        print(f"Certificate for {domain} is still current; nothing to do")
        return EXIT_UNCHANGED

    print(f"✓ Certificate ready for {domain}")
    return EXIT_CHANGED


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=["obtain", "renew", "auto", "register", "account-uri", "account-file",
                 "cert-path"],
    )
    parser.add_argument("--domain", help="Domain name")
    parser.add_argument("--email", help="Email for ACME registration")
    args = parser.parse_args()

    email = args.email or os.environ.get("ACME_EMAIL") or os.environ.get("CERTBOT_EMAIL", "")

    if args.action == "account-uri":
        uri = account_uri(email)
        if not uri:
            return EXIT_ERROR
        print(uri)
        return EXIT_CHANGED

    if args.action == "account-file":
        path = account_file(email)
        if not os.path.isfile(path):
            print(f"Error: lego account file not found at {path}", file=sys.stderr)
            return EXIT_ERROR
        print(path)
        return EXIT_CHANGED

    if args.action == "cert-path":
        if not args.domain:
            print("Error: --domain is required", file=sys.stderr)
            return EXIT_ERROR
        crt, key = cert_paths(args.domain)
        print(f"{crt} {key}")
        return EXIT_CHANGED

    if not os.path.isfile(LEGO_BIN):
        print(f"Error: lego binary not found at {LEGO_BIN}", file=sys.stderr)
        return EXIT_ERROR

    os.makedirs(LEGO_PATH, exist_ok=True)

    if args.action == "register":
        code = register(email)
        # "already registered" is success for callers that just need it to exist.
        return EXIT_CHANGED if code == EXIT_UNCHANGED else code

    if not args.domain:
        print("Error: --domain is required", file=sys.stderr)
        return EXIT_ERROR

    # obtain / renew / auto all map onto `lego run`, which decides for itself.
    return run_cert(args.domain, email)


if __name__ == "__main__":
    sys.exit(main())
