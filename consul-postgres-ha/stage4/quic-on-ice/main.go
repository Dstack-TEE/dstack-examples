// quic-on-ice — smoke test that proves QUIC can run over a pion/ice.Conn.
//
// Two processes coordinate through the same /publish + /poll signaling
// broker the rest of stage 4 uses. They establish one ICE pair, then on
// top of that single pion/ice.Conn one side runs quic-go's Listen, the
// other Dial. We open one stream, transfer N MB of random data, hash
// both ends, compare.
//
// If this works, we know quic-go is happy treating our PacketConn shim
// over ice.Conn as a valid underlay. The full mesh-conn replacement of
// yamux with QUIC then becomes a bounded refactor.
//
// Usage:
//   quic-on-ice -role=A -signal=http://x:7000 -peer=B -turn-host=x -turn-secret=hexkey
//   quic-on-ice -role=B -signal=http://x:7000 -peer=A -turn-host=x -turn-secret=hexkey
//
// (any string works for role/peer; only ordering matters: lex-smaller
// becomes ICE-Dialer + QUIC-client.)

package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/pion/ice/v2"
	"github.com/pion/stun"
	"github.com/quic-go/quic-go"
)

func main() {
	role := flag.String("role", "", "this peer's id (any string)")
	peerID := flag.String("peer", "", "remote peer's id (any string)")
	signal := flag.String("signal", "", "signaling URL, e.g. http://155.138.146.255:7000")
	turnHost := flag.String("turn-host", "", "TURN host (e.g. 155.138.146.255)")
	turnSecret := flag.String("turn-secret", "", "TURN HMAC shared secret")
	mb := flag.Int("mb", 10, "MB to transfer")
	relayOnly := flag.Bool("relay-only", false, "force ICE relay-only candidates")
	flag.Parse()
	if *role == "" || *peerID == "" || *signal == "" {
		log.Fatalf("need -role, -peer, -signal")
	}

	conn, err := dialICE(*role, *peerID, *signal, *turnHost, *turnSecret, *relayOnly)
	if err != nil {
		log.Fatalf("ice dial: %v", err)
	}
	log.Printf("ice up: %s", conn.LocalAddr())

	pkt := &iceConnPacketConn{conn: conn}

	if *role < *peerID {
		runQUICClient(pkt, *peerID, *mb)
	} else {
		runQUICServer(pkt, *peerID, *mb)
	}
}

// =============================================================================
// PacketConn shim over pion/ice.Conn
// =============================================================================

// pion/ice.Conn is a net.Conn with datagram semantics: every Read returns
// at most one packet, every Write sends one packet. quic-go wants a
// net.PacketConn though, so we adapt the addr-aware methods to ignore
// the addr parameter and route everything to the single peer that ICE
// has already locked us to.
type iceConnPacketConn struct {
	conn *ice.Conn
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

// Deadlines delegate to the ICE conn so quic-go can interrupt a
// blocked ReadFrom on context cancel; mirrors mesh-conn/main.go.
func (p *iceConnPacketConn) SetDeadline(t time.Time) error      { return p.conn.SetDeadline(t) }
func (p *iceConnPacketConn) SetReadDeadline(t time.Time) error  { return p.conn.SetReadDeadline(t) }
func (p *iceConnPacketConn) SetWriteDeadline(t time.Time) error { return p.conn.SetWriteDeadline(t) }

// =============================================================================
// QUIC client / server over the PacketConn
// =============================================================================

func runQUICClient(pkt net.PacketConn, peerID string, mb int) {
	tlsConf := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{"mesh-conn-smoke"},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	// We use the underlay's own remote addr so the QUIC layer's notion
	// of "where to send" matches what the PacketConn does anyway.
	remote := pkt.LocalAddr() // any addr — pkt.WriteTo ignores it
	conn, err := quic.Dial(ctx, pkt, remote, tlsConf, &quic.Config{
		KeepAlivePeriod:        5 * time.Second,
		MaxIdleTimeout:         60 * time.Second,
		InitialStreamReceiveWindow:     4 << 20,
		MaxStreamReceiveWindow:         16 << 20,
		InitialConnectionReceiveWindow: 8 << 20,
		MaxConnectionReceiveWindow:     32 << 20,
	})
	if err != nil {
		log.Fatalf("quic dial: %v", err)
	}
	defer conn.CloseWithError(0, "")
	log.Printf("quic dialed peer %s", peerID)

	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		log.Fatalf("open stream: %v", err)
	}
	log.Printf("stream %d open, sending %d MB", stream.StreamID(), mb)

	// Send mb MiB of pseudo-random bytes; report sha256.
	h := sha256.New()
	buf := make([]byte, 64*1024)
	if _, err := rand.Read(buf); err != nil {
		log.Fatalf("rand: %v", err)
	}
	total := mb * 1024 * 1024
	start := time.Now()
	written := 0
	for written < total {
		n := total - written
		if n > len(buf) {
			n = len(buf)
		}
		// Mutate buf slightly each iteration so the hash is meaningful.
		buf[0]++
		if _, err := stream.Write(buf[:n]); err != nil {
			log.Fatalf("stream write at %d: %v", written, err)
		}
		h.Write(buf[:n])
		written += n
	}
	if err := stream.Close(); err != nil {
		log.Fatalf("stream close: %v", err)
	}
	dur := time.Since(start)
	log.Printf("client done: wrote %d B in %s (%.2f MB/s) sha256=%s",
		written, dur, float64(written)/dur.Seconds()/(1<<20),
		hex.EncodeToString(h.Sum(nil)))

	// Wait for peer to ack via close-with-error.
	<-conn.Context().Done()
	log.Printf("conn ctx done: %v", context.Cause(conn.Context()))
}

