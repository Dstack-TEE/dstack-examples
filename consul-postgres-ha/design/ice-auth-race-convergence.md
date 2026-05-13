# Design: fix the mesh-conn ICE auth-race convergence bug + add a loopback regression test

**Status**: design accepted, not started. Single feature branch off
`dstack-consul-ha-db`, PR back into it.

**Why this bundles two punch-list items**: the bug is impossible to
reproduce or fix-and-verify confidently against the live cluster
($-spending each iteration, takes 5+ minutes per cycle, NAT-dependent).
A deterministic loopback harness is the prerequisite. Once it exists,
the fix becomes a small change against a measurable behavior, plus
the harness stays as the regression net for every future mesh-conn
change.

## Why the bug matters

Live-test on 2026-05-13 confirmed: when multiple peer pairs handshake
in close succession (the normal startup case), some pairs flap
indefinitely with this signature:

```
[<peer>] ice state: Checking
[<peer>] fresh auth (ufrag=Y) supersedes consumed (ufrag=X) — aborting attempt
[<peer>] link failed: ice: connecting canceled by caller — retrying in 5s
[<peer>] ice state: Closed
```

Even with `MESH_CONN_RELAY_ONLY=1` set. The cluster forms partial
quorum (some links work, some don't), and end-to-end verification of
anything that needs cross-peer Connect routing (notably Patroni
replica `pg_basebackup`) is blocked.

The supersession logic itself is correct in intent — it prevents
`agent.Dial`/`Accept` from completing against a remote ufrag/pwd the
peer has already rolled. The bug is symmetry: both sides supersede on
each other's fresh auth, and every retry publishes fresh auth (because
each retry builds a new `ice.Agent`, which generates new credentials),
so neither side ever lands on stable auth.

See `mesh-conn/main.go:1231-1240` for the supersede trigger and
`mesh-conn/main.go:407-422` for the fixed 5s retry loop.

## Goal

After this work:

- **A loopback integration test** in `mesh-conn/` that boots two
  `mesh-conn` instances + a real `signaling` broker on `127.0.0.1`,
  drives an ICE handshake between them, and asserts the link comes up
  inside a bounded time window. Test must reproduce the auth-race
  bug deterministically (`go test -run AuthRace` shows the flap in
  the BEFORE state) and pass once the fix lands.
- **The bug fixed.** Two mesh-conn instances handshaking with
  near-simultaneous restart converge to a working link within
  `<bound>` seconds (target: ≤ 15 s, comparable to a single normal
  handshake).
- **The fix in plain bash & Go**, no new dependencies, no protocol
  changes. The wire format (auth + candidate messages on the
  signaling broker) stays identical.

## Non-goals

- Replacing the supersession logic. The protection against stale
  remote auth is correct; the fix is about making the retry cycle
  asymmetric enough to converge.
- Re-architecting pion/ice usage or ICE Restart support.
- Changing the signaling broker's wire format.

## Investigative phase (before any code change)

The fix shape isn't obvious from reading the code alone. The brief
proposes three candidate fixes (below), but the experimenter should
**build the harness first**, reproduce the bug, then test each
candidate against measured behavior:

1. **Asymmetric back-off keyed on peer-ID lex order.** Lower-ID side
   retries with shorter back-off (e.g. 2 s ± jitter); higher-ID side
   retries with longer (e.g. 5 s ± jitter). Lower side becomes the
   "stable" auth publisher; higher side reads it during its longer
   wait. Cheapest to implement (~5 LoC in `runPeerLink`'s retry
   sleep), but doesn't fully break the symmetry — if both sides are
   actively restarting, each retry still republishes auth, so the
   race can still manifest under sustained churn.

2. **Time-gated supersession.** Track each attempt's start time on
   `peerSession`; in `pollLoop`, only supersede if the in-flight
   attempt has been running longer than some minimum window (e.g.
   3 s). The reasoning: in the first few seconds after dial, both
   sides are still racing each other's restart noise; after the
   handshake has had time to make progress, only legitimate restarts
   should be able to abort it. ~15 LoC.

