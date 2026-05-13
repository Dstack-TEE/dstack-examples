package main

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"
)

// TestSingleHandshake is the sanity test: bring up two peers with no
// race conditions and assert the link comes up. If this is flaky, the
// rest of the harness is unsound.
func TestSingleHandshake(t *testing.T) {
	sink := captureLogs(t)
	broker := newTestBroker()
	t.Cleanup(broker.Close)

	peers := twoPeers()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	a := newTestPeer(t, broker.URL(), "peer-A", peers, 21000)
	b := newTestPeer(t, broker.URL(), "peer-B", peers, 21000)
	t.Cleanup(a.stop)
	t.Cleanup(b.stop)
	a.start(ctx)
	b.start(ctx)

	elapsed, err := waitBothLinksUp(t, a, b, 30*time.Second)
	if err != nil {
		t.Fatalf("%v\n\nlogs:\n%s", err, sink.String())
	}
	t.Logf("single-handshake convergence: %s", elapsed)
}

// publishAuth forges an auth message from `from` to `to` on the
// broker. The injected ufrag/pwd are deliberately bogus; the peer
// receiving them will treat the value as a fresh remote-auth and
// supersede whatever attempt it has in flight.
//
// This is the deterministic kick used by TestAuthRaceConvergence: it
// simulates the "peer-B restarted while peer-A was mid-dial" scenario
// without needing to actually restart peer-B's process. Because mesh-
// conn's pollLoop reacts identically to a real restart and to a
// forged auth, the resulting race is faithful to the production bug.
func (b *testBroker) publishAuth(from, to, ufrag, pwd string) {
	b.push(to, Message{From: from, Type: "auth", Data: ufrag + ":" + pwd})
}

