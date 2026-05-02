// mesh-conn — userspace UDP port-forwarding agent over pion/ice.
//
// Replaces the earlier TUN-based version. The TUN approach worked but
// gave us a virtual L3 overlay we never really needed: our apps (Consul
// gossip, simple HTTP services) just want a stable peer address they can
// send UDP to.
//
// Naming convention used by the whole cluster:
//   each peer declares a list of "identity ports" — one per protocol.
//   For a Consul deployment that's typically four:
//     index 0 = serf_lan (UDP+TCP), 1 = server-RPC (TCP),
//     index 2 = HTTP API (TCP),     3 = gRPC/xDS (TCP)
//
//   On every peer's host:
//   - the local app binds 127.0.0.1:<own_port[i]> for protocol i
//   - mesh-conn binds 127.0.0.1:<peer_port[i]> for every OTHER peer
//     and every protocol i
//   - apps reach peer X on protocol i by sending UDP/TCP to
//     127.0.0.1:<X.ports[i]>
//
// All N peer-pair connections multiplex over one pion/ice connection
// per pair, wrapped in yamux. Each yamux stream's first three bytes
// are (tag, port-as-uint16-big-endian) where port is the receiver's
// own identity port — the receiver looks it up in self.ports and
// dispatches to the matching local UDP socket / dials the matching
// local TCP service.

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
	ID    string `json:"id"`
	Ports []int  `json:"ports"`
}

// hasPort returns the index of port in p.Ports, or -1 if absent.
func (p *Peer) hasPort(port int) int {
	for i, q := range p.Ports {
		if q == port {
			return i
		}
	}
	return -1
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
	if err := validatePeers(cfg); err != nil {
		log.Fatalf("PEERS_JSON: %v", err)
	}
	return cfg
}

// validatePeers fails fast on any silent mis-configuration that would
// otherwise manifest as confusing runtime failures: collided ports,
// missing self, mismatched port-list lengths, etc. Bound at startup
// because a peer's PEERS_JSON is shared with every other peer's
// configuration and must round-trip identically across the cluster.
func validatePeers(cfg *Config) error {
	if len(cfg.Peers) < 2 {
		return fmt.Errorf("need at least 2 peers in PEERS_JSON, got %d", len(cfg.Peers))
	}

	seenIDs := map[string]bool{}
	allPorts := map[int]string{} // port -> peer.ID owning it (for collision detection)
	expectedPortCount := -1
	selfFound := false

	for i, p := range cfg.Peers {
		if p.ID == "" {
			return fmt.Errorf("peer[%d] has empty id", i)
		}
		if seenIDs[p.ID] {
			return fmt.Errorf("peer id %q appears twice in PEERS_JSON", p.ID)
		}
		seenIDs[p.ID] = true
		if p.ID == cfg.SelfID {
			selfFound = true
		}

		if len(p.Ports) == 0 {
			return fmt.Errorf("peer %q has empty Ports list", p.ID)
		}
		if expectedPortCount < 0 {
			expectedPortCount = len(p.Ports)
		} else if len(p.Ports) != expectedPortCount {
			return fmt.Errorf("peer %q has %d ports, expected %d (every peer's port-list must have the same length — index i is the same protocol slot across peers)",
				p.ID, len(p.Ports), expectedPortCount)
		}

		// Each port must be unique cluster-wide: mesh-conn binds OTHER
		// peers' ports on 127.0.0.1, so two peers can't share a port
		// number or one would shadow the other.
		seenSelf := map[int]bool{}
		for j, port := range p.Ports {
			if port <= 0 || port > 65535 {
				return fmt.Errorf("peer %q ports[%d]=%d is out of range", p.ID, j, port)
			}
			if seenSelf[port] {
				return fmt.Errorf("peer %q has duplicate port %d in its own Ports list", p.ID, port)
			}
			seenSelf[port] = true
			if owner, ok := allPorts[port]; ok {
				return fmt.Errorf("port %d is claimed by both peer %q and peer %q — every identity port must be globally unique",
					port, owner, p.ID)
			}
			allPorts[port] = p.ID
		}
	}

	if !selfFound {
		return fmt.Errorf("PEER_ID %q not in PEERS_JSON (peers: %v)", cfg.SelfID, knownIDs(cfg.Peers))
	}

	// Log a digest of the validated config so operators can check that
	// every peer in the cluster sees the same PEERS_JSON. Differences
	// across peers would indicate a deploy-script discrepancy.
	digest := peersDigest(cfg.Peers)
	log.Printf("PEERS_JSON validated: %d peers, %d ports each, digest=%s",
		len(cfg.Peers), expectedPortCount, digest)
	return nil
}