3. **Don't republish auth on supersession-triggered retries.** Track
   the *reason* for the retry. If `dialAndPump` returns because of a
   supersession (not a real failure), reuse the already-published
   auth instead of building a fresh `ice.Agent` with new credentials.
   The peer's fresh auth is already in `authCh`; consume it and try
   again with the existing local agent. ~30 LoC + careful state
   management — pion's `ice.Agent` lifecycle may not support reuse
   cleanly.

Approaches (1) and (2) compose. (1) reduces the rate at which both
sides re-enter the supersede window simultaneously; (2) ensures that
once a handshake has started making progress, it isn't aborted on
spurious peer-side restarts. Implementing both is a real option if
either alone proves insufficient.

The experimenter's job is to:

- Build the harness (see "Harness shape" below).
- Reproduce the failing case deterministically.
- Try (1) alone. Measure convergence time + success rate over N
  trials. Document.
- If insufficient, layer (2) on top. Measure again.
- (3) is the heavier change; only attempt if (1)+(2) don't converge.

## Harness shape

The test should look like this (sketch — exact API up to the
implementer):

```go
func TestAuthRaceConvergence(t *testing.T) {
    // 1. Boot signaling broker on a random loopback port.
    broker := signaling.NewBroker(t, "127.0.0.1:0")
    defer broker.Close()

    // 2. Spawn two mesh-conn instances in goroutines, configured
    //    to talk to each other through the broker.
    peerA := newPeer(t, "peer-A", broker.URL(), peerSpec{
        peers: []Peer{{ID: "peer-B", VIP: 2}},
        selfID: "peer-A", selfVIP: 1,
    })
    peerB := newPeer(t, "peer-B", broker.URL(), peerSpec{
        peers: []Peer{{ID: "peer-A", VIP: 1}},
        selfID: "peer-B", selfVIP: 2,
    })

    // 3. Start both within 100ms of each other — this is the
    //    near-simultaneous-restart pattern that triggers the race.
    go peerA.Run()
    time.Sleep(50 * time.Millisecond)
    go peerB.Run()

    // 4. Assert both peers see "link up" within a deadline.
    //    Before the fix: this times out.
    //    After the fix: passes within ~10s.
    require.NoError(t, waitLinkUp(peerA, "peer-B", 30*time.Second))
    require.NoError(t, waitLinkUp(peerB, "peer-A", 30*time.Second))
}
```

Coverage targets:

- `TestAuthRaceConvergence` — the primary regression test (above).
- `TestSingleHandshake` — sanity check that a single peer-pair
  handshake without simultaneous restart still works.
- `TestRestartConvergence` — kill one peer mid-link, restart it,
  assert the link re-forms within bounded time.
- `TestPeersValidation` — already exists in `validate_test.go`; this
  refactor should not regress it.

A few design notes for the harness:

- **STUN/TURN**: skip. We're on loopback, ICE host candidates work
  fine without coturn. Set `TurnHost=""` in the test peer config and
  ensure `mesh-conn` handles that path (it should already, but worth
  verifying). The bug we're chasing isn't NAT-traversal-related; it's
  in the auth+retry state machine.
- **No real TCP forwarding payload needed.** "Link up" = QUIC
  handshake completed + the `link up` log line emits / a signal can
  be observed. The harness doesn't need to push bytes through.
- **Hook for observing "link up"**: easiest is a callback or channel
  injected into the test peer's config. Alternatively, capture log
  output and grep — uglier but works. Avoid adding a public API to
  mesh-conn just for the test if a test-only hook suffices.
- **Determinism**: the bug needs a specific timing window to
  reproduce. The harness's 50 ms delay between starts is a starting
  guess; the experimenter should sweep that and document which
  delays trigger the race in the BEFORE state.

## Implementation by file (assuming fix candidate (1) succeeds; pivot if not)

- **`mesh-conn/main.go`**:
  - In `runPeerLink`, replace the fixed `time.Sleep(5*time.Second)`
    with a function that returns a duration based on `self.ID <
    peer.ID` plus a deterministic jitter.
  - Document the asymmetry rationale in a comment above the retry
    sleep.
