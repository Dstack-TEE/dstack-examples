#!/bin/bash

# Verify that the ingress image can terminate TLS 1.3 with the configured
# post-quantum hybrid group and classical fallback groups.
#
# Usage: ./scripts/tests/test_x25519mlkem768.sh <image>

set -euo pipefail

IMAGE="${1:?usage: $0 <image>}"
CONTAINER="dstack-ingress-x25519mlkem768-$$"

# shellcheck disable=SC2317 # Invoked by the EXIT trap below.
cleanup() {
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --rm --name "${CONTAINER}" --entrypoint bash "${IMAGE}" -c '
    set -euo pipefail
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout /tmp/key.pem -out /tmp/cert.pem \
        -subj /CN=localhost -days 1 >/dev/null 2>&1
    cat /tmp/key.pem /tmp/cert.pem >/tmp/test.pem

    source /scripts/haproxy-lib.sh
    MAXCONN=16
    TIMEOUT_CONNECT=5s
    TIMEOUT_CLIENT=30s
    TIMEOUT_SERVER=30s
    haproxy_emit_global

    cat >>/etc/haproxy/haproxy.cfg <<EOF
frontend tls_test
    bind 127.0.0.1:24443 ssl crt /tmp/test.pem
    default_backend discard

backend discard
    server discard 127.0.0.1:9
EOF

    exec haproxy -W -db -f /etc/haproxy/haproxy.cfg
' >/dev/null

for group in X25519MLKEM768 X25519 secp256r1 secp384r1; do
    handshake=""
    for _ in {1..20}; do
        handshake="$(docker exec "${CONTAINER}" bash -c \
            "openssl s_client -connect 127.0.0.1:24443 -servername localhost -tls1_3 -groups ${group} </dev/null 2>&1" \
            || true)"
        # Each client offers exactly one group, so a successful TLS 1.3
        # handshake proves HAProxy selected that configured group. OpenSSL
        # only prints "Negotiated TLS1.3 group" for some group types.
        if grep -Fq 'Protocol: TLSv1.3' <<<"${handshake}"; then
            echo "TLS 1.3 handshake completed with ${group}"
            break
        fi
        sleep 0.1
    done

    if ! grep -Fq 'Protocol: TLSv1.3' <<<"${handshake}"; then
        printf '%s\n' "${handshake}" >&2
        echo "${group} TLS handshake did not complete" >&2
        exit 1
    fi
done
