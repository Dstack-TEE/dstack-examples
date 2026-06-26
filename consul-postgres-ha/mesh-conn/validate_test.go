package main

import (
	"net"
	"strings"
	"testing"
	"time"
)

// defaultAllowlist is the canonical 3-service-example shape the
// platform sidecar emits today (webdemo + postgres-master/-replica
// share a sidecar, so two sidecar ports + two Consul-infra ports).
// Tests that only care about peer validation use this so they have a
// non-empty allowlist; tests that target the allowlist itself
// construct their own.
func defaultAllowlist() []InfraPort {
	return []InfraPort{
		{Port: 21000, UDP: false},
		{Port: 21001, UDP: false},
		{Port: 8300, UDP: false},
		{Port: 8301, UDP: true},
	}
}

func okConfig() *Config {
	return &Config{
		SelfID: "ctrl",
		Peers: []Peer{
			{ID: "ctrl", Vip: 1},
			{ID: "w1", Vip: 2},
		},
		Allowlist: defaultAllowlist(),
	}
}

func TestValidateConfig_OK(t *testing.T) {
	if err := validateConfig(okConfig()); err != nil {
		t.Fatalf("unexpected: %v", err)
	}
}

func TestValidatePeers_VipCollision(t *testing.T) {
	cfg := okConfig()
	cfg.Peers = []Peer{
		{ID: "ctrl", Vip: 1},
		{ID: "w1", Vip: 1}, // collides with ctrl
	}
	err := validateConfig(cfg)
	if err == nil || !strings.Contains(err.Error(), "claimed by both") {
		t.Fatalf("want collision error, got %v", err)
	}
}

func TestValidatePeers_SelfNotInPeers(t *testing.T) {
	cfg := okConfig()
	cfg.SelfID = "missing"
	err := validateConfig(cfg)
	if err == nil || !strings.Contains(err.Error(), "not in PEERS_JSON") {
		t.Fatalf("want self-missing error, got %v", err)
	}
}

func TestValidatePeers_DuplicateID(t *testing.T) {
	cfg := okConfig()
	cfg.Peers = []Peer{
		{ID: "ctrl", Vip: 1},
		{ID: "ctrl", Vip: 2},
	}
	err := validateConfig(cfg)
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
			cfg := okConfig()
			cfg.Peers = []Peer{
				{ID: "ctrl", Vip: 1},
				{ID: "w1", Vip: tc.vip},
			}
			err := validateConfig(cfg)
			if err == nil || !strings.Contains(err.Error(), "out of range") {
				t.Fatalf("want out-of-range error for vip=%d, got %v", tc.vip, err)
			}
		})
	}
}

func TestValidateAllowlist_Empty(t *testing.T) {
	cfg := okConfig()
	cfg.Allowlist = nil
	err := validateConfig(cfg)
	if err == nil || !strings.Contains(err.Error(), "empty") {
		t.Fatalf("want empty-allowlist error, got %v", err)
	}
}

func TestValidateAllowlist_Duplicate(t *testing.T) {
	cfg := okConfig()
	cfg.Allowlist = []InfraPort{
		{Port: 21000, UDP: false},
		{Port: 21000, UDP: false}, // dup
	}
	err := validateConfig(cfg)
	if err == nil || !strings.Contains(err.Error(), "twice") {
		t.Fatalf("want duplicate-port error, got %v", err)
	}
}

func TestValidateAllowlist_PortOutOfRange(t *testing.T) {
	cases := []struct {
		name string
		port int
	}{
		{"zero", 0},
		{"too-big", 70000},
		{"negative", -1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg := okConfig()
			cfg.Allowlist = []InfraPort{
				{Port: 21000, UDP: false},
				{Port: tc.port, UDP: false},
			}
			err := validateConfig(cfg)
			if err == nil || !strings.Contains(err.Error(), "out of range") {
				t.Fatalf("want out-of-range error for port=%d, got %v", tc.port, err)
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

func TestConfig_AllowedPort(t *testing.T) {
	cfg := &Config{Allowlist: defaultAllowlist()}
	for _, p := range []int{21000, 21001, 8300, 8301} {
		if !cfg.allowedPort(p) {
			t.Errorf("allowedPort(%d) = false, want true", p)
		}
	}
	for _, p := range []int{0, 80, 5432, 8008} {
		if cfg.allowedPort(p) {
			t.Errorf("allowedPort(%d) = true, want false (not in default allowlist)", p)
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