- **`mesh-conn/main_test.go`** (new):
  - The harness + the four test cases above.
  - `signaling` broker is the production one — import the binary's
    package or vendor a thin wrapper. If the broker's a separate
    Go module, write a minimal in-test broker that implements the
    same `/publish` + `/poll` shape (likely the cleanest, since
    `signaling/` is its own go.mod).
- **`mesh-conn/go.mod`**: any new test-only deps (e.g.
  `require/assert` if not already there).
- **`ROBUSTNESS.md`**:
  - Move the "ICE auth-race convergence bug" section from
    "Recommended fixes" to "Already shipped" once verified.
- **Delete `design/ice-auth-race-convergence.md`** (this file) after
  the implementation lands.

## Success criteria

- [ ] `go test -run AuthRace -count 50 ./mesh-conn/...` passes 50/50
      times (deterministic, no flake).
- [ ] On the BEFORE branch (before the fix), the same test fails
      ≥ 30/50 times within the 30-second deadline. The agent should
      record this observation in the PR.
- [ ] The "single handshake" test still passes — no regression on
      the non-racy path.
- [ ] `mesh-conn/main.go` line count grows by ≤ 50 LoC for the fix
      itself (excluding the test).
- [ ] All `mesh-conn` unit tests pass: `go test -count=1 ./...`.
- [ ] Optional but recommended: live verification — rebuild images,
      deploy a 6-CVM cluster, observe that all peer pairs handshake
      within 30 s of CVM creation, run a `FAILOVER.md` recipe end
      to end (specifically the disk-loss `pg_basebackup` path that
      we observed failing on 2026-05-13). Spend ≤ $10. If skipped,
      surface that explicitly in the final report.

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| Asymmetric back-off (fix #1) reduces the race rate but doesn't eliminate it | Layer fix #2 (time-gated supersession) on top. The brief assumes the experimenter will measure and pivot. |
| Loopback harness doesn't exercise pion/ice the same way real ICE-over-coturn does | The auth-race bug is in mesh-conn's outer state machine (runPeerLink + pollLoop + sess.consumedAuth), not in pion. Loopback ICE host candidates are sufficient. If a follow-up reveals the bug only manifests with relay candidates, add a coturn fixture later. |
| Test harness depends on production `signaling` package which has its own go.mod | Inline a minimal `/publish` + `/poll` broker in the test file. The wire format is JSON arrays of `{from, type, data}` messages; ~50 LoC of net/http handler. |
| pion/ice agent reuse (fix #3) hits unsupported state in the library | Don't attempt #3 unless #1 + #2 together fail to converge. The brief flags it as the heavier option. |
| Live verification skipped → fix appears to work locally but doesn't on dstack NAT | Mark this explicitly in the report. The deterministic loopback test is the *primary* deliverable; live verification is supplemental. If live verification reveals a separate issue, that's a follow-up. |

## Hand-off

Implementing agent:

1. Read `mesh-conn/main.go` end-to-end. Focus on `runPeerLink`
   (407-423), `dialAndPump` (452-…), `dialICE` (990-…), `pollLoop`
   (~1180-…), and the `peerSession` struct (956-).
2. Read this doc and the "ICE auth-race convergence bug" section of
   `ROBUSTNESS.md`.
3. Build the harness first. **Do not write any fix code until you
   can reproduce the bug in a unit test.** The deterministic repro
   is the load-bearing deliverable; everything else depends on it.
4. Once reproducing: try fix candidate (1), measure, document.
   Iterate to (2) or (1+2) if needed. Avoid (3) unless necessary.
5. Land the fix + test in a single feature branch.
6. Optionally live-verify per "Success criteria" #6.
7. Update ROBUSTNESS.md.
8. Delete this doc.
9. Report back with: the BEFORE failure rate (n trials), the AFTER
   success rate (n trials), the chosen fix shape, and any deviations
   from this brief with file:line citations.
