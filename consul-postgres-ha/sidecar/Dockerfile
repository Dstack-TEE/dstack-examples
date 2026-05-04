# Combines the consul CLI (used to generate Envoy's bootstrap config)
# with Envoy itself (the sidecar data-plane). Smaller than running a
# full Consul agent in the sidecar container — we only need `consul
# connect envoy -bootstrap` and then `envoy`.
FROM hashicorp/consul:1.19 AS consul-bin

FROM envoyproxy/envoy:contrib-v1.30-latest
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl jq && \
    rm -rf /var/lib/apt/lists/*
COPY --from=consul-bin /bin/consul /usr/local/bin/consul
ENTRYPOINT ["/bin/sh", "-c"]
