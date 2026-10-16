#!/bin/bash
# entrypoint.sh - validate the settings both modes share, then hand over.
#
# There is no shared orchestration below this point: dns-01 and tls-alpn-01 have
# genuinely little in common (different ACME client, different on-disk layout,
# different DNS story, different proxy topology, different startup order), so
# each is its own program. What they truly share lives in the *-lib.sh files and
# is composed by the mode, not dispatched to.

set -e

# Identify the build first, so the line is there even if validation below
# fails. The same values are in the image labels and manifest annotations.
if [ -r /etc/dstack-ingress/build-info ]; then
    awk -F= '{ key = $1; sub(/^[^=]*=/, ""); info[key] = $0 }
             END { print "dstack-ingress " info["org.opencontainers.image.version"] \
                         " revision " info["org.opencontainers.image.revision"] \
                         " source " info["org.opencontainers.image.source"] }' \
        /etc/dstack-ingress/build-info
fi

source /scripts/functions.sh
source /scripts/haproxy-lib.sh

PORT=${PORT:-443}
TXT_PREFIX=${TXT_PREFIX:-"_dstack-app-address"}
MAXCONN=${MAXCONN:-4096}
TIMEOUT_CONNECT=${TIMEOUT_CONNECT:-10s}
TIMEOUT_CLIENT=${TIMEOUT_CLIENT:-86400s}
TIMEOUT_SERVER=${TIMEOUT_SERVER:-86400s}
EVIDENCE_SERVER=${EVIDENCE_SERVER:-true}
EVIDENCE_PORT=${EVIDENCE_PORT:-80}
ALPN=${ALPN:-}
ACCEPT_PROXY_PROTOCOL=${ACCEPT_PROXY_PROTOCOL:-false}
SEND_PROXY_PROTOCOL=${SEND_PROXY_PROTOCOL:-false}
CHALLENGE_TYPE=${CHALLENGE_TYPE:-dns-01}
RENEW_INTERVAL=${RENEW_INTERVAL:-43200}
RENEW_DAYS_BEFORE=${RENEW_DAYS_BEFORE:-}
DNS_SETUP_TIMEOUT=${DNS_SETUP_TIMEOUT:-1800}
DNS_SETUP_INTERVAL=${DNS_SETUP_INTERVAL:-15}
DNS_SETUP_MODE=${DNS_SETUP_MODE:-wait}
DETERMINISTIC_TLS_KEY=${DETERMINISTIC_TLS_KEY:-false}

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
all_domains=$(get-all-domains.sh || true)
if [ -z "$all_domains" ]; then
    echo "Error: no domain configured; set DOMAIN or DOMAINS" >&2
    exit 1
fi
# DOMAINS reaches file paths and certificate requests unchecked, so every
# entry has to pass the same check as DOMAIN.
while IFS= read -r domain; do
    if ! sanitize_domain "$domain" >/dev/null; then
        exit 1
    fi
done <<<"$all_domains"
if ! TARGET_ENDPOINT=$(sanitize_target_endpoint "$TARGET_ENDPOINT"); then
    exit 1
fi
# Without one of these haproxy has no default backend and closes every
# connection that is not for the evidence server.
if [ -z "${ROUTING_MAP:-}" ] && [ -z "$TARGET_ENDPOINT" ]; then
    echo "Error: nothing to route to; set TARGET_ENDPOINT or ROUTING_MAP" >&2
    exit 1
fi
if [ -n "$ACME_EMAIL" ] && ! ACME_EMAIL=$(sanitize_email "$ACME_EMAIL"); then
    exit 1
fi
if ! ACME_STAGING=$(sanitize_boolean "$ACME_STAGING" "ACME_STAGING/CERTBOT_STAGING"); then
    exit 1
fi
if ! DETERMINISTIC_TLS_KEY=$(sanitize_boolean "$DETERMINISTIC_TLS_KEY" "DETERMINISTIC_TLS_KEY"); then
    exit 1
fi
if ! GATEWAY_DOMAIN=$(sanitize_gateway_domain "${GATEWAY_DOMAIN:-}"); then
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
if ! EVIDENCE_SERVER=$(sanitize_boolean "$EVIDENCE_SERVER" "EVIDENCE_SERVER"); then
    exit 1
