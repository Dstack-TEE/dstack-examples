#!/usr/bin/env python3
"""Guide the operator through the DNS records dstack-ingress needs.

In tls-alpn-01 mode the container holds no DNS credentials, so it cannot create
the CNAME / TXT / CAA records itself. Instead it computes exactly which records
are required, prints them, optionally pushes them to a webhook, and then waits
until they are observable in public DNS before letting certificate issuance
proceed.

Waiting matters more than it looks. If the TXT record is missing the gateway has
no route for the hostname, so the CA's connection never reaches this container
and the failure surfaces as an opaque timeout -- while still burning Let's
Encrypt's "failed validations" budget (5 per account per hostname per hour).

Resolution goes through DoH rather than the container resolver: it sidesteps
local caching and needs no extra package (python3-requests is already present).
This is a convenience check for operator workflow, not a security control -- the
authoritative CAA evaluation is the CA's own, at issuance time.
"""

import argparse
import json
import os
import sys
import time
from dataclasses import dataclass, asdict
from typing import Dict, List, Optional, Sequence, Tuple

import requests

# Two independent resolvers, because one is not enough to trust either answer.
# Observed while testing this: a resolver that was asked for a CAA record before
# the record existed kept serving the negative answer well past the record's
# TTL, while the other resolver already had it. A single resolver would have
# reported "no CAA, issuance unrestricted" for a name that in fact restricted
# issuance -- exactly the check we cannot afford to get wrong.
#
# So the two record classes are read with opposite quorums:
#   propagation checks (CNAME, TXT) require *every* resolver to agree, which is
#     what "wait until it is really out there" means;
#   the CAA permission check takes the *union*, so any resolver seeing a
#     restriction is enough to stop us.
DEFAULT_DOH = "https://dns.google/resolve,https://cloudflare-dns.com/dns-query"
DEFAULT_TIMEOUT = 1800
DEFAULT_INTERVAL = 15
QUERY_TIMEOUT = 10

RR_A = 1
RR_CNAME = 5
RR_TXT = 16
RR_AAAA = 28
RR_CAA = 257

LE_ISSUER = "letsencrypt.org"


@dataclass
class Record:
    """A DNS record the operator has to create."""

    type: str
    name: str
    value: str
    note: str = ""
    # A CNAME the operator points at the gateway may legitimately be flattened
    # to an address record, so check_alias accepts either. A delegation CNAME
    # cannot: its target holds only a TXT, so there is no address to compare
    # and the record has to be the CNAME itself.
    exact: bool = False


class ResolveError(RuntimeError):
    """A DoH query failed in a way that is not simply "no such record"."""


def doh_query(name: str, rr_type: int, resolver: str) -> List[str]:
    """Return the rdata strings for name/type, or [] when there are none."""
    try:
        resp = requests.get(
            resolver,
            params={"name": name, "type": str(rr_type)},
            headers={"accept": "application/dns-json"},
            timeout=QUERY_TIMEOUT,
        )
    except requests.RequestException as exc:
        raise ResolveError(f"DoH query for {name} failed: {exc}") from exc

    if resp.status_code != 200:
        raise ResolveError(f"DoH query for {name} returned HTTP {resp.status_code}")

    try:
        payload = resp.json()
    except ValueError as exc:
        raise ResolveError(f"DoH response for {name} is not JSON: {exc}") from exc

    # Status 3 is NXDOMAIN: a definite "no such name", not an error for us.
    status = payload.get("Status")
    if status not in (0, 3):
        raise ResolveError(f"DoH query for {name} returned DNS status {status}")

    answers = payload.get("Answer") or []
    return [a["data"] for a in answers if a.get("type") == rr_type and "data" in a]


def split_resolvers(spec: str) -> List[str]:
    return [r.strip() for r in spec.split(",") if r.strip()]


def query_per_resolver(name: str, rr_type: int, resolvers: str) -> List[Tuple[str, List[str]]]:
    """Query every resolver; raise only if none of them answered."""
    results = []
    errors = []
    for resolver in split_resolvers(resolvers):
        try:
            results.append((resolver, doh_query(name, rr_type, resolver)))
        except ResolveError as exc:
            errors.append(str(exc))
    if not results:
        raise ResolveError("; ".join(errors) or f"no resolvers configured for {name}")
    return results