func knownIDs(peers []Peer) []string {
	ids := make([]string, 0, len(peers))
	for _, p := range peers {
		ids = append(ids, p.ID)
	}
	return ids
}

// peersDigest is a short stable hash of the canonical PEERS_JSON used
// only to make config-drift diagnosable across peers' logs.
func peersDigest(peers []Peer) string {
	keys := make([]string, len(peers))
	for i, p := range peers {
		keys[i] = p.ID
	}
	// Stable sort by ID so a re-ordered PEERS_JSON gives the same digest.
	// Then encode as a deterministic string.
	for i := 1; i < len(keys); i++ {
		for j := i; j > 0 && keys[j] < keys[j-1]; j-- {
			keys[j], keys[j-1] = keys[j-1], keys[j]
		}
	}
	var buf strings.Builder
	for _, id := range keys {
		buf.WriteString(id)
		buf.WriteByte(':')
		// find peer
		for _, p := range peers {
			if p.ID == id {
				for _, port := range p.Ports {
					fmt.Fprintf(&buf, "%d,", port)
				}
				break
			}
		}
		buf.WriteByte('|')
	}
	h := sha1.Sum([]byte(buf.String()))
	return base64.RawStdEncoding.EncodeToString(h[:])[:12]
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
	log.Printf("mesh-conn: self=%s ports=%v other=%d", cfg.SelfID, self.Ports, len(others))

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

// Stream header layout: 3 bytes per stream open.
//   byte 0 = tag (streamUDP or streamTCP)
//   bytes 1-2 = receiver-side port (big-endian uint16) — the port number
//     the receiver itself binds locally; receiver looks it up in its own
//     Ports list to find the index/protocol slot
const (
	streamUDP byte = 0x55 // long-lived per-port UDP datagram pipe
	streamTCP byte = 0x33 // per-conn TCP byte-stream forwarder
)

func dialAndPump(cfg *Config, self, peer Peer) error {
	if len(self.Ports) != len(peer.Ports) {
		return fmt.Errorf("port-count mismatch: self has %d ports, peer has %d", len(self.Ports), len(peer.Ports))
	}

	// 1. Establish ICE + wrap with yamux.
	conn, err := dialICE(cfg, peer.ID)
	if err != nil {
		return fmt.Errorf("ice: %w", err)
	}
	defer conn.Close()

	ycfg := yamux.DefaultConfig()
	ycfg.LogOutput = io.Discard
	ycfg.EnableKeepAlive = true
	isClient := cfg.SelfID < peer.ID
	var sess *yamux.Session
	if isClient {
		sess, err = yamux.Client(conn, ycfg)
	} else {
		sess, err = yamux.Server(conn, ycfg)
	}
	if err != nil {
		return fmt.Errorf("yamux: %w", err)
	}
	defer sess.Close()

	// 2. Bind localhost UDP+TCP listeners for every one of peer's ports.
	udpSocks := make([]*net.UDPConn, len(peer.Ports))
	tcpListeners := make([]*net.TCPListener, len(peer.Ports))
	for i, port := range peer.Ports {
		udpSocks[i], err = net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: port})
		if err != nil {
			return fmt.Errorf("udp listen 127.0.0.1:%d: %w", port, err)
		}
		defer udpSocks[i].Close()
		tcpListeners[i], err = net.ListenTCP("tcp", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: port})
		if err != nil {
			return fmt.Errorf("tcp listen 127.0.0.1:%d: %w", port, err)
		}
		defer tcpListeners[i].Close()
	}

	// 3. Establish the per-port long-lived UDP streams. Client opens
	//    them eagerly, server's accept loop populates them as headers
	//    arrive. Both sides also run an accept loop to handle ad-hoc
	//    incoming TCP streams.
	udpStreams := make([]*yamux.Stream, len(peer.Ports))
	allUDPReady := make(chan struct{})
	errCh := make(chan error, 4*len(peer.Ports))

	go func() {
		errCh <- runAcceptLoop(sess, &self, &peer, udpStreams, allUDPReady)
	}()

	if isClient {
		for i, peerPort := range peer.Ports {
			s, err := sess.OpenStream()
			if err != nil {
				return fmt.Errorf("yamux OpenStream: %w", err)
			}
			hdr := []byte{streamUDP, byte(peerPort >> 8), byte(peerPort & 0xff)}
			if _, err := s.Write(hdr); err != nil {
				return fmt.Errorf("yamux write hdr: %w", err)
			}
			udpStreams[i] = s
		}
		close(allUDPReady)
	} else {
		// Server: wait for all UDP streams to register via accept loop.
		select {
		case <-allUDPReady:
		case <-time.After(60 * time.Second):
			return fmt.Errorf("timeout waiting for UDP streams")
		}
	}

	log.Printf("[%s] link up — %d ports forwarded (udp+tcp), peer reachable via ICE",
		peer.ID, len(peer.Ports))

	// 4. Start pumps for each port.
	for i := range peer.Ports {
		i := i
		selfPort := self.Ports[i]
		go func() { errCh <- pumpUDPSockToStream(udpSocks[i], udpStreams[i]) }()
		go func() {
			udpDst := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: selfPort}
			errCh <- pumpUDPStreamToSock(udpStreams[i], udpSocks[i], udpDst)
		}()
		go func() {
			peerPort := peer.Ports[i]
			errCh <- acceptLocalTCP(tcpListeners[i], sess, peerPort)
		}()
	}
	return <-errCh
}

