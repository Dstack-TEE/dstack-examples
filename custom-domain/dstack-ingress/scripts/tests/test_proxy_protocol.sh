#!/bin/bash

# Verify the opt-in PROXY protocol: with ACCEPT_PROXY_PROTOCOL and
# SEND_PROXY_PROTOCOL, the public bind takes the client's address from the
# header the dstack gateway prepends, refuses a connection without one, and
# hands that address to the backend; with neither, the config is unchanged.
#
# Usage: ./scripts/tests/test_proxy_protocol.sh <image>

set -euo pipefail

IMAGE="${1:?usage: $0 <image>}"
CONTAINER="dstack-ingress-proxy-protocol-$$"

# shellcheck disable=SC2317 # Invoked by the EXIT trap below.
cleanup() {
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

failures=0
check() {
    local msg="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS: ${msg}"
    else
        echo "FAIL: ${msg} (expected '${expected}', got '${actual}')" >&2
        failures=$((failures + 1))
    fi
}

# The config the helpers emit with the switches unset has no PROXY keyword.
default_cfg="$(docker run --rm --entrypoint bash "${IMAGE}" -c '
    set -euo pipefail
    source /scripts/functions.sh
    source /scripts/haproxy-lib.sh
    MAXCONN=16 TIMEOUT_CONNECT=5s TIMEOUT_CLIENT=30s TIMEOUT_SERVER=30s
    EVIDENCE_SERVER=false DOMAIN=localhost TARGET_ENDPOINT=127.0.0.1:25080
    haproxy_emit_global
    haproxy_emit_tls_frontend "127.0.0.1:24443$(haproxy_accept_proxy)"
    haproxy_emit_backends
    cat /etc/haproxy/haproxy.cfg
')"
check "default config has no accept-proxy" "0" "$(grep -c 'accept-proxy' <<<"${default_cfg}" || true)"
check "default config has no send-proxy" "0" "$(grep -c 'send-proxy' <<<"${default_cfg}" || true)"

docker run -d --rm --name "${CONTAINER}" --entrypoint bash "${IMAGE}" -c '
    set -euo pipefail
    mkdir -p /etc/haproxy/certs
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout /tmp/key.pem -out /tmp/cert.pem \
        -subj /CN=localhost -days 1 >/dev/null 2>&1
    cat /tmp/key.pem /tmp/cert.pem >/etc/haproxy/certs/test.pem

    # The backend reports the source address of the PROXY v2 header it receives.
    python3 - <<"PY" &
import socket, struct
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 25080)); srv.listen()
while True:
    conn, _ = srv.accept()
    head = conn.recv(16)
    if head[:12] != b"\r\n\r\n\x00\r\nQUIT\n":
        conn.sendall(b"src=none"); conn.close(); continue
    body = conn.recv(struct.unpack("!H", head[14:16])[0])
    conn.sendall(("src=" + socket.inet_ntoa(body[:4])).encode()); conn.close()
PY

    source /scripts/functions.sh
    source /scripts/haproxy-lib.sh
    MAXCONN=16 TIMEOUT_CONNECT=5s TIMEOUT_CLIENT=30s TIMEOUT_SERVER=30s
    EVIDENCE_SERVER=false DOMAIN=localhost TARGET_ENDPOINT=127.0.0.1:25080
    ACCEPT_PROXY_PROTOCOL=true SEND_PROXY_PROTOCOL=true
    haproxy_emit_global
    haproxy_emit_tls_frontend "127.0.0.1:24443$(haproxy_accept_proxy)"
    haproxy_emit_backends
    exec haproxy -W -db -f /etc/haproxy/haproxy.cfg
' >/dev/null

client='
import socket, ssl, struct, sys
def pp2(src):
    addr = socket.inet_aton(src) + socket.inet_aton("127.0.0.1") + struct.pack("!HH", 40000, 24443)
    return b"\r\n\r\n\x00\r\nQUIT\n" + bytes([0x21, 0x11]) + struct.pack("!H", len(addr)) + addr
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
raw = socket.create_connection(("127.0.0.1", 24443), timeout=5)
if sys.argv[1] != "none":
    raw.sendall(pp2(sys.argv[1]))
try:
    tls = ctx.wrap_socket(raw, server_hostname="localhost")
    tls.sendall(b"x")
    print(tls.recv(64).decode())
except (ssl.SSLError, ConnectionError, OSError):
    print("refused")
'

result=""
for _ in {1..50}; do
    result="$(docker exec "${CONTAINER}" python3 -c "${client}" 203.0.113.9 2>/dev/null || true)"
    [[ -n "$result" && "$result" != "refused" ]] && break
    sleep 0.1
done
check "backend receives the client address from the PROXY header" "src=203.0.113.9" "${result}"
check "a connection without a PROXY header is refused" "refused" \
    "$(docker exec "${CONTAINER}" python3 -c "${client}" none 2>/dev/null || true)"

if [[ $failures -eq 0 ]]; then
    echo "All PROXY protocol tests passed"
else
    echo "$failures PROXY protocol tests failed" >&2
    exit 1
fi
