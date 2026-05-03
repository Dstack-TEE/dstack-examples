# Stage 4 — done

Postgres HA across 3 dstack-TEE workers + 3 Consul coordinators is live.
Patroni leader election, pg_basebackup bootstrap, and streaming
replication all complete end-to-end. Verified 2026-05-03.

## What got fixed in the final pass

The open bug from the previous RESUME.md ("link transfers ~268 KB then
yamux keepalive timeout") was a red herring — its real cause was
**yamux on top of pion/ice.Conn**. yamux assumes a reliable byte-stream
underlay; pion/ice.Conn is UDP. Between dstack worker CVMs the UDP path
is extremely lossy:

| Path | Measured loss |
|---|---|
| Direct hairpin (both peers behind same `66.220.6.105` NAT) | ~99% one direction, ~57% the other |
| Relay through Vultr coturn | ~78% |

yamux's "keepalive timeout" / "recv window exceeded" were symptoms of
dropped packets violating yamux's reliability invariants — not actual
yamux bugs. The previously hypothesised threshold of 256 KB
(MaxStreamWindowSize) was a coincidence; the real threshold was
"however many packets fit before the first lost window-update".

**Fix**: replace yamux with QUIC (`github.com/quic-go/quic-go`). QUIC
has built-in loss recovery, congestion control, and stream-multiplexing
on top of an unreliable datagram underlay — exactly what a
`pion/ice.Conn` provides. The shape of the change in
`mesh-conn/main.go` is small (~150 lines): a `net.PacketConn` shim
around the ICE conn, a self-signed TLS config (mesh trust comes from
the dstack TEE layer + TURN HMAC, not TLS identity), and a
`quic.Dial`/`quic.Listen` swap for the old
`yamux.Client`/`yamux.Server`. The 3-byte (tag, port) stream-header
convention is unchanged.

Same hairpin path that killed yamux at 3 KB now sustains
**25–28 MB/s** for pg_basebackup. Both replicas (`worker-4`,
`worker-5`) bootstrap and stream cleanly from leader `worker-3`.

## Currently deployed images

```
mesh_conn_image = ttl.sh/dstack-mesh-conn-1777779211:24h   # QUIC version
patroni_image   = ttl.sh/dstack-patroni-1777751805:24h
... (others unchanged)
```

`ttl.sh` images live 24h. Rebuild with `cd stage4/mesh-conn && docker
build -t ttl.sh/dstack-mesh-conn-$(date +%s):24h . && docker push ...`
when the tag expires.

## Verifying the cluster

```bash
GW=dstack-pha-prod5.phala.network
W3=eb94f7cd4f726ea3e90380e9043ed15c1f9e67e9   # Patroni leader

# Topology
ssh ... root@${W3}-22.${GW} \
  "docker exec dstack-tester-1 sh -c \
   'curl -s http://127.0.0.1:18803/cluster | jq .'"

# Write on leader, read on a replica
PW=$(ssh ... root@${W3}-22.${GW} "cat /tmp/dstack-runtime/secrets/patroni-superuser")
ssh ... root@${W3}-22.${GW} "PGPASSWORD='$PW' docker exec -e PGPASSWORD dstack-patroni-1 \
  psql -h 127.0.0.1 -p 18703 -U postgres -d postgres -c \"INSERT INTO demo(msg) VALUES ('hi') RETURNING *;\""
```

## Still-open work (none blocking stage 4)

* `MESH_CONN_TCP_ONLY` and `MESH_CONN_RELAY_ONLY` env knobs are kept as
  debug switches but no longer needed for correctness — remove if a
  cleanup pass is wanted.
* Direct host candidates inside the same dstack edge (`10.0.2.10:port`)
  are still selected first; QUIC's loss recovery papers over the
  hairpin loss but the path is suboptimal. A future improvement: extend
  the NetworkTypes / candidate-priority logic to prefer relay over
  same-public-IP direct pairs. Not required for stage 4.
* Bootstrap-secrets / signaling / patroni / sidecar / webdemo images
  are still on their pre-fix tags — they didn't change in this pass and
  are working.

## Live cluster (reference)

| role | ordinal | app_id |
|------|---------|--------|
| coordinator-0 | 0 | `860ae2502cf1950c96fa51777b0e822ffe2466a2` |
| coordinator-1 | 1 | `a56f5b22e88264d446a15c96a7c2e80f4ec1e117` |
| coordinator-2 | 2 | `2c30e64fa15cdef27825e5857ecfc725c5b5df7c` |
| worker-3      | 3 | `eb94f7cd4f726ea3e90380e9043ed15c1f9e67e9` (Patroni leader) |
| worker-4      | 4 | `0e51c005457fbe994b55480aab06dfaf6c7f89b1` (replica, streaming) |
| worker-5      | 5 | `0889166bf09d84ea06e132c4b3cc7e2e7db586e0` (replica, streaming) |

Vultr coordinator host (coturn + signaling): `root@155.138.146.255`.
Signaling code is bind-mounted at `/opt/dstack-mesh-coord/phase0/icetest/`.

## Diagnostic artifact

The smoke test that proved QUIC-on-ice would work lives at
`stage4/quic-on-ice/main.go`. Two copies coordinate through the same
signaling broker the cluster uses, establish one ICE pair, and transfer
N MB of random bytes through a single QUIC stream. Run when debugging
future transport issues:

```bash
cd stage4/quic-on-ice && go build .
# copy quic-on-ice to two CVMs, then on each:
./quic-on-ice -role=A -peer=B -signal=http://155.138.146.255:7000 \
  -turn-host=155.138.146.255 -turn-secret=<hex>
./quic-on-ice -role=B -peer=A -signal=http://155.138.146.255:7000 \
  -turn-host=155.138.146.255 -turn-secret=<hex>
```

10 MB worker↔worker hairpin completes in ~1s.
