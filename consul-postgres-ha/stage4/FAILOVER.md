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
  "docker exec dstack-tester-1 sh -c 'curl -s http://127.0.0.1:18803/cluster' | jq"

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

## Measured timeline (run from 2026-05-03)

```
T_kill            05:02:28.028   docker stop dstack-patroni-1 on worker-3
T_new_leader      05:02:49.994   worker-4 promoted (timeline 15 → 16)   +22s
T_first_write     05:02:52.313   INSERT succeeds on worker-4            +24s  ← RTO
T_restart_W3      05:03:39.704   docker start dstack-patroni-1
T_W3_rejoined     05:04:10.377   worker-3 streaming, lag=0              +31s
```

**RTO (Recovery Time Objective): ~24 seconds.** That's the wall time
from leader process death to first successful write on the new leader,
sitting comfortably inside the default Patroni `ttl=30`.

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

This kills patroni, postgres, mesh-conn, consul, sidecar, webdemo, and
the keepalive — everything that produces signal for the rest of the
cluster. Bring the host back via:

```bash
ssh ... root@${LEADER}-22.${GW} \
  "cd /tapp && docker compose --env-file /dstack/.host-shared/.decrypted-env \
     -p dstack -f /tapp/docker-compose.yaml up -d"
```

`docker compose up -d` respects the dependency order
(bootstrap-secrets → mesh-conn → consul → patroni).

### Measured timeline (run from 2026-05-03)

```
T_kill           07:26:42   docker stop -t 0 ALL 7 containers on worker-4
T_new_leader     07:27:13   worker-3 promoted (timeline 16 → 17)        +31s
T_first_write    07:27:15   INSERT succeeds on worker-3                 +33s  ← RTO
T_restart_W4     07:27:46   docker compose up -d on worker-4
T_W4_rejoined    07:28:34   worker-4 streaming, lag=0                   +48s after restart
```

**Hard-kill RTO ≈ 33 seconds**, ~9 seconds longer than the soft-kill
above. That extra cost is Consul gossip-failure detection: with
soft-kill only the Patroni leader-key TTL expires, while with hard-kill
the entire Consul agent is gone, so the surviving peers see *both*
signals.

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

## What this demo does NOT cover

* **CVM reboot or kernel panic** — `reboot`/`poweroff` from inside
  the CVM. This involves the dstack platform's CVM lifecycle and is
  qualitatively different from container-level kills. Consider
  separately if/when you need to claim "host hardware failure"
  resilience.
* **Network partition**: split-brain isolation between coordinators
  vs workers. Patroni + Consul should handle it, but worth a separate
  test before claiming partition-tolerance.
* **Disk loss on rejoin**: if the ex-leader's pgdata is wiped, rejoin
  WILL trigger a full pg_basebackup through mesh-conn. The
  ~25 MB/s throughput and the QUIC transport mean even a 10 GB
  rebuild takes ~7 minutes (acceptable), but it's a different code
  path than the cheap rejoin shown above.
