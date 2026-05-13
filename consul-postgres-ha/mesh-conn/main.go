// mesh-conn — userspace port-forwarding agent over pion/ice + QUIC.
//
// Addressing model: peer VIPs + platform-supplied port allowlist.
//
//   Every peer is identified by a /8 loopback IP `127.50.0.<vip>`. The
//   `vip` is a small integer (typically the peer's ordinal in the
//   cluster) declared in PEERS_JSON, byte-identical across the cluster.
//
//   On every peer's host:
//   - the entrypoint provisions `127.50.0.<vip>/32 dev lo` for ALL
//     peers, including self — so dialing self's VIP loops back through
//     the kernel without crossing mesh-conn.
//   - mesh-conn binds the allowlist on every OTHER peer's VIP — and
//     forwards each accepted connection to the right remote peer over
//     QUIC.
//
// Allowlist source: MESH_CONN_ALLOWLIST env, JSON shape `[{port, udp}, …]`.
// Populated by the platform sidecar entrypoint at startup from
// SERVICES_JSON (per-service Connect-sidecar ports) plus the two
// static Consul-infra ports {8300, 8301}. The substance — which ports
// cross peer boundaries — is platform state declared one level up in
// `cluster.tf`'s `local.services`; mesh-conn just reads what the
// platform tells it.
//
// Today's defaults (3-service example: webdemo + postgres-master/-replica):
//
//   21000  Envoy Connect public mTLS — webdemo sidecar         (TCP)
//   21001  Envoy Connect public mTLS — postgres sidecar        (TCP)
//   8300   Consul server RPC                                   (TCP)
//   8301   Consul serf-LAN gossip                              (UDP + TCP)
//
// Sidecar ports come in one-per-backend because stock Consul Connect
// requires one sidecar Envoy process per Connect-mesh-accessible
// service. Services sharing a canonical port (postgres-master and
// postgres-replica both on :5432, same Patroni backend) collapse onto
// one sidecar; distinct canonical ports get distinct sidecars and
// distinct allowlist entries.
//
// The allowlist is intentionally minimal: only platform infrastructure
// that needs unmediated peer-to-peer reachability. App-level traffic
// (including Patroni's Postgres replication) goes through the Connect
// mesh — mesh-conn knows peers, never services.
//
// Wire format on each QUIC stream is unchanged from the old shape:
// the first 3 bytes are (tag, port-big-endian-uint16), where port is
// the receiver's local port to dial / write into. The receiver
// validates port against the allowlist and rejects anything else.
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
	"github.com/pion/logging"
	"github.com/pion/stun"
	"github.com/quic-go/quic-go"
)

// =============================================================================
// config
// =============================================================================

type Peer struct {
	ID  string `json:"id"`
	Vip int    `json:"vip"` // last octet in 127.50.0.0/24 — identifies this peer cluster-wide
}

// vipAddr returns 127.50.0.<vip> as a net.IP for binding listeners.
func (p *Peer) vipAddr() net.IP {
	return net.IPv4(127, 50, 0, byte(p.Vip))
}

// InfraPort is one entry in the peer-VIP port allowlist. mesh-conn
// binds (peer.vipAddr(), Port) on every OTHER peer for each entry.
// JSON-tagged because the value comes in over MESH_CONN_ALLOWLIST env.
type InfraPort struct {
	Port int  `json:"port"`
	UDP  bool `json:"udp"` // some ports carry UDP (e.g. serf gossip); most are TCP-only
}

type Config struct {
	SelfID       string
	Peers        []Peer
	Allowlist    []InfraPort
	SignalingURL string
	TurnHost     string
	TurnSecret   string
}

// allowedPort reports whether the given port is in the allowlist.
// Used by the receiver to reject streams targeting unknown ports.
func (c *Config) allowedPort(port int) bool {
	for _, ip := range c.Allowlist {
		if ip.Port == port {
			return true
		}
	}
	return false
}

