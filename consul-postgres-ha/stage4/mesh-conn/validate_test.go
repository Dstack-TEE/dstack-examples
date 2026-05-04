package main

import (
	"net"
	"strings"
	"testing"
	"time"
)

func TestValidatePeers_OK(t *testing.T) {
	cfg := &Config{
		SelfID: "ctrl",
		Peers: []Peer{
			{ID: "ctrl", Ports: []int{18000, 18100}},
			{ID: "w1", Ports: []int{18001, 18101}},
		},
	}
	if err := validatePeers(cfg); err != nil {
		t.Fatalf("unexpected: %v", err)
	}
}

func TestValidatePeers_PortCollision(t *testing.T) {
	cfg := &Config{
		SelfID: "ctrl",
		Peers: []Peer{
			{ID: "ctrl", Ports: []int{18000, 18100}},
			{ID: "w1", Ports: []int{18000, 18101}}, // 18000 collides with ctrl
		},
	}
	err := validatePeers(cfg)
	if err == nil || !strings.Contains(err.Error(), "claimed by both") {
		t.Fatalf("want collision error, got %v", err)
	}
}

func TestValidatePeers_MismatchedPortCount(t *testing.T) {
	cfg := &Config{
		SelfID: "ctrl",
		Peers: []Peer{
			{ID: "ctrl", Ports: []int{18000, 18100, 18200}},
			{ID: "w1", Ports: []int{18001, 18101}}, // missing one
		},
	}
	err := validatePeers(cfg)
	if err == nil || !strings.Contains(err.Error(), "expected 3") {
		t.Fatalf("want port-count mismatch, got %v", err)
	}
}

func TestValidatePeers_SelfNotInPeers(t *testing.T) {
	cfg := &Config{
		SelfID: "missing",
		Peers: []Peer{
			{ID: "ctrl", Ports: []int{18000}},
			{ID: "w1", Ports: []int{18001}},
		},
	}
	err := validatePeers(cfg)
	if err == nil || !strings.Contains(err.Error(), "not in PEERS_JSON") {
		t.Fatalf("want self-missing error, got %v", err)
	}
}

func TestValidatePeers_DuplicateID(t *testing.T) {
	cfg := &Config{
		SelfID: "ctrl",
		Peers: []Peer{
			{ID: "ctrl", Ports: []int{18000}},
			{ID: "ctrl", Ports: []int{18001}},
		},
	}
	err := validatePeers(cfg)
	if err == nil || !strings.Contains(err.Error(), "twice") {
		t.Fatalf("want duplicate-id error, got %v", err)
	}
}

func TestValidatePeers_EmptyPorts(t *testing.T) {
	cfg := &Config{
		SelfID: "ctrl",
		Peers: []Peer{
			{ID: "ctrl", Ports: []int{18000}},
			{ID: "w1", Ports: []int{}},
		},
	}
	err := validatePeers(cfg)
	if err == nil || !strings.Contains(err.Error(), "empty Ports") {
		t.Fatalf("want empty-ports error, got %v", err)
	}
}

func TestValidatePeers_PortOutOfRange(t *testing.T) {
	cfg := &Config{
		SelfID: "ctrl",
		Peers: []Peer{
			{ID: "ctrl", Ports: []int{18000}},
			{ID: "w1", Ports: []int{0}},
		},
	}
	err := validatePeers(cfg)
	if err == nil || !strings.Contains(err.Error(), "out of range") {
		t.Fatalf("want out-of-range error, got %v", err)
	}
}

func TestValidatePeers_DigestStableUnderReorder(t *testing.T) {
	a := []Peer{
		{ID: "ctrl", Ports: []int{18000, 18100}},
		{ID: "w1", Ports: []int{18001, 18101}},
	}
	b := []Peer{
		{ID: "w1", Ports: []int{18001, 18101}},
		{ID: "ctrl", Ports: []int{18000, 18100}},
	}
	if peersDigest(a) != peersDigest(b) {
		t.Fatalf("digest changes with peer order: %s vs %s", peersDigest(a), peersDigest(b))
	}
}

func TestValidatePeers_DigestDiffersWithDifferentPorts(t *testing.T) {
	a := []Peer{
		{ID: "ctrl", Ports: []int{18000}},
		{ID: "w1", Ports: []int{18001}},
	}
	b := []Peer{
		{ID: "ctrl", Ports: []int{18000}},
		{ID: "w1", Ports: []int{18002}}, // different
	}
	if peersDigest(a) == peersDigest(b) {
		t.Fatalf("digest collides for different ports")
	}
}

// iceConnPacketConn must delegate deadline methods to the underlying
// conn so quic-go can interrupt blocked reads on context cancel.
// Returning nil from these methods (the previous behavior) leaves
// quic.Dial hung when ICE goes Failed mid-handshake — the surrounding
// runPeerLink retry loop then never gets to retry. Verified once at
// 2026-05-04 against the live cluster; this test pins the behavior so
// a future refactor doesn't regress.
func TestIceConnPacketConn_DeadlinesPropagate(t *testing.T) {
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()

	pkt := &iceConnPacketConn{conn: newCountingConn(a, "test")}

	deadline := time.Now().Add(50 * time.Millisecond)
	if err := pkt.SetReadDeadline(deadline); err != nil {
		t.Fatalf("SetReadDeadline: %v", err)
	}

	buf := make([]byte, 100)
	start := time.Now()
	_, _, err := pkt.ReadFrom(buf)
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("ReadFrom returned nil error past the deadline")
	}
	netErr, ok := err.(net.Error)
	if !ok || !netErr.Timeout() {
		t.Fatalf("expected timeout net.Error, got %v (%T)", err, err)
	}
	// Generous bounds: net.Pipe's deadline implementation is precise
	// enough that 40-300ms covers test-VM jitter without flakes.
	if elapsed < 40*time.Millisecond || elapsed > 300*time.Millisecond {
		t.Errorf("ReadFrom returned in %v, expected ~50ms", elapsed)
	}
}
