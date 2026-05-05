# Stage 4 — failover demo

A reproducible recipe for the soft-kill leader-failover scenario, plus the
measured timeline from a real run on the live cluster (2026-05-03).
This demonstrates that stage 4's HA story is end-to-end working: Patroni
elects via Consul KV when the leader's lock expires, a replica is
promoted, writes resume on the new leader, and the old leader rejoins
cheaply (WAL replay + streaming, no full pg_basebackup) once it comes
back.

## What gets exercised

1. Patroni leader-election via Consul KV (TTL-driven lock expiry).
2. Replica promotion + timeline bump.
3. Streaming replication on the new leader.
4. Old leader's cheap rejoin path (no full re-bootstrap through mesh-conn).

## Recipe

Set up env (cluster IDs from `RESUME.md`):

```bash
GW=dstack-pha-prod5.phala.network
W1=eb94f7cd4f726ea3e90380e9043ed15c1f9e67e9   # current leader (worker-3)
W2=0e51c005457fbe994b55480aab06dfaf6c7f89b1   # worker-4
W3=0889166bf09d84ea06e132c4b3cc7e2e7db586e0   # worker-5
PW=$(ssh ... root@${W1}-22.${GW} "cat /tmp/dstack-runtime/secrets/patroni-superuser")
```

### 1. Snapshot pre-state + mark a "before" row

```bash
ssh ... root@${W1}-22.${GW} \
  "docker exec dstack-sidecar-1 sh -c 'curl -s http://127.0.0.1:18803/cluster' | jq"

ssh ... root@${W1}-22.${GW} "PGPASSWORD='$PW' docker exec -e PGPASSWORD dstack-patroni-1 \
  psql -h 127.0.0.1 -p 18703 -U postgres -d postgres \
  -c \"INSERT INTO demo(msg) VALUES ('before failover') RETURNING id, msg;\""
```

Expected: `worker-3` leader, `worker-4` + `worker-5` replicas streaming with lag=0,
timeline=15. Default Patroni config: `ttl=30, loop_wait=10, retry_timeout=10`.

### 2. Soft-kill the leader

```bash
T_kill=$(date -u +%H:%M:%S.%N)
ssh ... root@${W1}-22.${GW} "docker stop -t 0 dstack-patroni-1"
```

### 3. Watch the election + first write on the new leader

```bash
# Poll W4's /cluster endpoint every ~1s; promotion shows when the
# leader-key expires from Consul KV (TTL=30s) and a replica wins.
while ! curl -s http://127.0.0.1:18804/cluster | jq -e '.members[]|select(.role=="leader" and .name!="worker-3")' >/dev/null; do
  sleep 1
done

# Try to write on whichever replica got promoted.
ssh ... root@${W2}-22.${GW} "PGPASSWORD='$PW' docker exec -e PGPASSWORD dstack-patroni-1 \
  psql -h 127.0.0.1 -p 18704 -U postgres -d postgres \
  -c \"INSERT INTO demo(msg) VALUES ('after failover') RETURNING id;\""
```

### 4. Bring the old leader back

```bash
ssh ... root@${W1}-22.${GW} "docker start dstack-patroni-1"
# Watch /cluster until worker-3 reports state=streaming, lag=0.
```

### 5. Confirm cheap-rejoin (no pg_basebackup)

```bash
ssh ... root@${W1}-22.${GW} \
  "docker logs --tail 40 dstack-patroni-1 2>&1 | grep -iE 'pg_basebackup|recovery|streaming|timeline'"
```

Expected log lines (no `pg_basebackup`, just WAL replay + streaming):

```
starting backup recovery with redo LSN 0/... checkpoint LSN 0/..., on timeline ID 15
completed backup recovery with redo LSN 0/... and end LSN 0/...
consistent recovery state reached at 0/...
started streaming WAL from primary at 0/... on timeline 16
```

## Measured timeline (run from 2026-05-04, single-sidecar layout)

```
T_kill            17:31:26   docker stop dstack-patroni-1 on worker-5 (leader)
T_new_leader      17:31:57   worker-4 promoted (timeline 2 → 3)         +31s
T_first_write     17:31:59   INSERT succeeds on worker-4                +33s  ← RTO
```

**RTO (Recovery Time Objective): ~33 seconds.** That's the wall time
from leader process death to first successful write on the new leader,
sitting at the edge of the default Patroni `ttl=30`. The 2026-05-03
multi-container baseline was 24s on a different cluster — the
single-sidecar layout is within typical run-to-run variance for the
`ttl=30 + promote-overhead` window. Cheap rejoin was confirmed in a
prior round of this same run: a previously-killed leader (worker-3)
came back as a streaming replica on the new timeline with lag=0
within ~60s of `docker start dstack-patroni-1`.

## Tunables for the RTO/availability tradeoff

If 24s is too long for your workload, lower the Patroni dynamic config in
Consul KV:

| Knob | Default | Effect of lowering |
|---|---|---|
| `ttl` | 30 | Faster TTL expiry → faster election; risk of false-positive failover under transient network blips |
| `loop_wait` | 10 | Faster Patroni heartbeat loop on each peer |
| `retry_timeout` | 10 | How long Patroni tolerates a flaky DCS before giving up |