func loadConfig() *Config {
	// Primary sources of truth (with env fallback so this binary
	// stays runnable in a bare-metal smoke test outside the dstack
	// runtime):
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
	//     update path.

	cfg := &Config{
		SelfID:       readSelfID(),
		SignalingURL: strings.TrimRight(mustEnv("SIGNALING_URL"), "/"),
		TurnHost:     os.Getenv("TURN_HOST"),
		TurnSecret:   readTurnSecret(),
	}
	if err := json.Unmarshal([]byte(mustEnv("PEERS_JSON")), &cfg.Peers); err != nil {
		log.Fatalf("PEERS_JSON: %v", err)
	}
	// MESH_CONN_ALLOWLIST: JSON list `[{port, udp}, …]` generated by
	// the platform sidecar entrypoint from SERVICES_JSON (per-service
	// Connect-sidecar ports) plus the static Consul-infra ports
	// (8300 RPC + 8301 gossip). This is platform plumbing; developers
	// edit `local.services` in cluster.tf, not this env.
	if err := json.Unmarshal([]byte(mustEnv("MESH_CONN_ALLOWLIST")), &cfg.Allowlist); err != nil {
		log.Fatalf("MESH_CONN_ALLOWLIST: %v", err)
	}
	if err := validateConfig(cfg); err != nil {
		log.Fatalf("config: %v", err)
	}
	return cfg
}

// readSelfID prefers /run/instance/info.json over PEER_ID env (the
// env path is kept so this binary stays runnable in a bare-metal
// smoke test). The JSON is written by bootstrap-secrets and gives
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
//   2. /run/secrets/turn (TEE-derived path; matches the embedded
//      coordinator's coturn which reads the same file).
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

// validateConfig fails fast on any silent mis-configuration that
// would otherwise manifest as confusing runtime failures: collided
// peer VIPs, missing self, malformed allowlist, etc. Bound at startup
// because PEERS_JSON and MESH_CONN_ALLOWLIST are shared cluster-wide
// state and must round-trip identically across peers.
func validateConfig(cfg *Config) error {
	if err := validatePeers(cfg); err != nil {
		return err
	}
	if err := validateAllowlist(cfg); err != nil {
		return err
	}
	// Log a digest of the validated config so operators can check that
	// every peer in the cluster sees the same PEERS_JSON. Differences
	// across peers would indicate a deploy-script discrepancy.
	digest := peersDigest(cfg.Peers)
	log.Printf("config validated: %d peers, allowlist=%d ports/peer (%v), digest=%s",
		len(cfg.Peers), len(cfg.Allowlist), allowlistPorts(cfg.Allowlist), digest)
	return nil
}

func validatePeers(cfg *Config) error {
	if len(cfg.Peers) < 2 {
		return fmt.Errorf("need at least 2 peers in PEERS_JSON, got %d", len(cfg.Peers))
	}

	seenIDs := map[string]bool{}
	allVips := map[int]string{} // vip -> peer.ID owning it (for collision detection)
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

		// VIP is the last octet of 127.50.0.0/24; must be 1..254
		// (avoid network 0 and broadcast 255 by convention) and unique
		// cluster-wide.
		if p.Vip < 1 || p.Vip > 254 {
			return fmt.Errorf("peer %q vip=%d out of range (1..254)", p.ID, p.Vip)
		}
		if owner, ok := allVips[p.Vip]; ok {
			return fmt.Errorf("vip %d is claimed by both peer %q and peer %q — every peer VIP must be globally unique",
				p.Vip, owner, p.ID)
		}
		allVips[p.Vip] = p.ID
	}

	if !selfFound {
		return fmt.Errorf("PEER_ID %q not in PEERS_JSON (peers: %v)", cfg.SelfID, knownIDs(cfg.Peers))
	}
	return nil
}

// validateAllowlist fails fast on MESH_CONN_ALLOWLIST malformations:
// empty list (mesh-conn with nothing to forward is always a config
// bug), out-of-range ports, or duplicate port entries (would race for
// the same listener bind at runtime).
func validateAllowlist(cfg *Config) error {
	if len(cfg.Allowlist) == 0 {
		return fmt.Errorf("MESH_CONN_ALLOWLIST is empty — platform sidecar should always emit at least the Consul-infra ports")
	}
	seen := map[int]bool{}
	for i, ip := range cfg.Allowlist {
		if ip.Port < 1 || ip.Port > 65535 {
			return fmt.Errorf("allowlist[%d] port=%d out of range (1..65535)", i, ip.Port)
		}
		if seen[ip.Port] {
			return fmt.Errorf("allowlist port %d appears twice — each port may only be entered once", ip.Port)
		}
		seen[ip.Port] = true
	}
	return nil
}

