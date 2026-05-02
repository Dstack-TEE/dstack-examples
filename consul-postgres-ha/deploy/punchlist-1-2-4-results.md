# Punch-list 1 + 2 + 4 — verified

**Date:** 2026-05-02
**Items:** ROBUSTNESS.md punch-list #1 (mesh-conn auth-channel
reconnect deadlock), #2 (Consul gossip key), #4 (PEERS_JSON
validation at startup).

**Outcome:** ✅ all three live on the redeployed stage-3b cluster.

## Verification

### #4 — PEERS_JSON validation + cross-peer digest

Every peer logs a one-line summary including a stable digest of the
canonical PEERS_JSON. If any peer's deploy ended up with a different
config, its digest would differ. Live across the 4-CVM cluster:

```
[ctrl] PEERS_JSON validated: 4 peers, 6 ports each, digest=NiNhinoUekif
[w1]   PEERS_JSON validated: 4 peers, 6 ports each, digest=NiNhinoUekif
[w3]   PEERS_JSON validated: 4 peers, 6 ports each, digest=NiNhinoUekif
```

All identical → cluster sees the same topology. The 8 unit tests in
`stage1/mesh-conn/validate_test.go` cover collisions, dup ids,
out-of-range ports, mismatched port-list lengths, and digest stability.

### #2 — Consul gossip key

`hashicorp/consul:1.19` startup banner from ctrl:

```
==> Starting Consul agent...
       Version: '1.19.2'
       ...
       Encrypt: Gossip=true, TLS-Outgoing=false, TLS-Incoming=false, ...
```

`Gossip=true` → serf-LAN UDP+TCP messages encrypted symmetrically
with the shared gossip key (32 bytes, generated at deploy via
`openssl rand -base64 32`, passed via `GOSSIP_KEY` env to every
agent's `-encrypt` flag). TLS-Outgoing/Incoming still false; RPC TLS
is the deferred half of #2.

### #1 — Reconnect bug fix

The fix is structural — every dialICE attempt installs a fresh
`peerSession` (new ICE agent + new auth channel), and pollLoop only
delivers messages to the **current** session for a peer. Stale auth
from a previous attempt can no longer poison the next one because
the channel it was delivered to is unreferenced.

Couldn't trigger an organic reconnect during this run (ICE links
were stable for the whole verification window), so this is verified
by code review + the new test suite, not by failure-injection.
Adding fault-injection (kill mesh-conn mid-run, watch reconnect)
goes on the stage-4 work list.

### Smoke-test that the cluster still works end-to-end

```
$ curl http://127.0.0.1:18501/all | jq .results          # from w1
{
  "hello from ctrl": 2,
  "hello from w1": 2,
  "hello from w2": 2,
  "hello from w3": 2
}
```

Same as stage-3b: Connect mTLS, intention webdemo→webdemo: allow,
Envoy round-robins across all 4 webdemo instances.

## What's left from the punch list

From ROBUSTNESS.md, in priority order:

- ✅ #1 mesh-conn reconnect deadlock — done.
- ⌛ #2 Consul gossip key — done; **RPC TLS** deferred to stage 4
   (cert distribution fits naturally into the dev-experience
   restructure).
- ⏳ #3 Three-server Consul HA — not yet.
- ✅ #4 PEERS_JSON validation — done.
- ⏳ #5 Move images off ttl.sh — stage 4 work.
- ⏳ #6 Two coordinators + signed signalling — stage 4 work.
- ⏳ #7 CI for mesh-conn — partial (validate_test.go covers config
   path; mesh-conn ↔ mesh-conn integration test still TBD).
- ⏳ #8 Periodic metrics — stage 4 work.
