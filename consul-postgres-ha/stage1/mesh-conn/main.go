// mesh-conn — userspace UDP port-forwarding agent over pion/ice.
//
// Replaces the earlier TUN-based version. The TUN approach worked but
// gave us a virtual L3 overlay we never really needed: our apps (Consul
// gossip, simple HTTP services) just want a stable peer address they can
// send UDP to.
//
// Naming convention used by the whole cluster:
//   each peer has a unique 16-bit "identity port". On every peer's host,
//   - the local app binds 127.0.0.1:<own_port> (its own identity)
//   - mesh-conn binds 127.0.0.1:<other_peer_port> for every OTHER peer
//   - apps reach peer X by sending UDP to 127.0.0.1:<X_port>
//   - mesh-conn shuffles those packets through one pion/ice connection
//     per peer-pair (direct-when-possible, TURN-relay-when-not)
//
// This means apps don't have to know anything about the overlay: they
// just see a flat localhost address space where each peer (including
// themselves) is addressable as 127.0.0.1:<peer_port>.

package main

import (
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
	"strings"
	"sync"
	"time"

	"github.com/hashicorp/yamux"
	"github.com/pion/ice/v2"
	"github.com/pion/stun"
)

// =============================================================================
// config
// =============================================================================

type Peer struct {
	ID   string `json:"id"`
	Port int    `json:"port"`
}

type Config struct {
	SelfID       string
	Peers        []Peer
	SignalingURL string
	TurnHost     string
	TurnSecret   string
}

func loadConfig() *Config {
	cfg := &Config{
		SelfID:       mustEnv("PEER_ID"),
		SignalingURL: strings.TrimRight(mustEnv("SIGNALING_URL"), "/"),
		TurnHost:     os.Getenv("TURN_HOST"),
		TurnSecret:   os.Getenv("TURN_SHARED_SECRET"),
	}
	if err := json.Unmarshal([]byte(mustEnv("PEERS_JSON")), &cfg.Peers); err != nil {
		log.Fatalf("PEERS_JSON: %v", err)
	}
	if cfg.peerByID(cfg.SelfID) == nil {
		log.Fatalf("PEER_ID %q not in PEERS_JSON", cfg.SelfID)
	}
	return cfg
}

func (c *Config) peerByID(id string) *Peer {
	for i := range c.Peers {
		if c.Peers[i].ID == id {
			return &c.Peers[i]
		}
	}
	return nil
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("missing env %s", k)
	}
	return v
}

// =============================================================================
// main
// =============================================================================

func main() {
	flag.Parse()
	cfg := loadConfig()
	self := cfg.peerByID(cfg.SelfID)

	others := make([]Peer, 0, len(cfg.Peers)-1)
	for _, p := range cfg.Peers {
		if p.ID != cfg.SelfID {
			others = append(others, p)
		}
	}
	log.Printf("mesh-conn: self=%s(:%d) other=%d", cfg.SelfID, self.Port, len(others))

	go pollLoop(cfg)

	var wg sync.WaitGroup
	for _, p := range others {
		wg.Add(1)
		go func(p Peer) {
			defer wg.Done()
			runPeerLink(cfg, *self, p)
		}(p)
	}
	wg.Wait()
	log.Printf("all peer links exited")
}

// =============================================================================
// per-peer link: ICE conn + bound UDP socket on peer's identity port
// =============================================================================

func runPeerLink(cfg *Config, self, peer Peer) {
	for {
		if err := dialAndPump(cfg, self, peer); err != nil {
			log.Printf("[%s] link failed: %v — retrying in 5s", peer.ID, err)
			time.Sleep(5 * time.Second)
			continue
		}
		// dialAndPump returns nil only when the conn closed cleanly.
		log.Printf("[%s] link closed — reconnecting", peer.ID)
	}
}

// Stream tag byte sent as the first byte of each yamux stream so the
// remote side knows what to do with it.
const (
	streamUDP byte = 0x55 // long-lived: length-prefixed UDP datagrams
	streamTCP byte = 0x33 // per-conn:   raw TCP-stream forwarding
)

