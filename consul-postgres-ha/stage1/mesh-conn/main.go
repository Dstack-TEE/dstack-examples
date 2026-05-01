// mesh-conn — userspace L3 overlay for dstack CVMs over ICE.
//
// Each CVM runs one mesh-conn instance. mesh-conn:
//  1. Creates a TUN device, assigns it a virtual IP from a /24 subnet
//     all peers share.
//  2. For every other peer, establishes a pion/ice connection (signaling
//     + STUN/TURN identical to phase-0).
//  3. Plumbs packets between the TUN device and ICE connections, routing
//     by destination IP.
//
// Consul (or any other UDP/TCP service) running on top sees a flat L3
// network and gossips/connects normally.
//
// MVP scope: exactly two peers (PEER_ID and PARTNER_ID) with one ICE
// link. Multi-peer comes next.

package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/pion/ice/v2"
	"github.com/pion/stun"
	"github.com/songgao/water"
)

func main() {
	flag.Parse()

	cfg := loadConfig()
	log.Printf("mesh-conn: peer=%s partner=%s virtIP=%s tun=%s",
		cfg.PeerID, cfg.PartnerID, cfg.VirtualIP, cfg.TunName)

	tun, err := openTun(cfg.TunName, cfg.VirtualIP, cfg.VirtualPrefix)
	if err != nil {
		log.Fatalf("tun setup: %v", err)
	}
	defer tun.Close()
	log.Printf("tun device %s up with %s/%d", tun.Name(), cfg.VirtualIP, cfg.VirtualPrefix)

	conn, agent, err := dialICE(cfg)
	if err != nil {
		log.Fatalf("ice dial: %v", err)
	}
	if pair, perr := agent.GetSelectedCandidatePair(); perr == nil && pair != nil {
		log.Printf("ICE selected pair: local=%s remote=%s", pair.Local.Type(), pair.Remote.Type())
		log.Printf("  local : %s", pair.Local.String())
		log.Printf("  remote: %s", pair.Remote.String())
	}
	log.Printf("ICE connection established to %s", cfg.PartnerID)

	// Bidirectional copy. Each L3 packet read from TUN is sent as one
	// length-framed message over the ICE conn (stream-oriented). Receive
	// side reads frames and writes them back to TUN.
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); pumpTunToICE(tun, conn) }()
	go func() { defer wg.Done(); pumpICEToTun(conn, tun) }()
	wg.Wait()
	log.Printf("mesh-conn exiting")
}

// =============================================================================
// config
// =============================================================================

type Config struct {
	PeerID        string
	PartnerID     string
	SignalingURL  string
	TurnHost      string
	TurnSecret    string
	VirtualIP     string // e.g. "10.66.0.2"
	VirtualPrefix int    // e.g. 24
	TunName       string // optional, default "mesh0"
}

func loadConfig() *Config {
	c := &Config{
		PeerID:        mustEnv("PEER_ID"),
		PartnerID:     mustEnv("PARTNER_ID"),
		SignalingURL:  strings.TrimRight(mustEnv("SIGNALING_URL"), "/"),
		TurnHost:      os.Getenv("TURN_HOST"),
		TurnSecret:    os.Getenv("TURN_SHARED_SECRET"),
		VirtualIP:     mustEnv("VIRTUAL_IP"),
		VirtualPrefix: 24,
		TunName:       envOr("TUN_NAME", "mesh0"),
	}
	return c
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("missing env %s", k)
	}
	return v
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// =============================================================================
// TUN setup (Linux, requires NET_ADMIN + /dev/net/tun)
// =============================================================================

func openTun(name, ip string, prefix int) (*water.Interface, error) {
	cfg := water.Config{DeviceType: water.TUN}
	cfg.Name = name
	iface, err := water.New(cfg)
	if err != nil {
		return nil, fmt.Errorf("water.New: %w", err)
	}
	// Bring it up + assign IP via iproute2.
	if err := run("ip", "addr", "add", fmt.Sprintf("%s/%d", ip, prefix), "dev", iface.Name()); err != nil {
		return nil, err
	}
	if err := run("ip", "link", "set", "dev", iface.Name(), "up", "mtu", "1300"); err != nil {
		return nil, err
	}
	return iface, nil
}

func run(args ...string) error {
	cmd := exec.Command(args[0], args[1:]...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s: %v: %s", strings.Join(args, " "), err, bytes.TrimSpace(out))
	}
	return nil
}

// =============================================================================
// ICE
// =============================================================================

