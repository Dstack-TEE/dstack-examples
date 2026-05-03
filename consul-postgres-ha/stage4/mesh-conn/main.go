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
// per pair, wrapped in QUIC. Each QUIC stream's first three bytes are
// (tag, port-as-uint16-big-endian) where port is the receiver's own
// identity port — the receiver looks it up in self.ports and dispatches
// to the matching local UDP socket / dials the matching local TCP
// service.
//
// Why QUIC and not yamux: yamux assumes a reliable byte-stream underlay,
// but pion/ice.Conn is UDP — and the UDP path between dstack worker
// CVMs is extremely lossy under sustained load (hairpinning the same
// public IP loses ~99% of bulk packets, coturn-relay loses ~78%).
// yamux's keepalive/recv-window invariants then trip and the user-
// visible error is "keepalive timeout" or "recv window exceeded", but
// the root cause is dropped packets. QUIC has built-in loss recovery,
// congestion control, and stream-multiplexing — it's exactly what a
// lossy UDP underlay needs. The previous yamux build died at 3KB-260KB
// depending on path; the QUIC build sustains 25-28 MB/s on the same
// hairpin.

package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/ice/v2"
	"github.com/pion/stun"
	"github.com/quic-go/quic-go"
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
	// Stage-4 sources of truth, with fallback to stage-1 envs so this
	// binary is back-compatible with the older deploy shape:
	//
	//   - SELF identity comes from /run/instance/info.json written by
	//     the bootstrap-secrets init container (which read it from the
	//     dstack SDK's Info() call). Falls back to PEER_ID env.
	//   - TURN_SHARED_SECRET comes from /run/secrets/turn (a hex blob
	//     written by bootstrap-secrets via getKey()). Falls back to
	//     the env value if the file isn't present.
	//   - PEERS_JSON still comes via env — cluster.tf computes it from
	//     the `replicas` count and re-applies on topology change,
	//     which propagates to every CVM via Phala's in-place compose
	//     update path (verified in disk-persistence shakedown).

	cfg := &Config{
		SelfID:       readSelfID(),
		SignalingURL: strings.TrimRight(mustEnv("SIGNALING_URL"), "/"),
		TurnHost:     os.Getenv("TURN_HOST"),
		TurnSecret:   readTurnSecret(),
	}
	if err := json.Unmarshal([]byte(mustEnv("PEERS_JSON")), &cfg.Peers); err != nil {
		log.Fatalf("PEERS_JSON: %v", err)
	}
	if err := validatePeers(cfg); err != nil {
		log.Fatalf("PEERS_JSON: %v", err)
	}
	return cfg
}

// readSelfID prefers /run/instance/info.json (stage-4) over PEER_ID env
// (stage-1 compat). The JSON is written by bootstrap-secrets and gives
// us a per-CVM identifier rooted in the platform.
func readSelfID() string {
	if b, err := os.ReadFile("/run/instance/info.json"); err == nil {
		var info struct {
			Role    string `json:"role"`
			Ordinal int    `json:"ordinal"`
		}
		if jerr := json.Unmarshal(b, &info); jerr == nil && info.Role != "" {
			id := fmt.Sprintf("%s-%d", info.Role, info.Ordinal)
			log.Printf("self identity from /run/instance/info.json: %s", id)
			return id
		}
		log.Printf("WARN /run/instance/info.json present but unparseable; falling back to PEER_ID env: %v", err)
	}
	return mustEnv("PEER_ID")
}

