# Zero-downtime upgrade

Updating a CVM's compose reboots it, and a stateful server is down until it boots again
(about 65 seconds for this example on Phala Cloud). This example upgrades without downtime:
it starts a second CVM of the same app on the new compose, hands the state and the writer
role to it, then deletes the old one.

The server is a small key-value store, inline Node in `docker-compose.yaml`. Its handover
code is what you would copy into your own server.

## How it works

Both CVMs get traffic from the gateway, so exactly one is the **writer** and the other
forwards to it. A **follower** forwards to its predecessor and takes over at boot; a
**retired** CVM forwards to its successor.

The handover is two calls from the new CVM B to the old CVM A. On `begin`, A holds requests
and returns its state. On `commit`, A retires and forwards to B, and B starts serving. With
no `commit` within 15 seconds, A resumes.

The calls are authenticated, and the state encrypted, with a key from `GetKey`. dstack derives
it from the app id, so A and B get the same key on different composes, and only a compose
the app allows can derive it.

`upgrade.sh` runs the upgrade:

1. `phala cvms replicate` A with `DORMANT=1`, so the replica only forwards.
2. `phala deploy --cvm-id B` with the new compose. Only B reboots; the gateway skips it while
   its port is closed.
3. B boots on the new compose and takes over.
4. After 20 seconds for requests in flight through A, delete A.

## Run it

```bash
phala deploy -n kv -c docker-compose.yaml -t tdx.small --wait -e PREDECESSOR_URL= -e DORMANT=
node client.mjs https://<app_id>-8080.<gateway base>    # in another terminal
sed 's/APP_VERSION=1/APP_VERSION=2/' docker-compose.yaml > v2.yaml
./upgrade.sh kv v2.yaml
```

`client.mjs` writes and reads a counter with no retries and prints every failure.
`upgrade.sh` needs `jq` and takes about two minutes. `node test-local.mjs` runs the same
upgrade on one machine.

The empty `-e` flags matter. dstack passes only env vars named in `allowed_envs`, which a
replica inherits. Without them the replica boots as a second writer with empty state; we saw
8 wrong reads in 20 seconds. `upgrade.sh` checks for them.

Change `APP_VERSION` with every change to the server code. Docker Compose does not recreate a
container when only an inline config's content changes, and the container survives the
reboot, so without a changed env var the CVM keeps running the old code.

The role is saved with the state and wins over the env at boot, because after an upgrade
`PREDECESSOR_URL` still names the deleted CVM.

## Results

Phala Cloud prod7, `tdx.small`, `dstack-dev-0.5.12`, with `client.mjs` running throughout:

| Upgrade | Failed requests | Longest request |
|---------|-----------------|-----------------|
| `phala deploy --cvm-id A` (in place) | 13, over 65 s | 5.4 s |
| `upgrade.sh` v1 → v2 → v3 | 0 of 334 | 1.2 s |
| `upgrade.sh` v1.1 → v2, this version of the server | 0 of 169 | 3.8 s |

While A is retired, a request through A costs about 10 ms more than one sent to B directly
(median of 12 each, after the TLS handshake). After A is deleted there is no forwarding.

State goes in one request, so a large database would hand over a pointer to encrypted
storage instead.