func dialAndPump(cfg *Config, self, peer Peer) error {
	// 1. Establish ICE.
	conn, err := dialICE(cfg, peer.ID)
	if err != nil {
		return fmt.Errorf("ice: %w", err)
	}
	defer conn.Close()

	// 2. Multiplex with yamux. Lex-smaller side runs the client (matches
	//    ICE Dial); the larger side is the server. Either side can open
	//    streams. We use a long-lived UDP control stream for datagram
	//    forwarding, plus per-TCP-conn ephemeral streams for byte-stream
	//    forwarding. Each new stream's first byte tags its purpose.
	ycfg := yamux.DefaultConfig()
	ycfg.LogOutput = io.Discard       // yamux is chatty
	ycfg.EnableKeepAlive = true
	var sess *yamux.Session
	if cfg.SelfID < peer.ID {
		sess, err = yamux.Client(conn, ycfg)
	} else {
		sess, err = yamux.Server(conn, ycfg)
	}
	if err != nil {
		return fmt.Errorf("yamux: %w", err)
	}
	defer sess.Close()

	// 3. Bind localhost UDP + TCP listeners on peer's identity port.
	udpAddr := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: peer.Port}
	udpSock, err := net.ListenUDP("udp", udpAddr)
	if err != nil {
		return fmt.Errorf("udp listen %s: %w", udpAddr, err)
	}
	defer udpSock.Close()

	tcpAddr := &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: peer.Port}
	tcpLis, err := net.ListenTCP("tcp", tcpAddr)
	if err != nil {
		return fmt.Errorf("tcp listen %s: %w", tcpAddr, err)
	}
	defer tcpLis.Close()

	// 4. Open the long-lived UDP stream. Both sides need to know which
	//    yamux stream is "the UDP one" — the client opens it eagerly,
	//    the server picks up the first stream that arrives with the
	//    streamUDP tag.
	udpStream, err := openOrAcceptUDPStream(sess, cfg.SelfID < peer.ID)
	if err != nil {
		return fmt.Errorf("udp stream: %w", err)
	}

	log.Printf("[%s] link up — listening on 127.0.0.1:%d (udp+tcp), peer reachable via ICE",
		peer.ID, peer.Port)

	udpDst := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: self.Port}
	tcpDst := &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: self.Port}

	errCh := make(chan error, 4)
	// UDP pumps over the dedicated stream.
	go func() { errCh <- pumpUDPSockToStream(udpSock, udpStream) }()
	go func() { errCh <- pumpUDPStreamToSock(udpStream, udpSock, udpDst) }()
	// TCP listener: each local Accept opens a new yamux stream tagged TCP.
	go func() { errCh <- acceptLocalTCP(tcpLis, sess) }()
	// Yamux accept loop: every incoming stream after the UDP one is a TCP forward.
	go func() { errCh <- acceptRemoteStreams(sess, tcpDst) }()
	return <-errCh
}

func openOrAcceptUDPStream(sess *yamux.Session, isClient bool) (*yamux.Stream, error) {
	if isClient {
		s, err := sess.OpenStream()
		if err != nil {
			return nil, err
		}
		if _, err := s.Write([]byte{streamUDP}); err != nil {
			return nil, err
		}
		return s, nil
	}
	// Server: first stream with streamUDP tag is the UDP pipe.
	for {
		s, err := sess.AcceptStream()
		if err != nil {
			return nil, err
		}
		var tag [1]byte
		if _, err := io.ReadFull(s, tag[:]); err != nil {
			s.Close()
			continue
		}
		if tag[0] == streamUDP {
			return s, nil
		}
		// Stray stream before the UDP one — shouldn't happen, but handle it.
		s.Close()
	}
}

func acceptRemoteStreams(sess *yamux.Session, tcpDst *net.TCPAddr) error {
	for {
		s, err := sess.AcceptStream()
		if err != nil {
			return fmt.Errorf("yamux accept: %w", err)
		}
		go handleRemoteStream(s, tcpDst)
	}
}