func knownIDs(peers []Peer) []string {
	ids := make([]string, 0, len(peers))
	for _, p := range peers {
		ids = append(ids, p.ID)
	}
	return ids
}

// allowlistPorts returns the bare port numbers for log output.
func allowlistPorts(allowlist []InfraPort) []int {
	out := make([]int, len(allowlist))
	for i, ip := range allowlist {
		out[i] = ip.Port
	}
	return out
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
				fmt.Fprintf(&buf, "vip=%d", p.Vip)
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
	m := newMesh(cfg)
	m.Run(context.Background())
}

// Mesh is one runtime instance — one mesh-conn process. Owns the
// per-peer session registry, signalling URL, and shutdown plumbing.
// Methods that previously closed over the package-level `sessions`
// map now receive *Mesh; main() builds one and calls Run().
//
// Reason for instance-scoping: the in-process loopback test boots two
// Mesh values side by side; a package-global session map collides
// across instances.
type Mesh struct {
	cfg  *Config
	self *Peer

	sessionsMu sync.Mutex
	sessions   map[string]*peerSession

	// onLinkUp is an optional test hook fired right after each
	// per-peer "link up" log line. nil in production.
	onLinkUp func(peerID string)
}

func newMesh(cfg *Config) *Mesh {
	return &Mesh{
		cfg:      cfg,
		self:     cfg.peerByID(cfg.SelfID),
		sessions: map[string]*peerSession{},
	}
}

func (m *Mesh) Run(ctx context.Context) {
	others := make([]Peer, 0, len(m.cfg.Peers)-1)
	for _, p := range m.cfg.Peers {
		if p.ID != m.cfg.SelfID {
			others = append(others, p)
		}
	}
	log.Printf("mesh-conn: self=%s vip=%d allowlist=%v other=%d",
		m.cfg.SelfID, m.self.Vip, allowlistPorts(m.cfg.Allowlist), len(others))

	go m.pollLoop(ctx)

	var wg sync.WaitGroup
	for _, p := range others {
		wg.Add(1)
		go func(p Peer) {
			defer wg.Done()
			m.runPeerLink(ctx, p)
		}(p)
	}
	wg.Wait()
	log.Printf("all peer links exited")
}

// =============================================================================
// per-peer link: ICE conn + bound UDP socket on peer's identity port
// =============================================================================

func (m *Mesh) runPeerLink(ctx context.Context, peer Peer) {
	// One peerSession per peer for the lifetime of mesh-conn. The
	// session holds authCh + candidateBuffer + abortAttempt — the
	// stable wiring pollLoop dispatches through. The ICE agent itself
	// is rebuilt per attempt inside dialICE (pion's Restart() doesn't
	// support re-Dial; see peerSession docstring).
	sess := m.setupPeerSession(peer.ID)
	for {
		if ctx.Err() != nil {
			return
		}
		if err := m.dialAndPump(ctx, peer, sess); err != nil {
			log.Printf("[%s] link failed: %v — retrying in 5s", peer.ID, err)
			if !sleepCtx(ctx, 5*time.Second) {
				return
			}
			continue
		}
		// dialAndPump returns nil only when the conn closed cleanly.
		log.Printf("[%s] link closed — reconnecting", peer.ID)
	}
}

