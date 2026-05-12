# consul-postgres-ha-mesh-sidecar

The single image that holds every platform-plumbing process a worker or
coordinator CVM runs:

| Process            | Role                                                     |
|--------------------|----------------------------------------------------------|
| `bootstrap-secrets` | One-shot init: derives per-CVM secrets from the dstack TEE KMS, claims an ordinal, writes `/run/instance/info.json`. |
| `mesh-conn`         | QUIC-on-pion/ICE overlay: forwards Consul gossip + RPC + HTTP ports between peer CVMs over a NAT'd L3 path. |
| `consul`            | Server on coordinator CVMs (`-server -bootstrap-expect=N -ui`), client on worker CVMs. Joins via mesh-conn-forwarded loopback ports. |
| `envoy`             | Connect-mTLS data plane on workers. Bootstrapped from the local consul agent's xDS once it's reachable. Coordinators don't run it. |

Replaces what used to be four separate compose services
(`bootstrap-secrets`, `mesh-conn`, `consul`, and the old envoy-only
`sidecar`) plus the legacy `keepalive` placeholder.

The compose-service name stays `sidecar` (so the per-CVM container
name is `dstack-sidecar-1` regardless of which image it points at);
the *image* is `consul-postgres-ha-mesh-sidecar`. The "mesh-" prefix
is meant to make it obvious that this is the bundle of mesh
plumbing — bootstrap-secrets + mesh-conn + consul + envoy — and not
just an Envoy sidecar.

## Lifecycle

`tini → entrypoint.sh` is PID 1. The script:

1. Runs `bootstrap-secrets` to completion (it's a one-shot — exit 0
   means `/run/instance/info.json` and `/run/secrets/*` are in place).
2. Starts `mesh-conn` in the background.
3. Starts `consul agent` in the background, with `-server` +
   `-bootstrap-expect=N` if `ROLE=coordinator`.
4. (Workers only) Polls `consul connect envoy -bootstrap` until the
   local consul agent answers, then exec's envoy.
5. `wait -n`s on all background processes — if any one exits, the
   container exits with that code, and compose's
   `restart: on-failure` brings it back.

This is "shell init", not s6-overlay. If we hit real-world flap-storms
where one inner process dying often takes the whole container down, the
upgrade path is per-process supervision via s6 — but today it doesn't
pay its complexity.

## Debugging

```bash
# Log stream for the whole sidecar — every line is prefixed with the
# inner process name ([bootstrap-secrets] / [mesh-conn] / [consul] /
# [envoy] / [init]).
docker logs dstack-sidecar-1

# Inspect what's running inside.
docker exec dstack-sidecar-1 ps -ef

# Talk to the local consul agent (handy for cluster status / KV).
docker exec dstack-sidecar-1 sh -c 'consul members -http-addr=127.0.0.1:$(jq -r .ports.http_api /run/instance/info.json)'

# Curl the local Patroni REST API or webdemo from inside the sidecar.
docker exec dstack-sidecar-1 sh -c 'curl -s http://127.0.0.1:$(jq -r .ports.patroni_rest /run/instance/info.json)/cluster | jq'
```

## Build context

CI builds this image with `consul-postgres-ha/` as the docker context
(not `consul-postgres-ha/mesh-sidecar/`) so the Dockerfile can `COPY
bootstrap-secrets/` and `COPY mesh-conn/` from sibling directories.
See `.github/workflows/consul-postgres-ha-publish.yml`.