func handleRemoteStream(s *yamux.Stream, tcpDst *net.TCPAddr) {
	defer s.Close()
	var tag [1]byte
	if _, err := io.ReadFull(s, tag[:]); err != nil {
		return
	}
	switch tag[0] {
	case streamTCP:
		dial, err := net.DialTCP("tcp", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)}, tcpDst)
		if err != nil {
			log.Printf("dial local TCP: %v", err)
			return
		}
		defer dial.Close()
		spliceBoth(s, dial)
	default:
		log.Printf("unexpected stream tag 0x%x", tag[0])
	}
}

func acceptLocalTCP(lis *net.TCPListener, sess *yamux.Session) error {
	for {
		c, err := lis.AcceptTCP()
		if err != nil {
			return fmt.Errorf("tcp accept: %w", err)
		}
		go func(c *net.TCPConn) {
			defer c.Close()
			s, err := sess.OpenStream()
			if err != nil {
				log.Printf("yamux open: %v", err)
				return
			}
			defer s.Close()
			if _, err := s.Write([]byte{streamTCP}); err != nil {
				return
			}
			spliceBoth(s, c)
		}(c)
	}
}

func spliceBoth(a, b io.ReadWriteCloser) {
	done := make(chan struct{}, 2)
	go func() { io.Copy(a, b); done <- struct{}{} }()
	go func() { io.Copy(b, a); done <- struct{}{} }()
	<-done
}

// =============================================================================
// UDP-over-yamux: length-prefixed datagrams on the dedicated stream.
// =============================================================================

func pumpUDPSockToStream(sock *net.UDPConn, s *yamux.Stream) error {
	buf := make([]byte, 1500)
	frame := make([]byte, 2+1500)
	for {
		n, _, err := sock.ReadFromUDP(buf)
		if err != nil {
			return fmt.Errorf("udp sock read: %w", err)
		}
		if n > 65535 {
			continue
		}
		binary.BigEndian.PutUint16(frame[:2], uint16(n))
		copy(frame[2:], buf[:n])
		if _, err := s.Write(frame[:2+n]); err != nil {
			return fmt.Errorf("udp stream write: %w", err)
		}
	}
}

func pumpUDPStreamToSock(s *yamux.Stream, sock *net.UDPConn, dst *net.UDPAddr) error {
	hdr := make([]byte, 2)
	buf := make([]byte, 65536)
	for {
		if _, err := io.ReadFull(s, hdr); err != nil {
			return fmt.Errorf("udp stream read header: %w", err)
		}
		n := int(binary.BigEndian.Uint16(hdr))
		if _, err := io.ReadFull(s, buf[:n]); err != nil {
			return fmt.Errorf("udp stream read body: %w", err)
		}
		if _, err := sock.WriteToUDP(buf[:n], dst); err != nil {
			return fmt.Errorf("udp sock write: %w", err)
		}
	}
}

// =============================================================================
// ICE — one agent per peer pair
// =============================================================================

type peerSession struct {
	agent  *ice.Agent
	authCh chan [2]string
}

var (
	sessionsMu sync.Mutex
	sessions   = map[string]*peerSession{} // key = remote peer id
)

func getOrMakeSession(cfg *Config, remoteID string) (*peerSession, bool) {
	sessionsMu.Lock()
	defer sessionsMu.Unlock()
	if s, ok := sessions[remoteID]; ok {
		return s, false
	}
	s := &peerSession{authCh: make(chan [2]string, 1)}
	sessions[remoteID] = s
	return s, true
}

func clearSession(remoteID string) {
	sessionsMu.Lock()
	defer sessionsMu.Unlock()
	delete(sessions, remoteID)
}