fi
if ! EVIDENCE_PORT=$(sanitize_port "$EVIDENCE_PORT" "EVIDENCE_PORT"); then
    exit 1
fi
if ! RENEW_INTERVAL=$(sanitize_positive_integer "$RENEW_INTERVAL" "RENEW_INTERVAL"); then
    exit 1
fi
if [ -n "$RENEW_DAYS_BEFORE" ] && ! RENEW_DAYS_BEFORE=$(sanitize_positive_integer "$RENEW_DAYS_BEFORE" "RENEW_DAYS_BEFORE"); then
    exit 1
fi
if ! DNS_SETUP_TIMEOUT=$(sanitize_positive_integer "$DNS_SETUP_TIMEOUT" "DNS_SETUP_TIMEOUT"); then
    exit 1
fi
if ! DNS_SETUP_INTERVAL=$(sanitize_positive_integer "$DNS_SETUP_INTERVAL" "DNS_SETUP_INTERVAL"); then
    exit 1
fi
case "$DNS_SETUP_MODE" in
    wait|print|webhook) ;;
    *)
        echo "Error: invalid DNS_SETUP_MODE '$DNS_SETUP_MODE' (expected wait, print or webhook)" >&2
        exit 1
        ;;
esac
if [ "$DNS_SETUP_MODE" = "webhook" ] && [ -n "${DNS_WEBHOOK_TIMEOUT+set}" ] &&
   ! DNS_WEBHOOK_TIMEOUT=$(sanitize_positive_integer "$DNS_WEBHOOK_TIMEOUT" "DNS_WEBHOOK_TIMEOUT"); then
    exit 1
fi
if ! ALPN=$(sanitize_alpn "$ALPN"); then
    exit 1
fi
if ! ACCEPT_PROXY_PROTOCOL=$(sanitize_boolean "$ACCEPT_PROXY_PROTOCOL" "ACCEPT_PROXY_PROTOCOL"); then
    exit 1
fi
if ! SEND_PROXY_PROTOCOL=$(sanitize_boolean "$SEND_PROXY_PROTOCOL" "SEND_PROXY_PROTOCOL"); then
    exit 1
fi
if [ -n "$ROUTING_MAP" ] && ! routing_map_entries >/dev/null; then
    exit 1
fi

# Warn about deprecated L7 env vars
for var in CLIENT_MAX_BODY_SIZE PROXY_READ_TIMEOUT PROXY_SEND_TIMEOUT PROXY_CONNECT_TIMEOUT PROXY_BUFFER_SIZE PROXY_BUFFERS PROXY_BUSY_BUFFERS_SIZE; do
    if [ -n "${!var}" ]; then
        echo "Warning: $var is ignored in TCP proxy mode"
    fi
done
if [ "$SEND_PROXY_PROTOCOL" = "true" ] && [ "$ACCEPT_PROXY_PROTOCOL" != "true" ]; then
    echo "Warning: SEND_PROXY_PROTOCOL without ACCEPT_PROXY_PROTOCOL passes the gateway's address, not the client's"
fi

# Everything from here on belongs to one mode. Exported so the mode script and
# the helpers it invokes see the sanitized values.
export PORT DOMAIN DOMAINS GATEWAY_DOMAIN TARGET_ENDPOINT ROUTING_MAP TXT_PREFIX MAXCONN
export TIMEOUT_CONNECT TIMEOUT_CLIENT TIMEOUT_SERVER EVIDENCE_SERVER EVIDENCE_PORT ALPN
export ACCEPT_PROXY_PROTOCOL SEND_PROXY_PROTOCOL
export ACME_EMAIL ACME_STAGING DETERMINISTIC_TLS_KEY RENEW_INTERVAL RENEW_DAYS_BEFORE
export DNS_SETUP_TIMEOUT DNS_SETUP_INTERVAL DNS_SETUP_MODE DNS_WEBHOOK_TIMEOUT

# A container restart keeps the filesystem, and with it the last run's pidfile.
rm -f /var/run/haproxy/haproxy.pid

case "$CHALLENGE_TYPE" in
    dns-01)
        exec /scripts/dns01.sh "$@"
        ;;
    tls-alpn-01)
        exec /scripts/tlsalpn.sh "$@"
        ;;
esac