def query_union(name: str, rr_type: int, resolvers: str) -> List[str]:
    seen: List[str] = []
    for _resolver, values in query_per_resolver(name, rr_type, resolvers):
        for value in values:
            if value not in seen:
                seen.append(value)
    return seen


def _unquote_txt(value: str) -> str:
    """Normalise TXT rdata, which resolvers hand back quoted and possibly split."""
    value = value.strip()
    if value.startswith('"') and value.endswith('"'):
        value = value[1:-1]
    # A long TXT value arrives as several quoted chunks that concatenate.
    return value.replace('" "', "")


def _fqdn(name: str) -> str:
    return name.rstrip(".").lower()


def check_txt(record: Record, resolvers: str) -> Tuple[bool, str]:
    lagging = []
    observed: List[str] = []
    for resolver, raw in query_per_resolver(record.name, RR_TXT, resolvers):
        values = [_unquote_txt(v) for v in raw]
        observed.extend(v for v in values if v not in observed)
        if record.value not in values:
            lagging.append(resolver)
    if not lagging:
        return True, "ok"
    if not observed:
        return False, f"no TXT record found (checked {len(lagging)} resolver(s))"
    return False, (
        f"TXT present but wrong value: {observed!r} (want {record.value!r})"
        if len(lagging) == len(split_resolvers(resolvers))
        else f"not yet propagated to {', '.join(lagging)} (saw {observed!r})"
    )


def check_cname_exact(record: Record, resolvers: str) -> Tuple[bool, str]:
    """Verify a CNAME points at exactly this target, with no address fallback."""
    target = _fqdn(record.value)
    cnames = [_fqdn(v) for v in query_union(record.name, RR_CNAME, resolvers)]
    if target in cnames:
        return True, "ok (CNAME)"
    if cnames:
        return False, f"CNAME points at {cnames!r}, expected {target!r}"
    return False, "no CNAME record found"


def check_alias(record: Record, resolvers: str) -> Tuple[bool, str]:
    """Verify the hostname ends up at the gateway.

    Accepts either a CNAME pointing at the gateway or an address record whose
    value matches one of the gateway's, so a flattened / ALIAS record at a zone
    apex is not rejected.
    """
    target = _fqdn(record.value)

    cnames = [_fqdn(v) for v in query_union(record.name, RR_CNAME, resolvers)]
    if target in cnames:
        return True, "ok (CNAME)"

    own_addrs = set(query_union(record.name, RR_A, resolvers)) | set(
        query_union(record.name, RR_AAAA, resolvers)
    )
    if not own_addrs:
        return False, "hostname does not resolve yet"

    gw_addrs = set(query_union(target, RR_A, resolvers)) | set(
        query_union(target, RR_AAAA, resolvers)
    )
    if gw_addrs and own_addrs & gw_addrs:
        return True, "ok (address matches gateway)"
    if cnames:
        return False, f"CNAME points at {cnames!r}, expected {target!r}"
    return False, (
        f"resolves to {sorted(own_addrs)!r} which does not match the gateway "
        f"{sorted(gw_addrs)!r}"
    )


def _parse_caa(rdata: str) -> Optional[Tuple[int, str, str]]:
    """Parse CAA rdata in either form a DoH resolver may hand back.

    Google returns presentation format -- `0 issue "letsencrypt.org;..."`.
    Cloudflare returns RFC 3597 generic format -- `\\# 47 00 05 69 73 73 75 65
    ...` -- i.e. the length followed by hex octets of the wire encoding. Parsing
    only the first shape silently degrades a "CAA forbids this" answer into "no
    CAA found", which is the wrong direction to fail in.
    """
    rdata = rdata.strip()

    if rdata.startswith("\\#"):
        # wire format: flags(1) tag-length(1) tag(tag-length) value(rest)
        try:
            raw = bytes.fromhex("".join(rdata.split()[2:]))
        except ValueError:
            return None
        if len(raw) < 2:
            return None
        flags, tag_len = raw[0], raw[1]
        tag = raw[2 : 2 + tag_len].decode("ascii", "replace").lower()
        value = raw[2 + tag_len :].decode("utf-8", "replace")
        return flags, tag, value

    parts = rdata.split(None, 2)
    if len(parts) != 3:
        return None
    flags_s, tag, value = parts
    try:
        flags = int(flags_s)
    except ValueError:
        return None
    return flags, tag.lower(), value.strip().strip('"')