// sleepCtx sleeps for d or until ctx is cancelled. Returns true if
// the full sleep completed (so the caller should continue), false if
// the caller should bail.
func sleepCtx(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return true
	case <-ctx.Done():
		return false
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

func (m *Mesh) dialAndPump(parentCtx context.Context, peer Peer, sess *peerSession) error {
	cfg := m.cfg
	self := *m.self
	// One attemptCtx for the entire attempt — covers dialICE, QUIC dial,
	// and the long-running pump goroutines. pollLoop and the ICE state
	// callback both wire abortAttempt to this ctx; cancelling it makes
	// the whole pile collapse so runPeerLink's 5s retry can re-enter.
	// parentCtx (from Mesh.Run) is the outer shutdown signal; cancelling
	// it also collapses the attempt.
	attemptCtx, abort := context.WithCancel(parentCtx)
	sess.mu.Lock()
	sess.consumedAuth = [2]string{}
	sess.abortAttempt = abort
	sess.mu.Unlock()
	defer func() {
		abort()
		sess.mu.Lock()
		// Only clear if it's still ours. runPeerLink's loop is serial
		// per peer so this is always the case, but defensive.
		if sess.abortAttempt != nil {
			sess.abortAttempt = nil
		}
		sess.mu.Unlock()
	}()

	// 1. Establish ICE + wrap with a counting conn for byte-level telemetry.
	rawConn, err := m.dialICE(peer.ID, sess, attemptCtx)
	if err != nil {
		return fmt.Errorf("ice: %w", err)
	}
	// ice.Conn.Close() also closes the underlying agent (pion ties
	// their lifetimes — transport.go:112). That's exactly what we want
	// at end-of-attempt: this iteration's agent goes away, and the
	// next iteration installs a fresh one.
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
	connCtx := attemptCtx
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
	go reportLinkStats(peer.ID, counted, stopStats)
	defer close(stopStats)

	// 3. Bind allowlist listeners on the peer's VIP. UDP only for ports
	//    flagged UDP=true (currently only 8301); TCP for every entry.
	//    Aliases like 127.50.0.<peer.Vip>/32 are provisioned by
	//    mesh-sidecar/entrypoint.sh before mesh-conn starts; failing
	//    here means the alias didn't get set up.
	peerVip := peer.vipAddr()
	udpSocks := map[int]*net.UDPConn{}     // port -> listener (only UDP-bearing ports)
	tcpListeners := make([]*net.TCPListener, 0, len(cfg.Allowlist))
	for _, ip := range cfg.Allowlist {
		tl, err := net.ListenTCP("tcp", &net.TCPAddr{IP: peerVip, Port: ip.Port})
		if err != nil {
			return fmt.Errorf("tcp listen %s:%d: %w", peerVip, ip.Port, err)
		}
		defer tl.Close()
		tcpListeners = append(tcpListeners, tl)
		if ip.UDP {
			us, err := net.ListenUDP("udp", &net.UDPAddr{IP: peerVip, Port: ip.Port})
			if err != nil {
				return fmt.Errorf("udp listen %s:%d: %w", peerVip, ip.Port, err)
			}
			defer us.Close()
			udpSocks[ip.Port] = us
		}
	}

	// 4. Establish the per-UDP-port long-lived streams. Client opens
	//    them eagerly tagged with the allowlist port; server's accept
	//    loop matches them by header. Both sides also run an accept
	//    loop to handle ad-hoc incoming TCP streams.
	udpStreams := map[int]*quic.Stream{}
	allUDPReady := make(chan struct{})
	errCh := make(chan error, 4*len(cfg.Allowlist))

	udpPortCount := len(udpSocks)
	go func() {
		errCh <- runAcceptLoop(connCtx, qconn, cfg, &self, udpStreams, udpPortCount, allUDPReady)
	}()

	if isClient {
		for _, ip := range cfg.Allowlist {
			if !ip.UDP {
				continue
			}
			s, err := qconn.OpenStreamSync(connCtx)
			if err != nil {
				return fmt.Errorf("quic OpenStreamSync: %w", err)
			}
			hdr := []byte{streamUDP, byte(ip.Port >> 8), byte(ip.Port & 0xff)}
			if _, err := s.Write(hdr); err != nil {
				return fmt.Errorf("quic write hdr: %w", err)
			}
			udpStreams[ip.Port] = s
		}
		close(allUDPReady)
	} else if udpPortCount > 0 {
		select {
		case <-allUDPReady:
		case <-time.After(60 * time.Second):
			return fmt.Errorf("timeout waiting for UDP streams")
		}
	} else {
		close(allUDPReady)
	}

	log.Printf("[%s] link up — peer vip=127.50.0.%d, allowlist=%v (udp=%d, tcp=%d)",
		peer.ID, peer.Vip, allowlistPorts(cfg.Allowlist), udpPortCount, len(tcpListeners))
	if m.onLinkUp != nil {
		m.onLinkUp(peer.ID)
	}

	// 5. Start pumps. UDP: one bidirectional pump pair per UDP port.
	//    TCP: one accept-loop per port (each accepted conn opens an
	//    ephemeral streamTCP).
	for _, ip := range cfg.Allowlist {
		port := ip.Port
		if ip.UDP {
			us := udpSocks[port]
			st := udpStreams[port]
			go func() { errCh <- pumpUDPSockToStream(us, st) }()
			go func() {
				// Dispatch to the SELF VIP, not 127.0.0.1, so the
				// inbound packet lands on whatever (Consul, Envoy, ...)
				// is listening on this peer's own loopback alias. This
				// also keeps the source-port-preservation invariant
				// intact: the local listener's bound addr is the
				// remote peer's VIP, so the receiving service sees
				// "from peer-N" as the source.
				udpDst := &net.UDPAddr{IP: self.vipAddr(), Port: port}
				errCh <- pumpUDPStreamToSock(st, us, udpDst)
			}()
		}
	}
	for i, ip := range cfg.Allowlist {
		tl := tcpListeners[i]
		port := ip.Port
		go func() { errCh <- acceptLocalTCP(connCtx, tl, qconn, port) }()
	}
	return <-errCh
}

// runAcceptLoop handles every incoming QUIC stream from the peer.
// streamUDP headers are matched into udpStreams keyed by port; streamTCP
// triggers a Dial to <self-vip>:<port> (so it lands on whatever the
// local Consul / Envoy bound on the peer's own loopback alias). The
// receiver validates port against the static allowlist; anything
// else is rejected — that's the only port-knowledge the receiver needs.
func runAcceptLoop(ctx context.Context, qconn *quic.Conn, cfg *Config, self *Peer, udpStreams map[int]*quic.Stream, expectedUDP int, allUDPReady chan struct{}) error {
	udpRegistered := 0
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
		if !cfg.allowedPort(port) {
			log.Printf("stream for non-allowlist port %d (tag=0x%x)", port, tag)
			s.CancelRead(0)
			s.Close()
			continue
		}
		switch tag {
		case streamUDP:
			if _, dup := udpStreams[port]; dup {
				log.Printf("duplicate streamUDP for port %d", port)
				s.CancelRead(0)
				s.Close()
				continue
			}
			udpStreams[port] = s
			udpRegistered++
			if udpRegistered == expectedUDP {
				close(allUDPReady)
			}
		case streamTCP:
			go handleIncomingTCP(s, &net.TCPAddr{IP: self.vipAddr(), Port: port})
		default:
			log.Printf("unknown stream tag 0x%x", tag)
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
// a periodic summary. Useful for diagnosing whether a link drop happens
// after 0 bytes, 1KB, or 100MB.
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

func (p *iceConnPacketConn) Close() error        { return p.conn.Close() }
func (p *iceConnPacketConn) LocalAddr() net.Addr { return p.conn.LocalAddr() }

// Deadline methods delegate to ice.Conn (via the embedded net.Conn on
// countingConn) instead of being a no-op. quic-go relies on
// SetReadDeadline to interrupt a blocked ReadFrom when its context
// cancels — without this delegation, a quic.Dial whose context times
// out (e.g. because ICE went Failed mid-handshake) would hang forever
// in our shim, and the surrounding runPeerLink retry loop never gets
// to retry. Pion's ice.Conn implements the deadline methods, so this
// is the natural place to wire them through.
func (p *iceConnPacketConn) SetDeadline(t time.Time) error      { return p.conn.SetDeadline(t) }
func (p *iceConnPacketConn) SetReadDeadline(t time.Time) error  { return p.conn.SetReadDeadline(t) }
func (p *iceConnPacketConn) SetWriteDeadline(t time.Time) error { return p.conn.SetWriteDeadline(t) }

// reportLinkStats logs a periodic summary per peer link. Once a minute,
// and only when bytes actually moved since the last tick, so an idle
// mesh stays quiet. Always logs the final summary on stop, regardless
// of activity, since that's what postmortems read.
func reportLinkStats(peerID string, conn *countingConn, stop <-chan struct{}) {
	t := time.NewTicker(60 * time.Second)
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
			if in == lastIn && out == lastOut {
				continue
			}
			log.Printf("[%s] link: in=%d (+%d B/min) out=%d (+%d B/min) reads=%d writes=%d",
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
// ICE — long-lived per-peer session, agent rebuilt per attempt
// =============================================================================

// peerSession holds the per-peer state shared between dialAndPump (the
// current attempt) and pollLoop (delivering signalling messages from the
// broker). The session is created ONCE per peer at startup; the agent
// inside it is replaced on every attempt.
//
// Why not persistent agent + Restart()? It looked clean on paper, but
// pion's Restart() doesn't reset agent.startedCh — once you've Dial'd
// or Accept'd once, a second Dial returns ErrMultipleStart. Restart is
// only intended for the WebRTC pattern where you keep the same ice.Conn
// and let the agent's connectivity checks re-form pairs internally.
// Our pattern (re-Dial on retry, drive a fresh QUIC connection each
// time) needs a fresh agent every iteration.
//
// What the session still provides — even with per-iteration agents —
// are the three race fixes that were the whole point of touching this:
//
//  1. **Stale auth mid-dial.** dialICE consumes one remote auth from
//     authCh then calls agent.Dial/Accept which bakes those credentials
//     into every connectivity-check for the attempt's duration. If the
//     peer republishes a fresher auth (hot-patch, asynchronous restart)
//     ICE silently runs to its 30s timeout against creds the peer no
//     longer recognises. Fix: pollLoop, on receiving a fresher peer
//     auth, calls sess.abortAttempt to unwind the whole attempt; the
//     retry loop re-enters dialICE with a fresh agent that publishes
//     fresh local credentials and converges with the peer.
//
//  2. **Lost remote candidates between attempts.** Peer's gather is
//     one-shot per attempt — if pollLoop receives peer's candidates
//     while WE are between attempts (no agent installed yet), nothing
//     ever calls AddRemoteCandidate and peer won't resend. Fix:
//     pollLoop appends every received candidate into sess.candidateBuffer
//     in addition to dispatching to the current agent; dialICE drains
//     the buffer into the freshly-created agent before Dial. The buffer
//     is cleared whenever pollLoop observes a fresh peer auth (peer
//     rolled creds → old candidates won't match new ufrag anyway).
//
//  3. **Lost auth between attempts.** Same shape: peer auth arriving
//     when sess.agent is mid-replacement used to be dropped. Fix:
//     pollLoop always drain-then-pushes auth into a session-owned
//     authCh, independent of the abort decision. dialICE always reads
//     the freshest value from authCh when its turn comes.
type peerSession struct {
	authCh chan [2]string

	mu              sync.Mutex
	agent           *ice.Agent         // replaced on every dialICE attempt; guarded by mu
	consumedAuth    [2]string          // ufrag,pwd dialICE pulled off authCh; zero before
	abortAttempt    context.CancelFunc // non-nil for the duration of an attempt
	candidateBuffer []ice.Candidate    // remote candidates seen since last peer-auth; replayed into each new agent
}

// currentSession returns the persistent session for remoteID, or nil
// if setupPeerSession hasn't installed it yet. Used by pollLoop to
// dispatch incoming messages to the right agent.
func (m *Mesh) currentSession(remoteID string) *peerSession {
	m.sessionsMu.Lock()
	defer m.sessionsMu.Unlock()
	return m.sessions[remoteID]
}

// setupPeerSession allocates the long-lived session shell (authCh,
// candidateBuffer, mutex) for one peer. The ICE agent itself is built
// per-attempt inside dialICE — see the peerSession docstring for why
// per-attempt rather than persistent.
func (m *Mesh) setupPeerSession(remoteID string) *peerSession {
	sess := &peerSession{
		authCh: make(chan [2]string, 1),
	}
	m.sessionsMu.Lock()
	m.sessions[remoteID] = sess
	m.sessionsMu.Unlock()
	return sess
}

func (m *Mesh) dialICE(remoteID string, sess *peerSession, attemptCtx context.Context) (*ice.Conn, error) {
	cfg := m.cfg
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
	// MESH_CONN_DEBUG_ICE=1 turns on pion's verbose ICE-level logging
	// (connectivity-check requests/responses, STUN attribute parsing,
	// candidate-pair scoring). Off by default because it's chatty.
	agentCfg := &ice.AgentConfig{
		Urls:           urls,
		NetworkTypes:   []ice.NetworkType{ice.NetworkTypeUDP4, ice.NetworkTypeTCP4},
		CandidateTypes: candidateTypes,
	}
	if os.Getenv("MESH_CONN_DEBUG_ICE") == "1" {
		lf := logging.NewDefaultLoggerFactory()
		lf.DefaultLogLevel = logging.LogLevelTrace
		agentCfg.LoggerFactory = lf
	}
	agent, err := ice.NewAgent(agentCfg)
	if err != nil {
		return nil, fmt.Errorf("NewAgent: %w", err)
	}
	// Install the agent in the session BEFORE any signalling so
	// pollLoop dispatches AddRemoteCandidate to this attempt. Any
	// agent from a previous attempt is dropped (it's already failed
	// or closed by the caller) — pollLoop captures the new pointer
	// under mu and uses that.
	sess.mu.Lock()
	sess.agent = agent
	sess.mu.Unlock()

	// On failure, close the agent before returning so pion's goroutines
	// don't leak. Successful path returns the conn; runPeerLink's outer
	// loop is responsible for closing it at end-of-attempt.
	closed := false
	defer func() {
		if !closed && err != nil {
			_ = agent.Close()
		}
	}()

	if err = agent.OnCandidate(func(c ice.Candidate) {
		if c == nil {
			return
		}
		publish(cfg, remoteID, "candidate", c.Marshal())
	}); err != nil {
		return nil, err
	}
	if err = agent.OnConnectionStateChange(func(s ice.ConnectionState) {
		log.Printf("[%s] ice state: %s", remoteID, s)
		if s == ice.ConnectionStateFailed || s == ice.ConnectionStateClosed {
			sess.mu.Lock()
			if sess.abortAttempt != nil {
				sess.abortAttempt()
			}
			sess.mu.Unlock()
		}
	}); err != nil {
		return nil, err
	}

	localUfrag, localPwd, err := agent.GetLocalUserCredentials()
	if err != nil {
		return nil, err
	}
	publish(cfg, remoteID, "auth", localUfrag+":"+localPwd)

	if err = agent.GatherCandidates(); err != nil {
		return nil, err
	}

	// Replay any remote candidates already buffered by pollLoop (sent
	// by peer before this iteration's agent was even constructed).
	// pollLoop also dispatches AddRemoteCandidate to the live agent for
	// every NEW candidate; this catch-up only matters for candidates
	// from peer's last gather that arrived during our retry window.
	sess.mu.Lock()
	buffered := append([]ice.Candidate(nil), sess.candidateBuffer...)
	sess.mu.Unlock()
	for _, c := range buffered {
		if err2 := agent.AddRemoteCandidate(c); err2 != nil {
			log.Printf("[%s] replay AddRemoteCandidate: %v", remoteID, err2)
		}
	}

	// Wait for remote auth. pollLoop drain-then-pushes the freshest
	// peer auth into sess.authCh independent of state, so by the time
	// we wake we always have the latest value. attemptCtx covers the
	// case where pollLoop already aborted us mid-wait (peer rolled
	// creds again between agent install and now).
	var remote [2]string
	select {
	case remote = <-sess.authCh:
	case <-time.After(60 * time.Second):
		err = fmt.Errorf("timeout waiting for remote auth from %s", remoteID)
		return nil, err
	case <-attemptCtx.Done():
		err = fmt.Errorf("attempt aborted before auth from %s", remoteID)
		return nil, err
	}

	// Record what we're about to dial against, so pollLoop can detect
	// fresher auth from the peer and abort the attempt. See peerSession
	// docstring for why this is necessary.
	sess.mu.Lock()
	sess.consumedAuth = remote
	sess.mu.Unlock()

	// 60s safety net; pion's default connectivity-check window is 30s
	// so if Dial/Accept hasn't succeeded by then the state callback
	// will have already fired abortAttempt.
	dialTimer := time.AfterFunc(60*time.Second, func() {
		sess.mu.Lock()
		if sess.abortAttempt != nil {
			sess.abortAttempt()
		}
		sess.mu.Unlock()
	})
	defer dialTimer.Stop()

	var conn *ice.Conn
	if cfg.SelfID < remoteID {
		conn, err = agent.Dial(attemptCtx, remote[0], remote[1])
	} else {
		conn, err = agent.Accept(attemptCtx, remote[0], remote[1])
	}
	if err != nil {
		return nil, err
	}
	closed = true // success — let runPeerLink own the conn (and thus the agent)

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
// signaling — wire format shared with the coordinator's broker
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

func (m *Mesh) pollLoop(ctx context.Context) {
	cfg := m.cfg
	client := &http.Client{}
	for {
		if ctx.Err() != nil {
			return
		}
		req, _ := http.NewRequestWithContext(ctx,
			http.MethodGet,
			cfg.SignalingURL+"/poll?peer="+url.QueryEscape(cfg.SelfID),
			nil)
		resp, err := client.Do(req)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			log.Printf("poll err: %v", err)
			if !sleepCtx(ctx, time.Second) {
				return
			}
			continue
		}
		var msgs []Message
		if err := json.NewDecoder(resp.Body).Decode(&msgs); err != nil {
			log.Printf("poll decode: %v", err)
			resp.Body.Close()
			if !sleepCtx(ctx, time.Second) {
				return
			}
			continue
		}
		resp.Body.Close()
		for _, msg := range msgs {
			sess := m.currentSession(msg.From)
			if sess == nil {
				// setupPeerSession hasn't installed this remote yet;
				// drop. runPeerLink installs all peer sessions at
				// startup, so this only fires if we receive a message
				// from a non-peer id (mis-configured cluster).
				continue
			}
			switch msg.Type {
			case "auth":
				parts := strings.SplitN(msg.Data, ":", 2)
				if len(parts) != 2 {
					log.Printf("[%s] bad auth %q", msg.From, msg.Data)
					continue
				}
				newAuth := [2]string{parts[0], parts[1]}

				// Fresh peer auth is the only reliable signal we have
				// that peer rolled credentials (process restart, ICE
				// restart, etc). Three things have to happen atomically
				// under sess.mu:
				//   1. Drop the candidate buffer — those candidates
				//      belong to the previous peer epoch and won't
				//      pair against the new credentials.
				//   2. If an attempt is currently in flight against
				//      different consumed creds, abort it; runPeerLink
				//      retries with a fresh agent + republished auth.
				//   3. (Outside mu, below.) Replace the buffered auth
				//      in authCh so the next dialICE iteration reads
				//      the freshest value.
				sess.mu.Lock()
				sess.candidateBuffer = nil
				zero := [2]string{}
				if sess.abortAttempt != nil &&
					sess.consumedAuth != zero &&
					sess.consumedAuth != newAuth {
					log.Printf("[%s] fresh auth (ufrag=%s) supersedes consumed (ufrag=%s) — aborting attempt",
						msg.From, newAuth[0], sess.consumedAuth[0])
					sess.abortAttempt()
				}
				sess.mu.Unlock()

				// Drain-then-push: the channel is buffer-1 and we want
				// only the freshest auth retained for the next read.
				// pion never reuses ufrag/pwd across restarts, so the
				// freshest message is always what we want to consume.
				select {
				case <-sess.authCh:
				default:
				}
				sess.authCh <- newAuth
			case "candidate":
				cand, err := ice.UnmarshalCandidate(msg.Data)
				if err != nil {
					log.Printf("[%s] bad candidate: %v", msg.From, err)
					continue
				}
				// Buffer first, then dispatch to the live agent if any.
				// Each attempt builds a fresh agent that starts with
				// zero remote candidates; dialICE drains this buffer
				// into the new agent before Dial so peer's candidates
				// from the previous attempt window don't get lost.
				// agent may be nil if we haven't entered dialICE yet,
				// or stale if we're mid-replacement — both are fine,
				// the buffer-drain on next dialICE catches them up.
				sess.mu.Lock()
				sess.candidateBuffer = append(sess.candidateBuffer, cand)
				agent := sess.agent
				sess.mu.Unlock()
				if agent != nil {
					if err := agent.AddRemoteCandidate(cand); err != nil {
						log.Printf("[%s] AddRemoteCandidate: %v", msg.From, err)
					}
				}
			}
		}
	}
}
