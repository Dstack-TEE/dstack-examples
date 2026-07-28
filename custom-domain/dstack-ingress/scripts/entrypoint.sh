#!/bin/bash
# entrypoint.sh - validate the settings both modes share, then hand over.
#
# There is no shared orchestration below this point: dns-01 and tls-alpn-01 have
# genuinely little in common (different ACME client, different on-disk layout,
# different DNS story, different proxy topology, different startup order), so
# each is its own program. What they truly share lives in the *-lib.sh files and
# is composed by the mode, not dispatched to.

set -e

source /scripts/functions.sh

PORT=${PORT:-443}
TXT_PREFIX=${TXT_PREFIX:-"_dstack-app-address"}
MAXCONN=${MAXCONN:-4096}
TIMEOUT_CONNECT=${TIMEOUT_CONNECT:-10s}
TIMEOUT_CLIENT=${TIMEOUT_CLIENT:-86400s}
TIMEOUT_SERVER=${TIMEOUT_SERVER:-86400s}
EVIDENCE_SERVER=${EVIDENCE_SERVER:-true}
EVIDENCE_PORT=${EVIDENCE_PORT:-80}
ALPN=${ALPN:-}
CHALLENGE_TYPE=${CHALLENGE_TYPE:-dns-01}

# ACME account settings, normalised once for both modes. What you are
# configuring is an ACME account, not a particular client -- which client
# implements a mode is an implementation detail, and this image already changed
# it once (certbot for dns-01, lego for tls-alpn-01). So ACME_EMAIL and
# ACME_STAGING are the names; CERTBOT_EMAIL and CERTBOT_STAGING are the
# historical ones and keep working.
#
# Normalising here rather than per mode is what fixes the real bug: ACME_STAGING
# used to be read only on the tls-alpn-01 path, so setting it under dns-01
# silently issued *production* certificates.
ACME_EMAIL=${ACME_EMAIL:-${CERTBOT_EMAIL:-}}
ACME_STAGING=${ACME_STAGING:-${CERTBOT_STAGING:-false}}

case "$CHALLENGE_TYPE" in
    dns-01|tls-alpn-01) ;;
    *)
        echo "Error: invalid CHALLENGE_TYPE '$CHALLENGE_TYPE' (expected dns-01 or tls-alpn-01)" >&2
        exit 1
        ;;
esac

if ! PORT=$(sanitize_port "$PORT"); then
    exit 1
fi
if ! DOMAIN=$(sanitize_domain "$DOMAIN"); then
    exit 1
fi
if ! TARGET_ENDPOINT=$(sanitize_target_endpoint "$TARGET_ENDPOINT"); then
    exit 1
fi
if ! TXT_PREFIX=$(sanitize_dns_label "$TXT_PREFIX"); then
    exit 1
fi
if ! MAXCONN=$(sanitize_positive_integer "$MAXCONN" "MAXCONN"); then
    exit 1
fi
if ! TIMEOUT_CONNECT=$(sanitize_haproxy_timeout "$TIMEOUT_CONNECT" "TIMEOUT_CONNECT"); then
    exit 1
fi
if ! TIMEOUT_CLIENT=$(sanitize_haproxy_timeout "$TIMEOUT_CLIENT" "TIMEOUT_CLIENT"); then
    exit 1
fi
if ! TIMEOUT_SERVER=$(sanitize_haproxy_timeout "$TIMEOUT_SERVER" "TIMEOUT_SERVER"); then
    exit 1
fi
if ! EVIDENCE_PORT=$(sanitize_positive_integer "$EVIDENCE_PORT" "EVIDENCE_PORT"); then
    exit 1
fi
if ! ALPN=$(sanitize_alpn "$ALPN"); then
    exit 1
fi

# Warn about deprecated L7 env vars
for var in CLIENT_MAX_BODY_SIZE PROXY_READ_TIMEOUT PROXY_SEND_TIMEOUT PROXY_CONNECT_TIMEOUT PROXY_BUFFER_SIZE PROXY_BUFFERS PROXY_BUSY_BUFFERS_SIZE; do
    if [ -n "${!var}" ]; then
        echo "Warning: $var is ignored in TCP proxy mode"
    fi
done

# Everything from here on belongs to one mode. Exported so the mode script and
# the helpers it invokes see the sanitized values.
export PORT DOMAIN DOMAINS TARGET_ENDPOINT ROUTING_MAP TXT_PREFIX MAXCONN
export TIMEOUT_CONNECT TIMEOUT_CLIENT TIMEOUT_SERVER EVIDENCE_SERVER EVIDENCE_PORT ALPN
export ACME_EMAIL ACME_STAGING

case "$CHALLENGE_TYPE" in
    dns-01)
        exec /scripts/dns01.sh "$@"
        ;;
    tls-alpn-01)
        exec /scripts/tlsalpn.sh "$@"
        ;;
    *)
        echo "Error: invalid CHALLENGE_TYPE '$CHALLENGE_TYPE' (expected dns-01 or tls-alpn-01)" >&2
        exit 1
        ;;
esac