def _caa_permits(value: str, tag: str, want_method: str, account_uri: str) -> Tuple[bool, str]:
    """Does one CAA value allow us to issue via want_method for account_uri?"""
    fields = [f.strip() for f in value.split(";")]
    issuer = _fqdn(fields[0]) if fields else ""
    if issuer != LE_ISSUER:
        return False, f"{tag} allows {issuer!r}, not {LE_ISSUER}"

    params: Dict[str, str] = {}
    for field in fields[1:]:
        if "=" in field:
            k, v = field.split("=", 1)
            params[k.strip().lower()] = v.strip()

    methods = params.get("validationmethods")
    if methods is not None:
        allowed = {m.strip() for m in methods.split(",")}
        if want_method not in allowed:
            return False, (
                f"{tag} restricts validationmethods to {sorted(allowed)}, "
                f"which excludes {want_method}"
            )

    uri = params.get("accounturi")
    if uri is not None and account_uri and uri != account_uri:
        return False, f"{tag} pins accounturi={uri}, but this container's account is {account_uri}"

    return True, "ok"


def check_caa(
    domain: str,
    want_tag: str,
    want_method: str,
    account_uri: str,
    resolvers: str,
    require_present: bool = False,
) -> Tuple[bool, str]:
    """Check CAA for domain, walking up to the closest ancestor that has one.

    An absent CAA record set means every CA may issue (RFC 8659), so "no CAA
    anywhere" is normally a pass: we are asking whether *we* may issue, and
    nothing forbids it.

    `require_present` inverts that for challenge delegation, where the question
    is different. There the record is not a formality but the only thing stopping
    someone else who can satisfy the delegated challenge from getting a
    certificate for this name, and we hold no token to create it ourselves. An
    unrestricted name is exactly the state that must block.
    """
    labels = _fqdn(domain).split(".")
    for i in range(len(labels) - 1):
        candidate = ".".join(labels[i:])
        # Union: one resolver seeing a restriction is enough to honour it.
        rdatas = query_union(candidate, RR_CAA, resolvers)
        # Deduplicate after parsing, not before: resolvers disagree on the wire
        # format (one returns presentation form, another RFC 3597 generic hex),
        # so the same record arrives as two distinct strings and would otherwise
        # be reported, and counted, twice.
        parsed = []
        for rdata in rdatas:
            record = _parse_caa(rdata)
            if record is not None and record not in parsed:
                parsed.append(record)
        relevant = [p for p in parsed if p[1] == want_tag]
        if not parsed:
            continue  # keep climbing; this level has no CAA record set

        # This is the closest CAA record set; it is the one that governs.
        if not relevant:
            return False, (
                f"{candidate} has a CAA record set but no {want_tag} tag, "
                f"which forbids issuance"
            )
        reasons = []
        for _flags, tag, value in relevant:
            ok, reason = _caa_permits(value, tag, want_method, account_uri)
            if ok:
                return True, f"ok (from {candidate})"
            reasons.append(reason)
        return False, f"CAA at {candidate} does not permit issuance: {'; '.join(reasons)}"

    if require_present:
        return False, (
            "no CAA record set, so any account that can satisfy the delegated "
            "challenge could obtain a certificate for this name"
        )
    return True, "ok (no CAA record set; issuance is unrestricted)"


def render(records: Sequence[Record], domain: str) -> str:
    width = 74
    lines = [
        "",
        "=" * width,
        f"  DNS records required for {domain}",
        "=" * width,
        "  This container holds no DNS credentials, so you must create these",
        "  records yourself. Certificate issuance waits until they are visible.",
        "",
    ]
    for rec in records:
        lines.append(f"  {rec.type:<6} {rec.name}")
        lines.append(f"  {'':<6} -> {rec.value}")
        if rec.note:
            lines.append(f"  {'':<6}    ({rec.note})")
        lines.append("")
    lines.append("=" * width)
    lines.append("")
    return "\n".join(lines)


