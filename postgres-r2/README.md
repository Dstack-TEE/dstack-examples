# Postgres that survives losing its disk, or its node

Your CVM was just redeployed. Where did your database go?

It's gone. A dstack app volume is cache-grade storage — the developer guide says so — and a
database sitting on one was never durable, only uninterrupted. This example stops treating the
disk as the database: Postgres ships every write-ahead log segment to an S3-compatible bucket
(Cloudflare R2 here) with [wal-g](https://github.com/wal-g/wal-g), and the disk becomes a cache
you can delete.

Then it goes one step further. The same archive is enough to stand up a second copy of the
database on a **different node**, one that has never spoken to the first. Kill the first node
and promote the second. What that costs, in acknowledged writes, is measured below.

The part that makes it a TEE example rather than an ops recipe: **the encryption key is derived
from the app's identity, not handed to it.** The bucket holds bytes nobody can read — not
Cloudflare, not you — and the only thing that turns them back into a database is attested code
running under the same app id. On a second node, that means the same app id on a second node.

## Run it

```bash
phala deploy -n pg-r2 -c docker-compose.yml \
  -e AWS_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com \
  -e AWS_ACCESS_KEY_ID=... -e AWS_SECRET_ACCESS_KEY=... \
  -e WALG_S3_PREFIX=s3://<bucket>/pg

./verify.sh pg-r2
```

No `POSTGRES_PASSWORD` and no encryption key in that command — both are derived at boot from
`GetKey` on the guest agent socket. The only secrets you pass are the bucket credentials, which
belong to Cloudflare's side of the arrangement and cannot be derived.

`PG_ROLE` defaults to `primary`. The other value is `standby`, and both drills below use it.

## Drill 1: the disk

The deployment is not the lesson. This is:

```bash
# 1. leave a canary
psql "$DSN" -c "CREATE TABLE canary(t timestamptz); INSERT INTO canary VALUES (now())"

# 2. wait for the segment to land (archive_timeout, 60s by default), then destroy the disk
phala ssh pg-r2 -- 'docker rm -f $(docker ps -q); docker volume rm <app>_pgdata'

# 3. bring the same app back as a standby, built from the archive alone
phala deploy --cvm-id pg-r2 -c docker-compose.yml -e PG_ROLE=standby \
  -e AWS_ENDPOINT=... -e AWS_ACCESS_KEY_ID=... -e AWS_SECRET_ACCESS_KEY=... \
  -e WALG_S3_PREFIX=s3://<bucket>/pg

# 4. it comes up read-only, replaying the archive; make it the primary again
psql "$DSN" -c "SELECT pg_promote()"

# 5. the canary is still there
psql "$DSN" -c "SELECT * FROM canary"
```

Nothing was copied from the old node and no key was carried across. The app re-derived the key
because it is the same app.

## Drill 2: the node

Same idea, but the second copy is built on another node *before* anything goes wrong, and the
first node is killed the hard way while a client is writing to it.

```bash
# 1. a standby on a second node, sharing the primary's app id
cat > standby.env <<EOF
PG_ROLE=standby
AWS_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
WALG_S3_PREFIX=s3://<bucket>/pg
EOF
phala cvms replicate pg-r2 --node-id <other-node> -e standby.env
```

`replicate` creates a second instance of the *same app* (same app id, same compose hash) on
the node you name. It gets the bucket credentials from the env file because those cannot be
derived. It does not get the archive key. It boots, asks `GetKey` for `/pg-r2/walg/v1`, gets
the same 32 bytes the primary got, and `wal-g backup-fetch` reads the primary's encrypted
archive with a key nobody handed it. Then it sits in recovery pulling each new segment as it
lands.

```bash
# 2. confirm it owes the primary nothing
psql "$STANDBY_DSN" -tAc "SHOW primary_conninfo"                          # empty
psql "$STANDBY_DSN" -tAc "SELECT count(*) FROM pg_stat_activity WHERE backend_type='walreceiver'"   # 0
psql "$STANDBY_DSN" -tAc "SELECT pg_is_in_recovery()"                     # t

# 3. write through the gateway, recording every id the server acknowledged
yes 'INSERT INTO drill DEFAULT VALUES RETURNING id;' \
  | psql "$DSN" -tAq -v ON_ERROR_STOP=1 | grep -E '^[0-9]+$' > acked.txt &

# 4. mid-write, SIGKILL the primary. No archive flush, no restart.
phala ssh pg-r2 -- 'docker rm -f $(docker ps -q)'

# 5. promote the standby and count what did not make it
psql "$STANDBY_DSN" -c "SELECT pg_promote(true, 120)"
psql "$STANDBY_DSN" -tAc "SELECT id FROM drill ORDER BY id" > survived.txt
comm -23 <(sort -u acked.txt) <(sort -u survived.txt) | wc -l

# 6. the old primary is a dead node now; treat it as one
phala cvms delete pg-r2 --force
```

The standby's DSN is the primary's app id on the other node's gateway; `phala cvms list` will
show you both instances. Step 3 goes through the gateway on purpose: an ack is only an ack if
the client received it, and the client is the only place that survives the primary dying.

> [!WARNING]
> **A different app cannot read this archive.** `GetKey` derives from app identity, so deploying
> this compose as a *new* CVM produces a different key and wal-g fails with `corrupted chunk` —
> that is decryption failing, not a damaged object. Measured on two CVMs running this exact
> example:
>
> ```
> pg-r2-example   /pg-r2/walg/v1 -> 736c54f314defc07…
> pg-r2-restored  /pg-r2/walg/v1 -> 160f640db26d2529…
> ```
>
> `phala cvms replicate` is the supported way to get a second instance under the same app id.
> The alternatives are `phala deploy --custom-app-id <id> --nonce <n>`, or a supplied
> `WALG_LIBSODIUM_KEY` — and the moment you supply one, someone outside the enclave is holding
> the key you were trying not to have. Decide before your first backup, not after your last.

## What `verify.sh` proves

It is handed nothing. It re-derives the superuser password and logs in with it, then re-derives
the archive key — which it must, because without it wal-g cannot read the bucket at all.

```
== 1. keys are derived, not stored
   superuser path, twice   : b60a400df24a9af7… / b60a400df24a9af7…  same
   archive-key path        : 736c54f314defc07…  unrelated
   logging in with the re-derived password: postgres

== 2. the archive is current
   segments archived      : 6 (0 failed)
   newest segment is      : 72s old
   waiting to archive     : 0 .ready files

== 3. the bucket holds ciphertext
   a live segment on disk  : 16d10600010000000000000200000000
   the object in the bucket: d830dc91fa382fe4f6fea96b3008cfb1
   the object after wal-g  : 16d10600010000000000000600000000
   WAL magic is 16d1 — the bucket copy does not have it, the wal-g copy does
```

Every WAL page opens with the same magic for a given server version, so the magic is what
carries across segments; comparing whole heads would prove nothing.

`verify.sh` reaches the CVM over `phala ssh`, which a replicated instance does not accept (it
is not issued your SSH key). Run it against the primary. Check the standby over its DSN, as in
Drill 2 step 2.

## The numbers, with denominators

Both drills below were run on real CVMs on two nodes, writing through the gateway at roughly
12–13 inserts/s, killing the primary with `docker rm -f` (SIGKILL: nothing flushes, nothing
restarts), then promoting a standby that had derived its own key.

| `archive_timeout` | acknowledged | lost | as time, at the observed write rate |
|---|---:|---:|---|
| 60 s | 771 | **429** | about 33 s of writes |
| 15 s | 739 | **16** | about 1 s of writes |

- **RPO — what a failure costs.** Whatever has not reached the archive yet, which is at most
  `archive_timeout` of writes. That bound is the guarantee. The *sample* depends on where the
  kill lands in the archive cycle: 429 used more than half the 60 s window, 16 used almost none
  of the 15 s one, and a rerun would land somewhere else inside each bound. Quote the bound.
  What the two rows do show is that the knob works: lowering the timeout narrows the window, at
  the cost of more and smaller objects in the bucket.
- **RTO — how long the rebuild takes.** Restore time tracks the *compressed archive*, not the
  logical database: **333 MB of incompressible rows came back in 29.3 s** (about 11 MB/s), while
  1.18 GB of repetitive rows took 15.2 s because its archive is nearly empty, and an empty
  database hits a fixed-cost floor near 12 s. With a standby already caught up, promotion itself
  is sub-second and the RTO is your detection time. Measure your own data before promising
  anyone either number.
- **What the idle standby costs.** A caught-up standby polls the bucket for the next segment.
  At Postgres's default 5 s retry that came to ~19 HEAD requests/s, 0 bytes retrieved, about
  1.7 M class B operations a day — roughly $0.42/day on R2, and the whole bill. The compose
  sets `wal_retrieve_retry_interval=30s`, which cuts it about 6×. Promotion drains the restore
  command first, so this interval does not change what a failover loses.

## After the failover

The promoted node is now a primary with one copy of the data and no standby. `archive_mode=on`
is inert while in recovery and arms the moment `pg_promote` runs, so it resumes shipping WAL to
the bucket on its own; without that a promoted standby would be a single copy with no archive,
and the next failure would lose everything. Check it:

```bash
psql "$DSN" -tAc "SELECT archived_count, last_archived_time FROM pg_stat_archiver"
```

Then give it a standby of its own with another `phala cvms replicate`, and delete the dead
instance. A restart of the promoted container comes back as a primary: the standby staging
only runs on an empty data directory, and promotion removed `standby.signal`.

## How it works

- **Keys from `GetKey`.** `POST /GetKey` on `/var/run/dstack.sock` with a path returns 32 bytes of
  hex — exactly wal-g's libsodium key size — plus a signature chain. Same app and path, same key
  on every boot, on every node running the app, and after a total rebuild; different path,
  unrelated key. The derivation path carries the domain separation.
- **It fails closed.** No socket, or a derivation that returns something unusable, and the
  container exits. A database that would ship plaintext WAL into someone else's bucket should not
  start at all.
- **The standby never talks to the primary.** `primary_conninfo` is set empty on purpose;
  `restore_command = wal-g wal-fetch` is its only source. Recovery depends on the bucket and
  the app's key, and on nothing that dies with the primary.
- **Archiving is configured on both roles.** So a promoted standby re-arms without a redeploy.
- **The base backup is pushed with the derived key in its environment.** WAL alone restores
  nothing; it needs a base to replay onto. The entrypoint pushes one on first boot from the
  process that holds the key. Do not push one by hand with `docker exec ... wal-g backup-push`:
  that shell has no key, wal-g writes an unencrypted base, and the standby's fetch fails with
  `corrupted chunk` because it is trying to decrypt plaintext.
- **wal-g is pinned by sha256** and verified before it runs. Pulling an unverified binary into a
  measured enclave at boot gives away most of what the measurement was for.
- **TLS terminates inside the enclave**, so a client talks to Postgres rather than to the gateway.
  Connect with `sslnegotiation=direct` (libpq 17+) — the gateway routes `5432s` by peeking the TLS
  SNI, and libpq's default handshake gets dropped with a misleading "server closed the connection
  unexpectedly".
- **`archive_timeout` is a startup argument.** It has the highest precedence, so `ALTER SYSTEM`
  cannot change it; pass `-e ARCHIVE_TIMEOUT=15` and redeploy.

## Not covered here

**RPO 0.** An archive-only standby cannot have what the primary never archived. Closing the
window rather than bounding it means streaming replication between the nodes, which is a
different design: the standby then depends on a live connection to the primary, and the key
story has to cover the stream as well as the bucket.

**A second failover.** After promotion the new primary archives on a new timeline. Building a
fresh standby from that archive, and failing over to it, was not exercised here.

**Detection.** The drill promotes by hand. Nothing here decides that the primary is dead.

**Archive rollback.** The bucket holds ciphertext, and a freshness check catches an archiver that
has stopped — but nothing here detects a storage provider that serves an *older* archive that is
internally consistent. wal-g will restore it and the result looks healthy at the wrong point in
history. Closing that needs a monotonic commitment to the archive head, kept somewhere the storage
provider does not control. It is the honest open problem in this design.

## Requirements

Two CVMs' worth of capacity on nodes your workspace can see (`phala nodes list`), each with
egress to your object store and the guest agent socket mounted (the compose does that).
Postgres 17, wal-g 3.0.9, any S3-compatible bucket. A libpq 17 client for the drills; on an
older distribution, `docker run --rm -i postgres:17 psql` works.
