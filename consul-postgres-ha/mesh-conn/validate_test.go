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
			{ID: "ctrl", Vip: 1},
			{ID: "w1", Vip: 2},
		},
	}
	if err := validatePeers(cfg); err != nil {
		t.Fatalf("unexpected: %v", err)
	}
}

func TestValidatePeers_VipCollision(t *testing.T) {
	cfg := &Config{
		SelfID: "ctrl",
		Peers: []Peer{
			{ID: "ctrl", Vip: 1},
			{ID: "w1", Vip: 1}, // collides with ctrl
		},
	}
	err := validatePeers(cfg)
	if err == nil || !strings.Contains(err.Error(), "claimed by both") {
		t.Fatalf("want collision error, got %v", err)
	}
}

func TestValidatePeers_SelfNotInPeers(t *testing.T) {
	cfg := &Config{
		SelfID: "missing",
		Peers: []Peer{
			{ID: "ctrl", Vip: 1},
			{ID: "w1", Vip: 2},
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
			{ID: "ctrl", Vip: 1},
			{ID: "ctrl", Vip: 2},
		},
	}
	err := validatePeers(cfg)
	if err == nil || !strings.Contains(err.Error(), "twice") {
		t.Fatalf("want duplicate-id error, got %v", err)
	}
}

func TestValidatePeers_VipOutOfRange(t *testing.T) {
	cases := []struct {
		name string
		vip  int
	}{
		{"zero", 0},
		{"too-big", 255},
		{"negative", -1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg := &Config{
				SelfID: "ctrl",
				Peers: []Peer{
					{ID: "ctrl", Vip: 1},
					{ID: "w1", Vip: tc.vip},
				},
			}
			err := validatePeers(cfg)
			if err == nil || !strings.Contains(err.Error(), "out of range") {
				t.Fatalf("want out-of-range error for vip=%d, got %v", tc.vip, err)
			}
		})
	}
}

func TestValidatePeers_DigestStableUnderReorder(t *testing.T) {
	a := []Peer{
		{ID: "ctrl", Vip: 1},
		{ID: "w1", Vip: 2},
	}
	b := []Peer{
		{ID: "w1", Vip: 2},
		{ID: "ctrl", Vip: 1},
	}
	if peersDigest(a) != peersDigest(b) {
		t.Fatalf("digest changes with peer order: %s vs %s", peersDigest(a), peersDigest(b))
	}
}

func TestValidatePeers_DigestDiffersWithDifferentVips(t *testing.T) {
	a := []Peer{
		{ID: "ctrl", Vip: 1},
		{ID: "w1", Vip: 2},
	}
	b := []Peer{
		{ID: "ctrl", Vip: 1},
		{ID: "w1", Vip: 3}, // different
	}
	if peersDigest(a) == peersDigest(b) {
		t.Fatalf("digest collides for different vips")
	}
}

func TestPeer_VipAddr(t *testing.T) {
	p := Peer{ID: "x", Vip: 7}
	got := p.vipAddr().String()
	if got != "127.50.0.7" {
		t.Fatalf("vipAddr() = %q, want 127.50.0.7", got)
	}
}

func TestAllowedPort(t *testing.T) {
	for _, p := range []int{21000, 21001, 8300, 8301} {
		if !allowedPort(p) {
			t.Errorf("allowedPort(%d) = false, want true", p)
		}
	}
	for _, p := range []int{0, 80, 5432, 8008} {
		if allowedPort(p) {
			t.Errorf("allowedPort(%d) = true, want false (not in static infra allowlist)", p)
		}
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