func dialICE(cfg *Config) (*ice.Conn, *ice.Agent, error) {
	var urls []*stun.URI
	if cfg.TurnHost != "" {
		user, pass := turnCreds(cfg.TurnSecret, time.Hour)
		urls = []*stun.URI{
			{Scheme: stun.SchemeTypeSTUN, Host: cfg.TurnHost, Port: 3478, Proto: stun.ProtoTypeUDP},
			{Scheme: stun.SchemeTypeTURN, Host: cfg.TurnHost, Port: 3478, Proto: stun.ProtoTypeUDP,
				Username: user, Password: pass},
			{Scheme: stun.SchemeTypeTURN, Host: cfg.TurnHost, Port: 3478, Proto: stun.ProtoTypeTCP,
				Username: user, Password: pass},
		}
	}
	agent, err := ice.NewAgent(&ice.AgentConfig{
		Urls:         urls,
		NetworkTypes: []ice.NetworkType{ice.NetworkTypeUDP4, ice.NetworkTypeTCP4},
		CandidateTypes: []ice.CandidateType{
			ice.CandidateTypeHost,
			ice.CandidateTypeServerReflexive,
			ice.CandidateTypePeerReflexive,
			ice.CandidateTypeRelay,
		},
	})
	if err != nil {
		return nil, nil, fmt.Errorf("ice.NewAgent: %w", err)
	}

	if err := agent.OnCandidate(func(c ice.Candidate) {
		if c == nil {
			return
		}
		log.Printf("local candidate: %s", c.Type())
		publish(cfg, "candidate", c.Marshal())
	}); err != nil {
		return nil, nil, err
	}

	if err := agent.OnConnectionStateChange(func(s ice.ConnectionState) {
		log.Printf("ice state: %s", s)
	}); err != nil {
		return nil, nil, err
	}

	localUfrag, localPwd, err := agent.GetLocalUserCredentials()
	if err != nil {
		return nil, nil, err
	}
	publish(cfg, "auth", localUfrag+":"+localPwd)

	if err := agent.GatherCandidates(); err != nil {
		return nil, nil, err
	}

	authCh := make(chan [2]string, 1)
	go pollLoop(cfg, agent, authCh)

	var remote [2]string
	select {
	case remote = <-authCh:
	case <-time.After(10 * time.Minute):
		return nil, nil, fmt.Errorf("timed out waiting for partner auth")
	}
	log.Printf("got partner auth, role=%s", roleName(cfg))

	ctx := context.Background()
	var conn *ice.Conn
	if cfg.PeerID < cfg.PartnerID {
		conn, err = agent.Dial(ctx, remote[0], remote[1])
	} else {
		conn, err = agent.Accept(ctx, remote[0], remote[1])
	}
	if err != nil {
		return nil, nil, err
	}
	return conn, agent, nil
}

func roleName(cfg *Config) string {
	if cfg.PeerID < cfg.PartnerID {
		return "controlling/Dial"
	}
	return "controlled/Accept"
}

func turnCreds(secret string, ttl time.Duration) (string, string) {
	exp := time.Now().Add(ttl).Unix()
	user := fmt.Sprintf("%d:meshconn", exp)
	h := hmac.New(sha1.New, []byte(secret))
	h.Write([]byte(user))
	return user, base64.StdEncoding.EncodeToString(h.Sum(nil))
}

// =============================================================================
// Signaling (same wire format as phase-0/icetest)
// =============================================================================

type Message struct {
	From string `json:"from"`
	Type string `json:"type"`
	Data string `json:"data"`
}

func publish(cfg *Config, typ, data string) {
	body, _ := json.Marshal(Message{From: cfg.PeerID, Type: typ, Data: data})
	resp, err := http.Post(cfg.SignalingURL+"/publish?to="+url.QueryEscape(cfg.PartnerID),
		"application/json", strings.NewReader(string(body)))
	if err != nil {
		log.Printf("publish err: %v", err)
		return
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
}

func pollLoop(cfg *Config, agent *ice.Agent, authCh chan<- [2]string) {
	authSent := false
	for {
		resp, err := http.Get(cfg.SignalingURL + "/poll?peer=" + url.QueryEscape(cfg.PeerID))
		if err != nil {
			log.Printf("poll err: %v", err)
			time.Sleep(time.Second)
			continue
		}
		var msgs []Message
		if err := json.NewDecoder(resp.Body).Decode(&msgs); err != nil {
			log.Printf("poll decode: %v", err)
			resp.Body.Close()
			time.Sleep(time.Second)
			continue
		}
		resp.Body.Close()
		for _, m := range msgs {
			switch m.Type {
			case "auth":
				if authSent {
					continue
				}
				parts := strings.SplitN(m.Data, ":", 2)
				if len(parts) != 2 {
					log.Printf("bad auth %q", m.Data)
					continue
				}
				authCh <- [2]string{parts[0], parts[1]}
				authSent = true
			case "candidate":
				cand, err := ice.UnmarshalCandidate(m.Data)
				if err != nil {
					log.Printf("bad candidate: %v", err)
					continue
				}
				if err := agent.AddRemoteCandidate(cand); err != nil {
					log.Printf("AddRemoteCandidate: %v", err)
				}
			}
		}
	}
}

// =============================================================================
// TUN <-> ICE pumps
//
// ice.Conn rides on UDP; each Read/Write maps to one datagram. The TUN
// device also reads/writes whole packets. So we just pass packets across
// 1:1, no framing needed. MTU is set to 1300 so we stay well under the
// 1500-byte path MTU after any ICE/UDP overhead.
// =============================================================================

const maxPacket = 1500

func pumpTunToICE(tun *water.Interface, conn *ice.Conn) {
	buf := make([]byte, maxPacket)
	for {
		n, err := tun.Read(buf)
		if err != nil {
			log.Printf("tun read: %v", err)
			return
		}
		if n == 0 {
			continue
		}
		if _, err := conn.Write(buf[:n]); err != nil {
			log.Printf("ice write: %v", err)
			return
		}
	}
}

func pumpICEToTun(conn *ice.Conn, tun *water.Interface) {
	buf := make([]byte, maxPacket)
	for {
		n, err := conn.Read(buf)
		if err != nil {
			log.Printf("ice read: %v", err)
			return
		}
		if n == 0 {
			continue
		}
		if _, err := tun.Write(buf[:n]); err != nil {
			log.Printf("tun write: %v", err)
			return
		}
	}
}

// keep imports stable across edits
var _ = net.ParseIP
var _ = binary.BigEndian
var _ = io.ReadFull