func runQUICServer(pkt net.PacketConn, peerID string, expectedMB int) {
	tlsConf := selfSignedTLS()
	tlsConf.NextProtos = []string{"mesh-conn-smoke"}
	ln, err := quic.Listen(pkt, tlsConf, &quic.Config{
		KeepAlivePeriod:                5 * time.Second,
		MaxIdleTimeout:                 60 * time.Second,
		InitialStreamReceiveWindow:     4 << 20,
		MaxStreamReceiveWindow:         16 << 20,
		InitialConnectionReceiveWindow: 8 << 20,
		MaxConnectionReceiveWindow:     32 << 20,
	})
	if err != nil {
		log.Fatalf("quic listen: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	conn, err := ln.Accept(ctx)
	if err != nil {
		log.Fatalf("accept: %v", err)
	}
	log.Printf("quic accepted peer %s", peerID)

	stream, err := conn.AcceptStream(ctx)
	if err != nil {
		log.Fatalf("accept stream: %v", err)
	}
	log.Printf("stream %d accepted", stream.StreamID())

	h := sha256.New()
	start := time.Now()
	n, err := io.Copy(h, stream)
	dur := time.Since(start)
	if err != nil {
		log.Fatalf("read: copied %d before err: %v", n, err)
	}
	log.Printf("server done: read %d B in %s (%.2f MB/s) sha256=%s",
		n, dur, float64(n)/dur.Seconds()/(1<<20),
		hex.EncodeToString(h.Sum(nil)))

	expected := int64(expectedMB) * 1024 * 1024
	if n != expected {
		log.Fatalf("byte count mismatch: got %d want %d", n, expected)
	}
	conn.CloseWithError(0, "ok")
}

func selfSignedTLS() *tls.Config {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		log.Fatalf("genkey: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "mesh-conn-smoke"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		log.Fatalf("createcert: %v", err)
	}
	return &tls.Config{
		Certificates: []tls.Certificate{{
			Certificate: [][]byte{der},
			PrivateKey:  priv,
		}},
	}
}

// =============================================================================
// minimal ICE dial — copy of mesh-conn's signalling shape
// =============================================================================

type peerSession struct {
	agent  *ice.Agent
	authCh chan [2]string
}

var (
	sessionsMu sync.Mutex
	sessions   = map[string]*peerSession{}
)

func dialICE(self, remote, signalURL, turnHost, turnSecret string, relayOnly bool) (*ice.Conn, error) {
	var urls []*stun.URI
	if turnHost != "" {
		user, pass := turnCreds(turnSecret, time.Hour)
		urls = []*stun.URI{
			{Scheme: stun.SchemeTypeSTUN, Host: turnHost, Port: 3478, Proto: stun.ProtoTypeUDP},
			{Scheme: stun.SchemeTypeTURN, Host: turnHost, Port: 3478, Proto: stun.ProtoTypeUDP, Username: user, Password: pass},
			{Scheme: stun.SchemeTypeTURN, Host: turnHost, Port: 3478, Proto: stun.ProtoTypeTCP, Username: user, Password: pass},
		}
	}
	candTypes := []ice.CandidateType{
		ice.CandidateTypeHost,
		ice.CandidateTypeServerReflexive,
		ice.CandidateTypePeerReflexive,
		ice.CandidateTypeRelay,
	}
	if relayOnly {
		candTypes = []ice.CandidateType{ice.CandidateTypeRelay}
	}
	agent, err := ice.NewAgent(&ice.AgentConfig{
		Urls:           urls,
		NetworkTypes:   []ice.NetworkType{ice.NetworkTypeUDP4, ice.NetworkTypeTCP4},
		CandidateTypes: candTypes,
	})
	if err != nil {
		return nil, err
	}
	sess := &peerSession{agent: agent, authCh: make(chan [2]string, 1)}
	sessionsMu.Lock()
	sessions[remote] = sess
	sessionsMu.Unlock()

	go pollLoop(self, signalURL)

	if err := agent.OnCandidate(func(c ice.Candidate) {
		if c == nil {
			return
		}
		publish(signalURL, self, remote, "candidate", c.Marshal())
	}); err != nil {
		return nil, err
	}
	if err := agent.OnConnectionStateChange(func(s ice.ConnectionState) {
		log.Printf("ice state: %s", s)
	}); err != nil {
		return nil, err
	}
	uf, pwd, err := agent.GetLocalUserCredentials()
	if err != nil {
		return nil, err
	}
	publish(signalURL, self, remote, "auth", uf+":"+pwd)
	if err := agent.GatherCandidates(); err != nil {
		return nil, err
	}

	var rauth [2]string
	select {
	case rauth = <-sess.authCh:
	case <-time.After(60 * time.Second):
		return nil, fmt.Errorf("timeout waiting for remote auth")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	if self < remote {
		return agent.Dial(ctx, rauth[0], rauth[1])
	}
	return agent.Accept(ctx, rauth[0], rauth[1])
}

type Message struct {
	From string `json:"from"`
	Type string `json:"type"`
	Data string `json:"data"`
}

func publish(signalURL, from, to, typ, data string) {
	body, _ := json.Marshal(Message{From: from, Type: typ, Data: data})
	resp, err := http.Post(signalURL+"/publish?to="+url.QueryEscape(to),
		"application/json", strings.NewReader(string(body)))
	if err != nil {
		log.Printf("publish: %v", err)
		return
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
}

func pollLoop(self, signalURL string) {
	for {
		resp, err := http.Get(signalURL + "/poll?peer=" + url.QueryEscape(self))
		if err != nil {
			time.Sleep(time.Second)
			continue
		}
		var msgs []Message
		json.NewDecoder(resp.Body).Decode(&msgs)
		resp.Body.Close()
		for _, m := range msgs {
			sessionsMu.Lock()
			sess := sessions[m.From]
			sessionsMu.Unlock()
			if sess == nil {
				continue
			}
			switch m.Type {
			case "auth":
				p := strings.SplitN(m.Data, ":", 2)
				if len(p) != 2 {
					continue
				}
				select {
				case <-sess.authCh:
				default:
				}
				sess.authCh <- [2]string{p[0], p[1]}
			case "candidate":
				cand, err := ice.UnmarshalCandidate(m.Data)
				if err != nil {
					continue
				}
				sess.agent.AddRemoteCandidate(cand)
			}
		}
	}
}

func turnCreds(secret string, ttl time.Duration) (string, string) {
	exp := time.Now().Add(ttl).Unix()
	user := fmt.Sprintf("%d:smoke", exp)
	h := hmac.New(sha1.New, []byte(secret))
	h.Write([]byte(user))
	return user, base64.StdEncoding.EncodeToString(h.Sum(nil))
}
