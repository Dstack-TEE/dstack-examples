#!/bin/bash
# certbot --manual auth/cleanup hook for ACME DNS-01 challenge delegation.
#
# Instead of writing the `_acme-challenge` TXT into the served domain's own
# zone (which requires a DNS token for that zone), this writes it into a
# delegated zone that our token controls (DELEGATION_ZONE). The served
# domain's zone only needs one static, operator-managed CNAME:
#
#   _acme-challenge.<domain>  CNAME  _acme-challenge.<domain>.<DELEGATION_ZONE>
#
# Let's Encrypt follows that CNAME during validation and reads the TXT from the
# delegated zone, so the enclave's token never needs access to the served
# domain's (production) zone.
#
# certbot invokes this with $CERTBOT_DOMAIN and $CERTBOT_VALIDATION set, and
# runs it as either:  acme-dns-alias-hook.sh auth  |  acme-dns-alias-hook.sh cleanup
set -euo pipefail

action="${1:-}"

zone="${DELEGATION_ZONE:-}"
if [ -z "$zone" ]; then
    echo "acme-dns-alias-hook: DELEGATION_ZONE is not set" >&2
    exit 1
fi
if [ -z "${CERTBOT_DOMAIN:-}" ]; then
    echo "acme-dns-alias-hook: CERTBOT_DOMAIN not set (must be invoked by certbot)" >&2
    exit 1
fi

# certbot always passes the base domain (no leading "*.") in CERTBOT_DOMAIN.
record="_acme-challenge.${CERTBOT_DOMAIN}.${zone}"

case "$action" in
    auth)
        : "${CERTBOT_VALIDATION:?CERTBOT_VALIDATION not set}"
        echo "acme-dns-alias-hook: writing challenge TXT to delegated record $record"
        dnsman.py set_txt --domain "$record" --content "$CERTBOT_VALIDATION"
        # certbot asks Let's Encrypt to validate immediately after this hook
        # returns, so wait for the record to propagate before returning.
        #
        # This has to outlast the record's own TTL, not just the time the write
        # takes. dnsman.py publishes TXT with a 60s TTL, so a resolver that saw
        # the *previous* challenge value keeps serving it for up to that long --
        # which is exactly the situation on the second of the two issuance
        # attempts. At 30s Let's Encrypt's multi-perspective check fails with
        # "During secondary validation: Incorrect TXT record found". The dns-01
        # plugin path waits 120s for the same reason.
        sleep "${ACME_CHALLENGE_PROPAGATION_SECONDS:-120}"
        ;;
    cleanup)
        echo "acme-dns-alias-hook: removing challenge TXT $record"
        # Non-fatal: a failed cleanup leaves a stale TXT in the delegated zone,
        # which the next auth overwrites; it must not fail the whole run.
        dnsman.py unset_txt --domain "$record" || true
        ;;
    *)
        echo "acme-dns-alias-hook: usage: $0 <auth|cleanup>" >&2
        exit 1
        ;;
esac
