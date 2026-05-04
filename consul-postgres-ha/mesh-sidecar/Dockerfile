# Single image containing every platform-plumbing process a
# consul-postgres-ha CVM runs:
#
#   bootstrap-secrets  one-shot init, derives per-CVM secrets from the
#                      dstack KMS and writes /run/instance/info.json
#   mesh-conn          QUIC-on-pion/ICE userspace overlay
#   consul             agent (server on coordinator CVMs, client on
#                      worker CVMs)
#   envoy              Connect mTLS data plane (workers only)
#
# Build context is the parent `consul-postgres-ha/` directory so this
# Dockerfile can COPY both Go sources straight in. CI configures that
# context via .github/workflows/consul-postgres-ha-publish.yml.
#
# The final stage inherits envoyproxy/envoy because envoy is the
# largest binary and the only one not statically linked — its base
# already carries the right glibc + ca-certs. The other binaries are
# CGO_ENABLED=0 Go builds that work on any base.

FROM golang:1.24-alpine AS bootstrap-build
WORKDIR /src
COPY bootstrap-secrets/go.mod bootstrap-secrets/go.sum ./
RUN go mod download
COPY bootstrap-secrets/*.go ./
RUN CGO_ENABLED=0 go build -o /out/bootstrap-secrets .

FROM golang:1.24-alpine AS mesh-build
WORKDIR /src
COPY mesh-conn/go.mod mesh-conn/go.sum ./
RUN go mod download
COPY mesh-conn/*.go ./
RUN CGO_ENABLED=0 go build -o /out/mesh-conn .

FROM hashicorp/consul:1.19 AS consul-bin

FROM envoyproxy/envoy:contrib-v1.30-latest

# tini = correct PID 1 reaping + signal forwarding;
# jq, curl = used by the entrypoint and convenient for `docker exec`-debug.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl jq tini && \
    rm -rf /var/lib/apt/lists/*

COPY --from=bootstrap-build /out/bootstrap-secrets /usr/local/bin/bootstrap-secrets
COPY --from=mesh-build      /out/mesh-conn         /usr/local/bin/mesh-conn
COPY --from=consul-bin      /bin/consul            /usr/local/bin/consul
COPY mesh-sidecar/entrypoint.sh                    /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Persistent consul state — workers' KV cache and coordinators' Raft log.
VOLUME ["/consul/data"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
