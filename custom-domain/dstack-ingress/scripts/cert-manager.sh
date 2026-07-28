#!/bin/bash
# cert-manager.sh - the single owner of the certificate lifecycle.
#
# There used to be two drivers: a `bootstrap` that ran once at startup and a
# renewal daemon that woke every 12 hours. Both ended up calling
# renew-certificate.sh, so they were the same operation with different
# preludes. That was harmless only because bootstrap finished before the daemon
# started -- an ordering that stopped holding once tls-alpn-01 forced bootstrap
# into the background (haproxy has to be listening before the first certificate
# can be issued). The two then raced: both ACME clients tried to bind the same
# challenge port, and the loser still spent one of Let's Encrypt's five failed
# validations per hostname per hour.
#
# So there is now one pass, used for both jobs. process_domain is idempotent --
# the DNS setters short-circuit when a record already holds the right value, the
# ACME account registration returns early when it exists, and the ACME client
# reports "no renewal needed" when the certificate is still fresh -- so the
# first pass and the ten-thousandth are the same code.
#
# Usage:
#   cert-manager.sh --once   run a single pass, exit with its status
#   cert-manager.sh          run passes forever

set -uo pipefail

source /scripts/functions.sh
source /scripts/domains.sh

# Self-sufficient rather than trusting the parent's exports, for the same
# reason domains.sh carries its own defaults.
if [ -z "${DSTACK_INSTANCE_ID:-}" ] || [ -z "${DSTACK_APP_ID:-}" ]; then
    load_dstack_identity
fi

RENEW_INTERVAL=${RENEW_INTERVAL:-43200}      # 12h between successful passes
RETRY_INTERVAL_MIN=${RETRY_INTERVAL_MIN:-60} # backoff floor after a failed pass
RETRY_INTERVAL_MAX=${RETRY_INTERVAL_MAX:-1800}

reload_haproxy() {
    if [ ! -f /var/run/haproxy/haproxy.pid ]; then
        # Normal during the dns-01 startup pass: haproxy has not been exec'd
        # yet, and it will read the fresh certificates when it starts.
        echo "HAProxy is not running yet; certificates will be picked up at start"
        return 0
    fi
    if kill -USR2 "$(cat /var/run/haproxy/haproxy.pid)"; then
        echo "HAProxy reloaded with the new certificates"
    else
        echo "HAProxy reload failed: SIGUSR2 to PID $(cat /var/run/haproxy/haproxy.pid) failed" >&2
        return 1
    fi
}

# One pass over every configured domain. Returns non-zero if any domain failed.
run_pass() {
    local all_domains domain failed=0 changed=0

    all_domains=$(get-all-domains.sh)
    if [ -z "$all_domains" ]; then
        echo "Error: No domains found. Set either DOMAIN or DOMAINS" >&2
        return 1
    fi

    local status
    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        # Subshell: the process_domain helpers `exit` on fatal misconfiguration,
        # which should fail this domain rather than kill the manager.
        ( process_domain "$domain" )
        status=$?
        # renew-certificate.sh reports 0 = certificate changed, 2 = nothing to
        # do, 1 = failure, and process_domain passes that through. Reloading
        # only on 0 is what keeps a quiet pass from churning haproxy.
        case $status in
            0) changed=1 ;;
            2) ;;
            *)
                echo "Certificate management failed for $domain" >&2
                failed=1
                ;;
        esac
    done <<<"$all_domains"

    if [ "$changed" -eq 1 ]; then
        generate-evidences.sh || echo "Evidence generation failed" >&2
        build-combined-pems.sh || echo "Combined PEM build failed" >&2
        reload_haproxy || true
    fi

    if [ "$failed" -eq 0 ]; then
        touch /.bootstrapped
        return 0
    fi
    return 1
}

if [ "${1:-}" = "--once" ]; then
    run_pass
    exit $?
fi

attempt=0
while true; do
    if run_pass; then
        attempt=0
        delay=$RENEW_INTERVAL
    else
        # Falling back to the 12-hour interval would be a terrible retry rate
        # for a flow whose normal state is "waiting for an operator to create a
        # DNS record". Back off, but stay responsive.
        attempt=$((attempt + 1))
        delay=$((RETRY_INTERVAL_MIN * attempt))
        [ "$delay" -gt "$RETRY_INTERVAL_MAX" ] && delay=$RETRY_INTERVAL_MAX
        echo "[$(date)] Pass failed (attempt ${attempt}); retrying in ${delay}s"
    fi
    echo "[$(date)] Next certificate check in ${delay}s"
    sleep "$delay"
done