def verify_once(
    records: Sequence[Record],
    domain: str,
    caa_tag: str,
    caa_method: str,
    account_uri: str,
    resolvers: str,
    caa_advisory: bool = False,
    caa_required: bool = False,
) -> List[Tuple[str, bool, str]]:
    results = []
    for rec in records:
        if rec.type == "TXT":
            ok, why = check_txt(rec, resolvers)
            results.append((f"TXT {rec.name}", ok, why))
        elif rec.type == "CNAME":
            if rec.exact:
                ok, why = check_cname_exact(rec, resolvers)
            else:
                ok, why = check_alias(rec, resolvers)
            results.append((f"CNAME {rec.name}", ok, why))
    ok, why = check_caa(
        domain, caa_tag, caa_method, account_uri, resolvers, caa_required
    )
    if not ok and caa_advisory:
        results.append((f"CAA {domain}", True, f"WARNING: {why} (continuing: CAA is advisory)"))
    else:
        results.append((f"CAA {domain}", ok, why))
    return results


def build_records(args: argparse.Namespace) -> List[Record]:
    include = {part.strip() for part in args.include.split(",") if part.strip()}
    records = []
    if "cname" in include:
        records.append(
            Record(
                type="CNAME",
                name=args.domain.lstrip("*."),
                value=args.alias_target,
                note="points the hostname at the dstack gateway",
            )
        )
    if "txt" in include:
        records.append(
            Record(
                type="TXT",
                name=args.txt_name,
                value=args.txt_value,
                note="tells the gateway which instance to route this hostname to",
            )
        )
    if "delegated" in include and args.challenge_alias:
        # Full delegation: every name this deployment needs is aliased into a
        # zone the container can write, so the operator creates these three once
        # and never touches DNS again -- not when the app id changes, not when
        # the ACME account changes, not when the gateway moves.
        #
        # Each is exact: the target holds only what we put there, so there is no
        # address to fall back to and a wrong target must be reported as wrong
        # rather than as "does not resolve".
        base = args.domain[2:] if args.domain.startswith("*.") else args.domain
        alias = args.challenge_alias
        wanted = [
            (args.domain, "routes traffic for this hostname into the delegated zone"),
            (args.txt_name, "lets the container publish the gateway routing target"),
            (f"_acme-challenge.{base}", "delegates the ACME challenge"),
        ]
        if args.domain.startswith("*."):
            # RFC 8659 evaluates CAA for *.example.com at example.com, not at the
            # wildcard, so the base needs its own alias for the CAA to be
            # delegated too. Verified: with this in place the CA followed it and
            # honoured an issuewild record in the delegated zone.
            #
            # The base has to be aliasable, which a zone apex is not (SOA and
            # NS live there and a CNAME excludes them), so `*.example.com`
            # served straight off its own zone is not a fit for delegation.
            wanted.insert(1, (base, "delegates CAA, which a wildcard is evaluated at"))
        for name, note in wanted:
            records.append(
                Record(
                    type="CNAME",
                    name=name,
                    value=f"{name}.{alias}" if name != args.domain else f"{base}.{alias}",
                    note=note,
                    exact=True,
                )
            )
    if "challenge-cname" in include and args.challenge_alias:
        # Challenge delegation: the CA follows this CNAME when it looks for
        # _acme-challenge, so the TXT can live in a zone whose token we hold and
        # the served zone never needs one. certbot validates at the base name
        # even for a wildcard, so strip "*." here too.
        base = args.domain[2:] if args.domain.startswith("*.") else args.domain
        records.append(
            Record(
                type="CNAME",
                name=f"_acme-challenge.{base}",
                value=f"_acme-challenge.{base}.{args.challenge_alias}",
                note="delegates the ACME challenge to a zone this container can write",
                exact=True,
            )
        )
    if "caa" in include and args.caa_value:
        note = "optional; restricts issuance for this name to Let's Encrypt"
        if args.account_uri:
            note = "optional, but pins issuance to this enclave's ACME account"
        records.append(
            Record(
                type="CAA",
                name=args.caa_name,
                value=f'0 {args.caa_tag} "{args.caa_value}"',
                note=note,
            )
        )
    return records


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--domain", default="")
    parser.add_argument("--alias-target", default="", help="gateway domain")
    parser.add_argument("--txt-name", default="")
    parser.add_argument("--txt-value", default="")
    parser.add_argument("--caa-name", default="")
    parser.add_argument("--caa-tag", default="issue", choices=["issue", "issuewild"])
    parser.add_argument("--caa-value", default="")
    parser.add_argument("--account-uri", default="")
    parser.add_argument("--challenge", default="tls-alpn-01")
    parser.add_argument(
        "--challenge-alias",
        default=os.environ.get("DELEGATION_ZONE", ""),
        help="delegation zone for the _acme-challenge CNAME (dns-01 delegation)",
    )
    parser.add_argument(
        "--caa-required",
        action="store_true",
        help="treat an absent CAA record set as a failure (challenge delegation: "
             "the record is the only protection and we cannot create it)",
    )
    parser.add_argument(
        "--caa-advisory",
        action="store_true",
        help="report a failing CAA check as a warning instead of blocking",
    )
    parser.add_argument(
        "--mode",
        default=os.environ.get("DNS_SETUP_MODE", "wait"),
        choices=["wait", "print", "webhook"],
    )
    parser.add_argument("--timeout", type=int, default=int(os.environ.get("DNS_SETUP_TIMEOUT", DEFAULT_TIMEOUT)))
    parser.add_argument("--interval", type=int, default=int(os.environ.get("DNS_SETUP_INTERVAL", DEFAULT_INTERVAL)))
    parser.add_argument(
        "--resolver",
        default=os.environ.get("DOH_RESOLVERS", os.environ.get("DOH_RESOLVER", DEFAULT_DOH)),
        help="comma-separated DoH endpoints",
    )
    parser.add_argument(
        "--resolve",
        default="",
        help="print the A records for a name and exit (used to publish the "
             "gateway address into a delegated zone)",
    )
    parser.add_argument("--json", action="store_true", help="also emit the records as JSON")
    parser.add_argument(
        "--include",
        default="cname,txt,caa",
        help="comma-separated subset of records to handle "
             "(cname,txt,caa,challenge-cname,delegated)",
    )
    args = parser.parse_args()

    if not args.resolve:
        missing = [n for n, v in (("--domain", args.domain),
                                  ("--alias-target", args.alias_target),
                                  ("--txt-name", args.txt_name),
                                  ("--txt-value", args.txt_value)) if not v]
        if missing:
            parser.error(f"{', '.join(missing)} required unless --resolve is given")

    if args.resolve:
        # Address lookup for callers that need to publish an A record rather
        # than a CNAME. Same resolvers, same union semantics as everything else.
        for addr in query_union(args.resolve, RR_A, args.resolver):
            print(addr)
        return 0

    if not args.caa_name:
        args.caa_name = args.domain.lstrip("*.")

    records = build_records(args)
    print(render(records, args.domain), flush=True)
    if args.json:
        print(json.dumps([asdict(r) for r in records], indent=2), flush=True)

    if args.mode == "webhook":
        # Imported lazily so `print`/`wait` do not depend on the hook module.
        import dnshook

        try:
            dnshook.notify(records, domain=args.domain, challenge=args.challenge)
        except Exception as exc:  # noqa: BLE001 - a hook failure must not be fatal
            print(f"Warning: DNS webhook notification failed: {exc}", file=sys.stderr, flush=True)
            print("Continuing; the records above still have to exist.", file=sys.stderr, flush=True)

    if args.mode == "print":
        print("DNS_SETUP_MODE=print: not verifying, continuing immediately.", flush=True)
        return 0

    deadline = time.monotonic() + args.timeout
    attempt = 0
    while True:
        attempt += 1
        try:
            results = verify_once(
                records, args.domain.lstrip("*."), args.caa_tag, args.challenge,
                args.account_uri, args.resolver, args.caa_advisory,
                args.caa_required,
            )
        except ResolveError as exc:
            print(f"[dns-check #{attempt}] resolver problem: {exc}", flush=True)
            results = []

        if results and all(ok for _, ok, _ in results):
            print(f"[dns-check #{attempt}] all records verified:", flush=True)
            for label, _, why in results:
                print(f"    OK   {label}: {why}", flush=True)
            return 0

        for label, ok, why in results:
            print(f"[dns-check #{attempt}] {'OK  ' if ok else 'WAIT'} {label}: {why}", flush=True)

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            print(
                f"Error: DNS records were not visible within {args.timeout}s. "
                f"Create the records above, or set DNS_SETUP_MODE=print to skip this check.",
                file=sys.stderr,
                flush=True,
            )
            return 1
        time.sleep(min(args.interval, max(1, int(remaining))))


if __name__ == "__main__":
    sys.exit(main())