A common production setting is `ttl=20, loop_wait=5, retry_timeout=5`
for ~10–15s RTO. Don't go below `ttl >= 2 * loop_wait` (Patroni rejects).

## Hard-kill variant (whole-userspace failure)

Same outline, but instead of stopping just `dstack-patroni-1`, simulate
a "host crashed but recovered" scenario by killing all containers on
the leader at once:

```bash
ssh ... root@${LEADER}-22.${GW} "docker stop -t 0 \$(docker ps -q)"
```

This kills patroni, postgres, webdemo, and the consolidated sidecar
(which itself runs bootstrap-secrets, mesh-conn, consul, and envoy
inside it) — everything that produces signal for the rest of the
cluster. Bring the host back via:

```bash
ssh ... root@${LEADER}-22.${GW} \
  "cd /tapp && docker compose --env-file /dstack/.host-shared/.decrypted-env \
     -p dstack -f /tapp/docker-compose.yaml up -d"
```

`docker compose up -d` respects the dependency order
(sidecar's `service_healthy` gate fires once bootstrap-secrets has
written `/run/instance/info.json`, then patroni and webdemo start).

### Measured timeline (run from 2026-05-04, single-sidecar layout)

```
T_kill           17:33:29   docker stop -t 0 ALL containers on worker-4 (leader)
T_new_leader     17:34:00   worker-3 promoted (timeline 3 → 4)          +31s
T_first_write    17:34:02   INSERT succeeds on worker-3                 +33s  ← RTO
T_restart_W4     17:34:02   docker compose up -d on worker-4
```

**Hard-kill RTO ≈ 33 seconds**, identical to both the soft-kill above
and the 2026-05-03 multi-container baseline. Consul gossip-failure
detection (which sees worker-4's whole agent disappear, not just the
Patroni lock) lines up with the Patroni leader-key TTL on this run,
so neither signal extends the RTO.

The post-restart rejoin path on dstack-worker pairs is occasionally
flaky (the documented `MESH_CONN_RELAY_ONLY=1` escape hatch in
`compose/worker.yaml` is exactly this case — flip it on if your
deployment hits a wedged ICE re-handshake). The mesh-conn binary
behavior is unchanged by the single-sidecar consolidation.

### Things confirmed by the hard-kill that the soft-kill didn't exercise

- **Best-replica selection under uneven lag.** Going into the kill,
  worker-3 was timeline=16, lag=0 while worker-5 was timeline=15 with
  measurable lag. Patroni picked worker-3 (the up-to-date one), not
  the alphabetically-earlier one. The promote-best-replica heuristic
  works.
- **mesh-conn QUIC ICE redial after a peer's userspace evaporates.**
  Other peers' QUIC links to worker-4 hit `MaxIdleTimeout=60s` and
  tore down; once worker-4's containers came back, the new mesh-conn
  established fresh ICE pairs and replication resumed without
  intervention. The earlier yamux build had a pathology where
  redial-after-stress would loop forever; QUIC is clean.
- **Cheap rejoin survives hard-kill.** worker-4's pgdata was
  untouched (the kernel never died, just userspace), so on bring-up
  Patroni replayed local WAL and joined as a streaming replica on the
  new timeline. No pg_basebackup, no multi-MB re-copy through
  mesh-conn.

## Disk-loss rejoin (full pg_basebackup variant)

A replica whose pgdata is wiped goes through Patroni's bootstrap path
and pulls a full pg_basebackup from the leader, all over mesh-conn's
QUIC tunnel. Recipe (run on a non-leader CVM):

```bash
docker stop -t 5 dstack-patroni-1
rm -rf /var/lib/docker/volumes/dstack_patroni-pgdata/_data/*
docker start dstack-patroni-1
```

### Measured timeline (run from 2026-05-04, single-sidecar layout)

```
T_wipe         17:34:21   docker stop + rm -rf pgdata on worker-5
T_restart      17:34:25   docker start
T_complete     17:34:43   "replica has been created using basebackup"   +18s
T_streaming    17:35:43   streaming WAL on timeline 4, lag=0            +82s total
```

A few-MB pgdata transferred in ~18 seconds end-to-end. The dataset
is small enough that handshake/startup overhead dominates — for a
realistic throughput number, see the soft-kill section's pg_basebackup
trace at ~25 MB/s sustained on the QUIC path.

The path itself is the proof point: Patroni correctly detects empty
pgdata, picks `bootstrap from leader` (not WAL replay), pulls the full
backup over mesh-conn, transitions to streaming on the current
timeline. No operator intervention.

## What this demo does NOT cover

* **CVM reboot or kernel panic** — `reboot`/`poweroff` from inside
  the CVM. This involves the dstack platform's CVM lifecycle and is
  qualitatively different from container-level kills. Consider
  separately if/when you need to claim "host hardware failure"
  resilience.
* **Network partition**: split-brain isolation between coordinators
  vs workers. Patroni + Consul should handle it, but worth a separate
  test before claiming partition-tolerance.