func dialICE(cfg *Config, remoteID string) (*ice.Conn, error) {
	sess, _ := getOrMakeSession(cfg, remoteID)

	var urls []*stun.URI
	if cfg.TurnHost != "" {
		user, pass := turnCreds(cfg.TurnSecret, time.Hour)
		urls = []*stun.URI{
			{Scheme: stun.SchemeTypeSTUN, Host: cfg.TurnHost, Port: 3478, Proto: stun.ProtoTypeUDP},
			{Scheme: stun.SchemeTypeTURN, Host: cfg.TurnHost, Port: 3478, Proto: stun.ProtoTypeUDP, Username: user, Password: pass},
			{Scheme: stun.SchemeTypeTURN, Host: cfg.TurnHost, Port: 3478, Proto: stun.ProtoTypeTCP, Username: user, Password: pass},
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
		return nil, fmt.Errorf("NewAgent: %w", err)
	}
	sess.agent = agent

	if err := agent.OnCandidate(func(c ice.Candidate) {
		if c == nil {
			return
		}
		publish(cfg, remoteID, "candidate", c.Marshal())
	}); err != nil {
		return nil, err
	}
	if err := agent.OnConnectionStateChange(func(s ice.ConnectionState) {
		log.Printf("[%s] ice state: %s", remoteID, s)
	}); err != nil {
		return nil, err
	}

	localUfrag, localPwd, err := agent.GetLocalUserCredentials()
	if err != nil {
		return nil, err
	}
	publish(cfg, remoteID, "auth", localUfrag+":"+localPwd)

	if err := agent.GatherCandidates(); err != nil {
		return nil, err
	}

	var remote [2]string
	select {
	case remote = <-sess.authCh:
	case <-time.After(10 * time.Minute):
		return nil, fmt.Errorf("timeout waiting for remote auth from %s", remoteID)
	}

	ctx := context.Background()
	var conn *ice.Conn
	if cfg.SelfID < remoteID {
		conn, err = agent.Dial(ctx, remote[0], remote[1])
	} else {
		conn, err = agent.Accept(ctx, remote[0], remote[1])
	}
	if err != nil {
		clearSession(remoteID)
		return nil, err
	}

	if pair, perr := agent.GetSelectedCandidatePair(); perr == nil && pair != nil {
		log.Printf("[%s] selected pair: %s <-> %s", remoteID, pair.Local.Type(), pair.Remote.Type())
	}
	return conn, nil
}

func turnCreds(secret string, ttl time.Duration) (string, string) {
	exp := time.Now().Add(ttl).Unix()
	user := fmt.Sprintf("%d:meshconn", exp)
	h := hmac.New(sha1.New, []byte(secret))
	h.Write([]byte(user))
	return user, base64.StdEncoding.EncodeToString(h.Sum(nil))
}

// =============================================================================
// signaling — same wire format as phase-0/icetest
// =============================================================================

type Message struct {
	From string `json:"from"`
	Type string `json:"type"`
	Data string `json:"data"`
}

func publish(cfg *Config, to, typ, data string) {
	body, _ := json.Marshal(Message{From: cfg.SelfID, Type: typ, Data: data})
	resp, err := http.Post(cfg.SignalingURL+"/publish?to="+url.QueryEscape(to),
		"application/json", strings.NewReader(string(body)))
	if err != nil {
		log.Printf("publish err: %v", err)
		return
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
}

func pollLoop(cfg *Config) {
	for {
		resp, err := http.Get(cfg.SignalingURL + "/poll?peer=" + url.QueryEscape(cfg.SelfID))
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
			sess, _ := getOrMakeSession(cfg, m.From)
			switch m.Type {
			case "auth":
				parts := strings.SplitN(m.Data, ":", 2)
				if len(parts) != 2 {
					log.Printf("[%s] bad auth %q", m.From, m.Data)
					continue
				}
				select {
				case sess.authCh <- [2]string{parts[0], parts[1]}:
				default:
					// already delivered for this attempt
				}
			case "candidate":
				if sess.agent == nil {
					// agent not yet created; drop — peer will retry candidates
					continue
				}
				cand, err := ice.UnmarshalCandidate(m.Data)
				if err != nil {
					log.Printf("[%s] bad candidate: %v", m.From, err)
					continue
				}
				if err := sess.agent.AddRemoteCandidate(cand); err != nil {
					log.Printf("[%s] AddRemoteCandidate: %v", m.From, err)
				}
			}
		}
	}
}