// readTurnSecret resolves the TURN shared secret in priority order:
//
//   1. TURN_SHARED_SECRET env (set when using an external coturn whose
//      static-auth-secret was configured out-of-band — e.g. the Vultr
//      coordinator path). When this is present it MUST win, because
//      the local TEE-derived value won't match what coturn is checking
//      against.
//   2. /run/secrets/turn (stage-4 TEE-derived path; matches the
//      embedded coordinator's coturn which reads the same file).
//
// Order matters: env beats file so that "use external coturn" can be
// configured purely at the cluster.tf layer.
func readTurnSecret() string {
	if v := os.Getenv("TURN_SHARED_SECRET"); v != "" {
		log.Printf("turn shared secret loaded from TURN_SHARED_SECRET env (%d bytes)", len(v))
		return v
	}
	if b, err := os.ReadFile("/run/secrets/turn"); err == nil {
		s := strings.TrimSpace(string(b))
		if s != "" {
			log.Printf("turn shared secret loaded from /run/secrets/turn (%d bytes)", len(s))
			return s
		}
	}
	return ""
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

// quicConfig is shared by client and server. We give QUIC large windows
// so a pg_basebackup stream (sustained 100s of MB) doesn't stall on
// flow-control updates: a single InitialConnectionReceiveWindow of 8 MiB
// lets the sender push a chunk that big before needing an ACK from us.
// MaxIdleTimeout is what we use to detect a dead link — if no packet
// arrives in this long, the conn errors out.
func quicConfig() *quic.Config {
	return &quic.Config{
		KeepAlivePeriod:                10 * time.Second,
		MaxIdleTimeout:                 60 * time.Second,
		InitialStreamReceiveWindow:     4 << 20,
		MaxStreamReceiveWindow:         16 << 20,
		InitialConnectionReceiveWindow: 8 << 20,
		MaxConnectionReceiveWindow:     32 << 20,
	}
}

func dialAndPump(cfg *Config, self, peer Peer) error {
	if len(self.Ports) != len(peer.Ports) {
		return fmt.Errorf("port-count mismatch: self has %d ports, peer has %d", len(self.Ports), len(peer.Ports))
	}

	// 1. Establish ICE + wrap with a counting conn for byte-level telemetry.
	rawConn, err := dialICE(cfg, peer.ID)
	if err != nil {
		return fmt.Errorf("ice: %w", err)
	}
	defer rawConn.Close()
	counted := newCountingConn(rawConn, peer.ID)
	pkt := &iceConnPacketConn{conn: counted}

	// 2. Establish a QUIC connection on top of the ICE PacketConn.
	//    We replaced yamux here because pion/ice.Conn's UDP underlay drops
	//    packets under sustained load (NAT hairpinning loss between dstack
	//    workers is ~99%; even relay-via-coturn loses ~78%). yamux assumes
	//    a reliable byte-stream and dies as "keepalive timeout" or "recv
	//    window exceeded" — protocol violations triggered by lost packets.
	//    QUIC has built-in loss recovery + congestion control, so a lossy
	//    UDP underlay is exactly what it expects. Stream multiplex API is
	//    a near-drop-in for yamux: OpenStreamSync / AcceptStream.
	isClient := cfg.SelfID < peer.ID
	connCtx, connCancel := context.WithCancel(context.Background())
	defer connCancel()
	dialCtx, dialCancel := context.WithTimeout(connCtx, 30*time.Second)
	defer dialCancel()

	var qconn *quic.Conn
	if isClient {
		// remote net.Addr is ignored by our PacketConn shim (it only
		// knows about the one ICE peer); we still pass something non-nil
		// because quic.Dial uses it for SNI fallback / connection ID.
		qconn, err = quic.Dial(dialCtx, pkt, counted.RemoteAddr(), clientTLS(), quicConfig())
		if err != nil {
			return fmt.Errorf("quic dial: %w", err)
		}
	} else {
		ln, lerr := quic.Listen(pkt, serverTLS(), quicConfig())
		if lerr != nil {
			return fmt.Errorf("quic listen: %w", lerr)
		}
		// Close the listener once we have our one accepted conn — we
		// only want a single QUIC connection per ICE pair.
		acceptCtx, acceptCancel := context.WithTimeout(connCtx, 30*time.Second)
		qconn, err = ln.Accept(acceptCtx)
		acceptCancel()
		ln.Close()
		if err != nil {
			return fmt.Errorf("quic accept: %w", err)
		}
	}
	defer qconn.CloseWithError(0, "")

	// Periodic per-link telemetry. The counting conn tracks bytes through
	// the underlying ice.Conn (i.e. wire bytes including QUIC overhead).
	// QUIC's StreamCount isn't directly exposed, so we report just bytes.
	stopStats := make(chan struct{})
	go reportLinkStats(peer.ID, counted, qconn, stopStats)
	defer close(stopStats)

	// 3. Bind localhost UDP+TCP listeners for every one of peer's ports.
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

	// 4. Establish the per-port long-lived UDP streams. Client opens
	//    them eagerly, server's accept loop populates them as headers
	//    arrive. Both sides also run an accept loop to handle ad-hoc
	//    incoming TCP streams.
	udpStreams := make([]*quic.Stream, len(peer.Ports))
	allUDPReady := make(chan struct{})
	errCh := make(chan error, 4*len(peer.Ports))

	go func() {
		errCh <- runAcceptLoop(connCtx, qconn, &self, &peer, udpStreams, allUDPReady)
	}()

	if isClient {
		for i, peerPort := range peer.Ports {
			s, err := qconn.OpenStreamSync(connCtx)
			if err != nil {
				return fmt.Errorf("quic OpenStreamSync: %w", err)
			}
			hdr := []byte{streamUDP, byte(peerPort >> 8), byte(peerPort & 0xff)}
			if _, err := s.Write(hdr); err != nil {
				return fmt.Errorf("quic write hdr: %w", err)
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

	// 5. Start pumps for each port.
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
			errCh <- acceptLocalTCP(connCtx, tcpListeners[i], qconn, peerPort)
		}()
	}
	return <-errCh
}

// runAcceptLoop handles every incoming QUIC stream from the peer.
// streamUDP headers are matched to the right slot in udpStreams (one per
// port, by index in self.Ports). streamTCP triggers a Dial to the
// corresponding local TCP service.
func runAcceptLoop(ctx context.Context, qconn *quic.Conn, self, peer *Peer, udpStreams []*quic.Stream, allUDPReady chan struct{}) error {
	udpRegisteredCount := 0
	udpRegisteredOnce := make([]bool, len(self.Ports))
	for {
		s, err := qconn.AcceptStream(ctx)
		if err != nil {
			return fmt.Errorf("quic accept: %w", err)
		}
		hdr := make([]byte, 3)
		if _, err := io.ReadFull(s, hdr); err != nil {
			s.CancelRead(0)
			s.Close()
			continue
		}
		tag := hdr[0]
		port := int(hdr[1])<<8 | int(hdr[2])
		// "port" is the receiver-side port — we look it up in our own ports.
		idx := self.hasPort(port)
		if idx < 0 {
			log.Printf("[%s] stream for unknown self-port %d", peer.ID, port)
			s.CancelRead(0)
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
			s.CancelRead(0)
			s.Close()
		}
	}
}

func handleIncomingTCP(s *quic.Stream, dst *net.TCPAddr) {
	defer s.Close()
	c, err := net.DialTCP("tcp", nil, dst)
	if err != nil {
		log.Printf("dial local %s: %v", dst, err)
		return
	}
	defer c.Close()
	spliceBoth(s, c)
}

func acceptLocalTCP(ctx context.Context, lis *net.TCPListener, qconn *quic.Conn, dstPeerPort int) error {
	for {
		c, err := lis.AcceptTCP()
		if err != nil {
			return fmt.Errorf("tcp accept: %w", err)
		}
		go func(c *net.TCPConn) {
			defer c.Close()
			s, err := qconn.OpenStreamSync(ctx)
			if err != nil {
				log.Printf("quic open: %v", err)
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

func pumpUDPSockToStream(sock *net.UDPConn, s *quic.Stream) error {
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

func pumpUDPStreamToSock(s *quic.Stream, sock *net.UDPConn, dst *net.UDPAddr) error {
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
// Per-link instrumentation: count bytes through the ICE conn (i.e. the
// raw wire bytes including QUIC framing/encryption overhead) and log
// every 10s. Useful for diagnosing whether a link drop happens after
// 0 bytes, 1KB, or 100MB.
// =============================================================================

type countingConn struct {
	net.Conn
	peerID   string
	bytesIn  atomic.Uint64
	bytesOut atomic.Uint64
	reads    atomic.Uint64
	writes   atomic.Uint64
}

func newCountingConn(c net.Conn, peerID string) *countingConn {
	return &countingConn{Conn: c, peerID: peerID}
}

func (c *countingConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	c.bytesIn.Add(uint64(n))
	c.reads.Add(1)
	if err != nil {
		log.Printf("[%s] conn.Read err after %d bytes total / %d reads: %v",
			c.peerID, c.bytesIn.Load(), c.reads.Load(), err)
	}
	return n, err
}

func (c *countingConn) Write(p []byte) (int, error) {
	n, err := c.Conn.Write(p)
	c.bytesOut.Add(uint64(n))
	c.writes.Add(1)
	if err != nil {
		log.Printf("[%s] conn.Write err after %d bytes total / %d writes: %v",
			c.peerID, c.bytesOut.Load(), c.writes.Load(), err)
	}
	return n, err
}

// iceConnPacketConn adapts a pion/ice.Conn (packet-oriented net.Conn) to
// a net.PacketConn so quic-go can run on it. Every Read on ice.Conn
// returns one datagram; every Write sends one. The single-peer case
// means we can ignore the addr arg from quic and unconditionally route
// to the ICE peer that's already locked in.
type iceConnPacketConn struct {
	conn *countingConn
}

func (p *iceConnPacketConn) ReadFrom(b []byte) (int, net.Addr, error) {
	n, err := p.conn.Read(b)
	return n, p.conn.RemoteAddr(), err
}

func (p *iceConnPacketConn) WriteTo(b []byte, _ net.Addr) (int, error) {
	return p.conn.Write(b)
}

func (p *iceConnPacketConn) Close() error                       { return p.conn.Close() }
func (p *iceConnPacketConn) LocalAddr() net.Addr                { return p.conn.LocalAddr() }
func (p *iceConnPacketConn) SetDeadline(_ time.Time) error      { return nil }
func (p *iceConnPacketConn) SetReadDeadline(_ time.Time) error  { return nil }
func (p *iceConnPacketConn) SetWriteDeadline(_ time.Time) error { return nil }

func reportLinkStats(peerID string, conn *countingConn, qconn *quic.Conn, stop <-chan struct{}) {
	t := time.NewTicker(10 * time.Second)
	defer t.Stop()
	var lastIn, lastOut uint64
	for {
		select {
		case <-stop:
			log.Printf("[%s] final stats: in=%d out=%d reads=%d writes=%d",
				peerID, conn.bytesIn.Load(), conn.bytesOut.Load(),
				conn.reads.Load(), conn.writes.Load())
			return
		case <-t.C:
			in, out := conn.bytesIn.Load(), conn.bytesOut.Load()
			log.Printf("[%s] link: in=%d (+%d B/10s) out=%d (+%d B/10s) reads=%d writes=%d",
				peerID, in, in-lastIn, out, out-lastOut,
				conn.reads.Load(), conn.writes.Load())
			lastIn, lastOut = in, out
		}
	}
}

// =============================================================================
// TLS — QUIC requires a TLS handshake. We don't rely on its identity
// guarantees (mesh peers are already authenticated by the dstack TEE
// layer + the TURN HMAC secret); a self-signed cert with no verification
// is fine here. We accept any peer cert because trust is established
// out-of-band before ICE even starts.
// =============================================================================

const quicALPN = "dstack-mesh-conn"

func clientTLS() *tls.Config {
	return &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{quicALPN},
	}
}

func serverTLS() *tls.Config {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		log.Fatalf("ecdsa keygen: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "mesh-conn"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		log.Fatalf("self-signed cert: %v", err)
	}
	return &tls.Config{
		Certificates: []tls.Certificate{{
			Certificate: [][]byte{der},
			PrivateKey:  priv,
		}},
		NextProtos: []string{quicALPN},
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

	// MESH_CONN_RELAY_ONLY=1 restricts candidate gathering to Relay only.
	// Use when direct (host/srflx/prflx) connectivity is unreliable — e.g.
	// dstack worker-to-worker pairs where pion's connectivity check fails
	// for every direct pair and the agent never gets to relay before
	// timing out. Trades latency for guaranteed reachability via coturn.
	candidateTypes := []ice.CandidateType{
		ice.CandidateTypeHost,
		ice.CandidateTypeServerReflexive,
		ice.CandidateTypePeerReflexive,
		ice.CandidateTypeRelay,
	}
	if os.Getenv("MESH_CONN_RELAY_ONLY") == "1" {
		candidateTypes = []ice.CandidateType{ice.CandidateTypeRelay}
	}
	// MESH_CONN_TCP_ONLY=1 restricts ICE to TCP NetworkTypes AND drops
	// UDP-transport TURN URLs (pion's NetworkTypes only filters HOST
	// candidates; Relay candidates inherit transport from their TURN
	// URL's Proto, regardless of NetworkTypes). Without dropping UDP
	// URLs, pion still picks `relay ... (proto=udp)` and we get the
	// same UDP-loss behavior that kills yamux keepalives.
	netTypes := []ice.NetworkType{ice.NetworkTypeUDP4, ice.NetworkTypeTCP4}
	if os.Getenv("MESH_CONN_TCP_ONLY") == "1" {
		netTypes = []ice.NetworkType{ice.NetworkTypeTCP4}
		var tcpURLs []*stun.URI
		for _, u := range urls {
			if u.Proto == stun.ProtoTypeTCP {
				tcpURLs = append(tcpURLs, u)
			}
		}
		urls = tcpURLs
		log.Printf("[%s] TCP-only mode: %d URLs after UDP filter", remoteID, len(urls))
	}
	agent, err := ice.NewAgent(&ice.AgentConfig{
		Urls:           urls,
		NetworkTypes:   netTypes,
		CandidateTypes: candidateTypes,
	})
	if err != nil {
		return nil, fmt.Errorf("NewAgent: %w", err)
	}
	// Install fresh session BEFORE doing any signalling so any partner
	// auth/candidate we publish only ever resolves against this attempt.
	// pollLoop will deliver messages here from now on.
	sess := installSession(remoteID, agent)

	// dialCtx is cancelled either by ICE state Failed/Closed (terminal
	// pion/ice states; agent.Dial/Accept won't recover from them on its
	// own and would otherwise block forever) or by the 60s deadline below.
	// runPeerLink retries the whole dialAndPump after we return — without
	// the cancel, a single ICE failure wedges this peer slot indefinitely.
	dialCtx, cancelDial := context.WithCancel(context.Background())
	defer cancelDial()

	closeAgent := func() {
		// pion's Close is idempotent; safe in defers and callbacks both.
		_ = agent.Close()
	}

	if err := agent.OnCandidate(func(c ice.Candidate) {
		if c == nil {
			return
		}
		publish(cfg, remoteID, "candidate", c.Marshal())
	}); err != nil {
		closeAgent()
		return nil, err
	}
	if err := agent.OnConnectionStateChange(func(s ice.ConnectionState) {
		log.Printf("[%s] ice state: %s", remoteID, s)
		if s == ice.ConnectionStateFailed || s == ice.ConnectionStateClosed {
			cancelDial()
		}
	}); err != nil {
		closeAgent()
		return nil, err
	}

	localUfrag, localPwd, err := agent.GetLocalUserCredentials()
	if err != nil {
		closeAgent()
		return nil, err
	}
	publish(cfg, remoteID, "auth", localUfrag+":"+localPwd)

	if err := agent.GatherCandidates(); err != nil {
		closeAgent()
		return nil, err
	}

	var remote [2]string
	select {
	case remote = <-sess.authCh:
	case <-time.After(60 * time.Second):
		closeAgent()
		return nil, fmt.Errorf("timeout waiting for remote auth from %s", remoteID)
	}

	// 60s is comfortably longer than pion's default 30s connectivity-check
	// window. If Dial/Accept hasn't succeeded by then, ICE has already
	// transitioned to Failed and the state callback above cancelled the ctx.
	dialTimer := time.AfterFunc(60*time.Second, cancelDial)
	defer dialTimer.Stop()

	var conn *ice.Conn
	if cfg.SelfID < remoteID {
		conn, err = agent.Dial(dialCtx, remote[0], remote[1])
	} else {
		conn, err = agent.Accept(dialCtx, remote[0], remote[1])
	}
	if err != nil {
		closeAgent()
		return nil, err
	}

	if pair, perr := agent.GetSelectedCandidatePair(); perr == nil && pair != nil {
		// Log full addresses + types so we can correlate stuck links against
		// specific NAT mappings / TURN allocations on coturn.
		log.Printf("[%s] selected pair: %s %s:%d <-> %s %s:%d (proto=%s)",
			remoteID,
			pair.Local.Type(), pair.Local.Address(), pair.Local.Port(),
			pair.Remote.Type(), pair.Remote.Address(), pair.Remote.Port(),
			pair.Local.NetworkType().NetworkShort())
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
				// Always keep the LATEST auth. select-default would drop
				// the new one — and if the buffered one was stale (from
				// before the peer's last bounce), dialICE would consume
				// that stale auth, Dial against the wrong ufrag, ICE
				// would Fail, and we'd repeat forever. Drain-then-push
				// ensures the channel always holds the most-recent auth.
				select {
				case <-sess.authCh:
				default:
				}
				sess.authCh <- [2]string{parts[0], parts[1]}
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
