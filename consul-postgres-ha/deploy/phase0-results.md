# Phase-0 ICE feasibility — Results

**Date:** 2026-05-01
**Question:** Can a dstack CVM hole-punch UDP to another dstack CVM?
**Answer:** **YES — direct UDP path established, no TURN relay needed.**

## Setup

- **Coordinator host (public IP):** `155.138.146.255` (Vultr Ubuntu 24.04, Docker 28.2.2)
  - `coturn` 4.6 listening on UDP/TCP 3478, TLS 5349, relay range 49152–49999/UDP
  - tiny signaling broker (Go HTTP) on TCP 7000, ferries ICE
    candidates+ufrag/pwd between peers
  - ufw: `22/tcp`, `3478/udp+tcp`, `5349/tcp`, `7000/tcp`,
    `49152:49999/udp` opened
- **Two throwaway dstack CVMs** (Phala Cloud, default node selection) running
  `consul-postgres-ha/phase0/docker-compose.yaml`. Image:
  `ttl.sh/dstack-mesh-icetest-dfdbf3d5:24h` (built from
  `phase0/icetest/main.go`, pion/ice v2.3.25).

## What ICE saw

Both CVMs gathered the full set of candidates:

| Candidate | peer-a                                | peer-b                                |
| ---       | ---                                   | ---                                   |
| host      | `udp4 10.0.2.10:60017` (docker br0)   | `udp4 10.0.2.10:60124` (docker br0)   |
| host      | `udp4 10.4.0.67:34346` (CVM iface)    | `udp4 10.4.0.64:40649` (CVM iface)    |
| host      | `udp4 172.17.0.1:57770`               | `udp4 172.17.0.1:55481`               |
| **srflx** | `udp4 66.220.6.105:57719` (via STUN)  | `udp4 66.220.6.105:54785` (via STUN)  |
| **srflx** | `udp4 66.220.6.105:50080`             | `udp4 66.220.6.105:53711`             |
| **srflx** | `udp4 66.220.6.105:37149`             | `udp4 66.220.6.105:46063`             |
| relay     | `udp4 155.138.146.255:49278`          | `udp4 155.138.146.255:49691`          |
| relay     | `udp4 155.138.146.255:49323`          | `udp4 155.138.146.255:49660`          |

Key observations:

- Both CVMs share the same public IP `66.220.6.105`. They sit behind the
  same provider-level NAT.
- STUN binding worked (srflx candidates were obtained). Outbound UDP egress
  from a dstack CVM is allowed.
- TURN allocation worked (relay candidates exist). UDP-relay fallback is
  available if direct ever fails.

## What ICE picked

Selected candidate pair (perspective-dependent; same physical path):

```
peer-a view:  CONNECTED via host  <-> srflx
              local : udp4 host  10.0.2.10:60017
              remote: udp4 srflx 66.220.6.105:54785

peer-b view:  CONNECTED via srflx <-> prflx
              local : udp4 srflx 66.220.6.105:54785
              remote: udp4 prflx 66.220.6.105:38077
```

This is the **directly hole-punched UDP path** through the provider NAT
(NAT hairpinning). No TURN relay is in the data path.

## RTT (20 echo round-trips)

```
ping-0  18.96 ms   (warm-up; first packet after handshake)
ping-1   3.63 ms
ping-2   5.46 ms
ping-3   8.18 ms
ping-4   4.80 ms
ping-5   4.78 ms
ping-6   7.65 ms
ping-7   6.12 ms
ping-8   6.53 ms
ping-9   6.60 ms
ping-10  5.40 ms
ping-11  7.10 ms
ping-12  6.06 ms
ping-13  7.11 ms
ping-14  7.09 ms
ping-15  7.87 ms
ping-16  6.62 ms
ping-17  6.54 ms
ping-18  7.75 ms
ping-19  6.59 ms

min:  3.63 ms
median: ~6.6 ms
p95:  ~8.2 ms (excluding warm-up)
max: 18.96 ms (warm-up only)
```

## Bug discovered + fixed during this run

First attempt failed because each peer used a 60s context timeout for
`agent.Dial()` / `agent.Accept()`. peer-b booted ~3 minutes before peer-a
(image pull time), timed out, exited, and its sockets closed before
peer-a came up. Fixed by switching to `context.Background()` (wait
indefinitely; rely on container restart policy for crash resilience).
File: `phase0/icetest/main.go`, around the `Dial`/`Accept` call site.

## Implications for stage-1 design

- **Direct hole-punching works**, so `mesh-conn` for stage 1 should
  configure pion/ice with full STUN+TURN URLs and let ICE pick
  direct-when-possible / relay-as-fallback transparently.
- **Latency is a non-issue**: 6 ms median is far below anything Consul
  gossip / Raft / Patroni cares about.
- **Same-NAT optimization**: in this run both CVMs landed in the same
  provider NAT, which is the easy case. Cross-region or cross-provider
  CVMs would punch through different NATs; behavior could differ. Worth
  re-running Phase-0 across regions before declaring stage-1 portable.
- **TURN remains available** as graceful degradation for the symmetric-NAT
  / firewall-blocked-UDP case.

## Cleanup

Both throwaway CVMs were deleted after results were captured. coturn +
signaling on the coordinator host remain up for stage-1 work.