// waitBothPublishedAuth waits until both peers have observed each
// other's auth (visible in the log as "ice state: Checking" or similar
// progress). On a green path, this is the point at which an injected
// fresh-auth will actually supersede a consumed value.
//
// We use a log-grep ("ice state:") because it's the cheapest progress
// signal that mesh-conn already emits per peer.
func waitForChecking(t *testing.T, sink *testLogSink, peerID string, deadline time.Duration) error {
	t.Helper()
	needle := fmt.Sprintf("[%s] ice state: Checking", peerID)
	endByT := time.Now().Add(deadline)
	for time.Now().Before(endByT) {
		if strings.Contains(sink.String(), needle) {
			return nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return fmt.Errorf("timed out waiting for %q in logs", needle)
}

// TestAuthRaceConvergence is the regression test for the ICE auth-race
// convergence bug.
//
// The bug: when peer-A is mid-dial against peer-B's published auth X,
// and a fresh auth Y arrives from peer-B (process restart, ICE
// restart, etc.), mesh-conn's pollLoop supersedes A's attempt — and
// then A's retry publishes a fresh auth A2, which symmetrically
// supersedes B's mid-attempt, ad infinitum. Both sides flap without
// ever converging.
//
// Deterministic repro: forge a fresh-auth from peer-B to peer-A
// (impersonating a peer-B restart) after both peers have begun ICE
// connectivity checks. This kicks A into the supersession path with a
// known-bad ufrag; A's retry re-publishes its own auth; B's pollLoop
// then supersedes its own in-flight Dial. From there the symmetric
// flap is determined entirely by mesh-conn's retry-and-republish
// logic — exactly the bug we want to catch.
//
// After the fix lands, the flap collapses within one retry cycle and
// both peers reach "link up" inside the deadline.
func TestAuthRaceConvergence(t *testing.T) {
	sink := captureLogs(t)
	broker := newTestBroker()
	t.Cleanup(broker.Close)

	peers := twoPeers()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	a := newTestPeer(t, broker.URL(), "peer-A", peers, 21001)
	b := newTestPeer(t, broker.URL(), "peer-B", peers, 21001)
	t.Cleanup(a.stop)
	t.Cleanup(b.stop)
	a.start(ctx)
	b.start(ctx)

	// Wait until both peers have reached the connectivity-check phase —
	// this is the moment where sess.consumedAuth is non-zero on both
	// sides and a fresh-auth injection will trigger the supersession
	// path. Without this wait, the injection might race ahead of the
	// auth consumption and just get dropped.
	if err := waitForChecking(t, sink, "peer-B", 5*time.Second); err != nil {
		// Peer-A's log line names the OTHER side ("peer-B"), so we
		// wait for "[peer-B] ice state: Checking" which is logged from
		// inside peer-A's Mesh.
		t.Fatalf("peer-A never reached Checking: %v\n\nlogs:\n%s", err, sink.String())
	}
	if err := waitForChecking(t, sink, "peer-A", 5*time.Second); err != nil {
		t.Fatalf("peer-B never reached Checking: %v\n\nlogs:\n%s", err, sink.String())
	}

	// Inject a forged fresh-auth from peer-B to peer-A. This impersonates
	// "peer-B restarted while peer-A was mid-Dial" and triggers the
	// supersession path in peer-A's pollLoop.
	broker.publishAuth("peer-B", "peer-A", "fakeufragXYZ123", "fakepwdABCDEF0123456789012")

	// Now assert that despite the race kick, both peers eventually
	// converge to link-up within 30 s. Before the fix this fails the
	// majority of the time (peer-A's retry republishes auth, supersedes
	// peer-B, and the loop never converges within the deadline). After
	// the fix the asymmetric retry breaks the symmetry within one
	// cycle.
	elapsed, err := waitBothLinksUp(t, a, b, 30*time.Second)
	if err != nil {
		supersedes := sink.countLines("supersedes consumed")
		t.Fatalf("%v after %s\n  supersession count: %d\n\nlogs:\n%s",
			err, elapsed, supersedes, sink.String())
	}
	t.Logf("auth-race convergence: %s", elapsed)
}

// TestRestartConvergence simulates a real peer restart mid-link: kill
// peer-A's Mesh, build a fresh one with the same identity, and assert
// the new peer-A and the still-running peer-B converge to link-up.
//
// This is the second deterministic regression path: even on a clean
// (no forged auth) restart, the symmetry of "both sides see fresh
// auth from each other in close succession" is what triggers the
// flap when the fix isn't in place.
func TestRestartConvergence(t *testing.T) {
	sink := captureLogs(t)
	broker := newTestBroker()
	t.Cleanup(broker.Close)

	peers := twoPeers()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	a := newTestPeer(t, broker.URL(), "peer-A", peers, 21002)
	b := newTestPeer(t, broker.URL(), "peer-B", peers, 21002)
	t.Cleanup(b.stop)
	a.start(ctx)
	b.start(ctx)

	// First handshake — should always succeed.
	if _, err := waitBothLinksUp(t, a, b, 30*time.Second); err != nil {
		a.stop()
		t.Fatalf("initial link-up failed: %v\n\nlogs:\n%s", err, sink.String())
	}

	// Restart peer-A. Peer-B keeps running. Its consumedAuth is set
	// against peer-A's old auth — when the new peer-A publishes fresh
	// auth, peer-B will supersede its attempt and retry. This is the
	// asymmetric-restart pattern that triggered the live-cluster bug.
	a.stop()
	a2 := newTestPeer(t, broker.URL(), "peer-A", peers, 21002)
	t.Cleanup(a2.stop)
	a2.start(ctx)

	elapsed, err := waitBothLinksUp(t, a2, b, 30*time.Second)
	if err != nil {
		supersedes := sink.countLines("supersedes consumed")
		t.Fatalf("post-restart convergence failed: %v after %s\n  supersession count: %d\n\nlogs:\n%s",
			err, elapsed, supersedes, sink.String())
	}
	t.Logf("restart convergence: %s", elapsed)
}