// runAcceptLoop handles every incoming yamux stream from the peer.
// streamUDP headers are matched to the right slot in udpStreams (one per
// port, by index in self.Ports). streamTCP triggers a Dial to the
// corresponding local TCP service.
func runAcceptLoop(sess *yamux.Session, self, peer *Peer, udpStreams []*yamux.Stream, allUDPReady chan struct{}) error {
	udpRegisteredCount := 0
	udpRegisteredOnce := make([]bool, len(self.Ports))
	for {
		s, err := sess.AcceptStream()
		if err != nil {
			return fmt.Errorf("yamux accept: %w", err)
		}
		hdr := make([]byte, 3)
		if _, err := io.ReadFull(s, hdr); err != nil {
			s.Close()
			continue
		}
		tag := hdr[0]
		port := int(hdr[1])<<8 | int(hdr[2])
		// "port" is the receiver-side port — we look it up in our own ports.
		idx := self.hasPort(port)
		if idx < 0 {
			log.Printf("[%s] stream for unknown self-port %d", peer.ID, port)
			s.Close()
			continue
		}
		switch tag {
		case streamUDP:
			udpStreams[idx] = s
			if !udpRegisteredOnce[idx] {
				udpRegisteredOnce[idx] = true
				udpRegisteredCount++
				if udpRegisteredCount == len(self.Ports) {
					close(allUDPReady)
				}
			}
		case streamTCP:
			go handleIncomingTCP(s, &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: port})
		default:
			log.Printf("[%s] unknown stream tag 0x%x", peer.ID, tag)
			s.Close()
		}
	}
}

func handleIncomingTCP(s *yamux.Stream, dst *net.TCPAddr) {
	defer s.Close()
	c, err := net.DialTCP("tcp", nil, dst)
	if err != nil {
		log.Printf("dial local %s: %v", dst, err)
		return
	}
	defer c.Close()
	spliceBoth(s, c)
}

func acceptLocalTCP(lis *net.TCPListener, sess *yamux.Session, dstPeerPort int) error {
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
			hdr := []byte{streamTCP, byte(dstPeerPort >> 8), byte(dstPeerPort & 0xff)}
			if _, err := s.Write(hdr); err != nil {
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

// peerSession is the shared state between dialICE (the current attempt
// to handshake) and pollLoop (delivering signalling messages). It is
// replaced wholesale on every reconnect so stale state from a previous
// failed attempt can't poison the next one.
type peerSession struct {
	agent  *ice.Agent
	authCh chan [2]string
}

var (
	sessionsMu sync.Mutex
	sessions   = map[string]*peerSession{} // key = remote peer id
)

// currentSession returns the active session for remoteID, or nil if
// none exists yet. Used by pollLoop to find the right authCh /
// agent for incoming messages.
func currentSession(remoteID string) *peerSession {
	sessionsMu.Lock()
	defer sessionsMu.Unlock()
	return sessions[remoteID]
}

// installSession atomically replaces any previous session for
// remoteID. Called from dialICE on each new attempt, so any stale
// auth/candidate that pollLoop wrote to the *old* channel is left
// behind unreferenced and the new attempt starts from clean state.
func installSession(remoteID string, agent *ice.Agent) *peerSession {
	sessionsMu.Lock()
	defer sessionsMu.Unlock()
	s := &peerSession{agent: agent, authCh: make(chan [2]string, 1)}
	sessions[remoteID] = s
	return s
}

func dialICE(cfg *Config, remoteID string) (*ice.Conn, error) {
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
	// Install fresh session BEFORE doing any signalling so any partner
	// auth/candidate we publish only ever resolves against this attempt.
	// pollLoop will deliver messages here from now on.
	sess := installSession(remoteID, agent)

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
			sess := currentSession(m.From)
			if sess == nil {
				// No active dialICE attempt for this remote yet; drop.
				// On reconnect both sides re-enter dialICE and publish
				// fresh auth/candidates, so dropping stale messages from
				// before our local attempt is what we want.
				continue
			}
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
					// channel already has a pending auth for this attempt
				}
			case "candidate":
				if sess.agent == nil {
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
