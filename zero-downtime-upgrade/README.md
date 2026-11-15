# Zero-downtime upgrade

Updating a CVM's compose reboots it. A stateful server on that CVM is unreachable until the
new image boots, which on Phala Cloud took about 70 seconds for a `tdx.small` running this
example. This example upgrades the server without downtime instead: it starts a second
CVM of the same app on the new compose, hands the state and the writer role to it, and only
then deletes the old one.

The server is a small key-value store (`docker-compose.yaml`, inline Node, no build step).
The handover code in it is what you would copy into your own server.

## How it works

Two CVMs of the same app can both receive traffic through the gateway, so at any moment
exactly one of them is the **writer** and the other forwards every request to it:

- **writer** serves requests from its own state, persisted on its disk.
- **follower** forwards to its predecessor. At boot it takes over (below).
- **retired** forwards to its successor, until it is deleted.

The handover is two calls from the new CVM B to the old CVM A:

1. `begin`: A stops serving writes (requests wait) and returns its state, encrypted.
2. `commit`: A becomes retired and forwards everything to B. B loads the state and becomes
   the writer. Requests that waited on A are forwarded to B.

If A gets no `commit` within 15 seconds it goes back to serving, so a B that crashes
mid-handover cannot strand the app.

Both calls go over the public gateway. They are authenticated with a key from `GetKey`, and the
state is encrypted under that key. dstack derives the key from the app id, so A and B get
the same key even though they run different composes, and nothing outside an approved
CVM of this app can derive it.

The upgrade itself is `upgrade.sh`:

1. `phala cvms replicate` A with `DORMANT=1`. The replica boots on A's compose and only
   forwards. Without `DORMANT` it would take over before running the new code.
2. `phala deploy --cvm-id B` with the new compose. Only B reboots. Meanwhile A keeps serving,
   and the gateway skips B because its port is closed.
3. B boots on the new compose and takes over from A.
4. After 20 seconds for in-flight requests through A, delete A.

## Run it

```bash
phala deploy -n kv -c docker-compose.yaml -t tdx.small --wait \
  -e PREDECESSOR_URL= -e DORMANT= -e GATEWAY_BASE=
node client.mjs https://<app_id>-8080.<gateway base>    # in another terminal

sed 's/APP_VERSION=1/APP_VERSION=2/' docker-compose.yaml > v2.yaml
./upgrade.sh kv v2.yaml
```

`client.mjs` writes and reads a counter in a loop with no retries and a fresh connection
per request, and prints every failure. `/_status` on the app URL shows which version and
role answered. `upgrade.sh` needs `jq`. Each upgrade takes about two minutes, most of it
the replica booting and then rebooting into the new compose.

The three `-e` flags on the first deploy are required even though they are empty. dstack only
passes env vars named in the CVM's `allowed_envs`, which the CLI sets from the `-e` names,
and a replica inherits its source's list. Without them the replica silently gets no
`DORMANT` and no `PREDECESSOR_URL`, boots as a second writer with empty state, and the
gateway splits traffic between two databases. When we tried that, the client saw 8 failed
reads and 4 version regressions in 20 seconds. `upgrade.sh` now refuses to start unless the
three names are allowed.

The role is saved on the data volume with the state, and at boot the saved role wins over
the env. A finished upgrade leaves `PREDECESSOR_URL` pointing at the deleted CVM, so
without this a restart of the new writer would make it a follower of nothing.

`node test-local.mjs` runs the same upgrade on one machine with a fake dstack socket and a
stand-in gateway.

## Results

On Phala Cloud (prod7, `tdx.small`, the `dstack-dev-0.5.12` image Phala picked by default), with `client.mjs` running throughout:

| Upgrade | Failed requests | Longest request |
|---------|-----------------|-----------------|
| `phala deploy --cvm-id A` (in place) | 13, from 03:51:56 to 03:53:01 | 5.4 s |
| `upgrade.sh` v1 → v2, then `upgrade.sh` v2 → v3 | 0 of 334 | 1.2 s |

The in-place failures were `socket hang up`. After the two upgrades, `phala cvms restart` of
the final CVM brought it back as the writer with the last value and version.

## Limits

- Requests wait during the handover, for the length of the two calls through the gateway.
  State is sent in one request, so a large database would hand over a pointer to
  encrypted storage instead.
- dstack-gateway can skip non-writers using `requirements.health_check` in the app compose. The
  server already writes a health file if `HEALTH_FILE` is set. The Phala CLI cannot set
  this field yet, so this example relies on forwarding instead.
- The port is fixed at 8080 in `upgrade.sh`.
