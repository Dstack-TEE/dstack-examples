// Phase-0 ICE feasibility test.
//
// Single binary with two modes:
//   - signaling: tiny HTTP broker that ferries ICE candidates + ufrag/pwd
//     between two peers. Runs on the public coturn host.
//   - peer:      runs a pion/ice agent against coturn (STUN+TURN), exchanges
//     candidates via signaling, establishes connectivity, sends echo
//     packets, and prints which candidate pair won + RTT samples.
//
// The point: confirm whether a dstack CVM can hole-punch UDP to another
// dstack CVM (best case: srflx<->srflx), or whether ICE is forced onto
// the relay path (TURN) by dstack's network model.

package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/pion/ice/v2"
	"github.com/pion/stun"
)

func main() {
	mode := flag.String("mode", "", "signaling | peer")
	addr := flag.String("addr", ":7000", "signaling listen address")
	flag.Parse()

	switch *mode {
	case "signaling":
		runSignaling(*addr)
	case "peer":
		runPeer()
	default:
		log.Fatalf("usage: %s -mode=signaling|peer", os.Args[0])
	}
}

// =============================================================================
// signaling: HTTP broker
//
// POST /publish?to=<peer>      body=Message  -> queue for recipient
// GET  /poll?peer=<peer>                     -> long-poll, returns up to N
//                                              messages, drains the queue
// =============================================================================

type Message struct {
	From string `json:"from"`
	Type string `json:"type"` // "auth" | "candidate" | "done"
	Data string `json:"data"`
}

type mailbox struct {
	mu      sync.Mutex
	queues  map[string][]Message
	waiters map[string]chan struct{}
}

func newMailbox() *mailbox {
	return &mailbox{
		queues:  make(map[string][]Message),
		waiters: make(map[string]chan struct{}),
	}
}

func (m *mailbox) push(to string, msg Message) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.queues[to] = append(m.queues[to], msg)
	if w, ok := m.waiters[to]; ok {
		close(w)
		delete(m.waiters, to)
	}
}

func (m *mailbox) drain(peer string) []Message {
	m.mu.Lock()
	defer m.mu.Unlock()
	q := m.queues[peer]
	delete(m.queues, peer)
	return q
}

func (m *mailbox) wait(peer string) <-chan struct{} {
	m.mu.Lock()
	defer m.mu.Unlock()
	if len(m.queues[peer]) > 0 {
		c := make(chan struct{})
		close(c)
		return c
	}
	if w, ok := m.waiters[peer]; ok {
		return w
	}
	w := make(chan struct{})
	m.waiters[peer] = w
	return w
}

func runSignaling(addr string) {
	mb := newMailbox()

	http.HandleFunc("/publish", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		to := r.URL.Query().Get("to")
		if to == "" {
			http.Error(w, "missing ?to=", http.StatusBadRequest)
			return
		}
		var msg Message
		if err := json.NewDecoder(r.Body).Decode(&msg); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		mb.push(to, msg)
		log.Printf("signaling: %s -> %s : %s", msg.From, to, msg.Type)
		w.WriteHeader(http.StatusNoContent)
	})

	http.HandleFunc("/poll", func(w http.ResponseWriter, r *http.Request) {
		peer := r.URL.Query().Get("peer")
		if peer == "" {
			http.Error(w, "missing ?peer=", http.StatusBadRequest)
			return
		}
		select {
		case <-mb.wait(peer):
		case <-time.After(25 * time.Second):
		case <-r.Context().Done():
			return
		}
		msgs := mb.drain(peer)
		_ = json.NewEncoder(w).Encode(msgs)
	})

	log.Printf("signaling listening on %s", addr)
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatal(err)
	}
}

// =============================================================================
// peer: pion/ice agent
// =============================================================================

func runPeer() {
	peerID := mustEnv("PEER_ID")
	partnerID := mustEnv("PARTNER_ID")
	signalingURL := strings.TrimRight(mustEnv("SIGNALING_URL"), "/")
	turnHost := os.Getenv("TURN_HOST")
	turnSecret := os.Getenv("TURN_SHARED_SECRET")

	var urls []*stun.URI
	if turnHost != "" {
		if turnSecret == "" {
			log.Fatalf("TURN_HOST set but TURN_SHARED_SECRET missing")
		}
		turnUser, turnPass := makeTurnCreds(turnSecret, 1*time.Hour)
		urls = []*stun.URI{
			{Scheme: stun.SchemeTypeSTUN, Host: turnHost, Port: 3478, Proto: stun.ProtoTypeUDP},
			{Scheme: stun.SchemeTypeTURN, Host: turnHost, Port: 3478, Proto: stun.ProtoTypeUDP,
				Username: turnUser, Password: turnPass},
			{Scheme: stun.SchemeTypeTURN, Host: turnHost, Port: 3478, Proto: stun.ProtoTypeTCP,
				Username: turnUser, Password: turnPass},
		}
		log.Printf("ICE: using STUN+TURN at %s", turnHost)
	} else {
		log.Printf("ICE: host-candidates only (no TURN_HOST set)")
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
		log.Fatalf("ice.NewAgent: %v", err)
	}

	// Send each locally-gathered candidate to the partner.
	if err := agent.OnCandidate(func(c ice.Candidate) {
		if c == nil {
			log.Printf("local: gathering complete")
			return
		}
		log.Printf("local candidate: %s (%s)", c.String(), c.Type())
		publish(signalingURL, peerID, partnerID, "candidate", c.Marshal())
	}); err != nil {
		log.Fatalf("OnCandidate: %v", err)
	}

	if err := agent.OnConnectionStateChange(func(s ice.ConnectionState) {
		log.Printf("ice state: %s", s)
	}); err != nil {
		log.Fatalf("OnConnectionStateChange: %v", err)
	}

	localUfrag, localPwd, err := agent.GetLocalUserCredentials()
	if err != nil {
		log.Fatalf("GetLocalUserCredentials: %v", err)
	}

	publish(signalingURL, peerID, partnerID, "auth", localUfrag+":"+localPwd)

	if err := agent.GatherCandidates(); err != nil {
		log.Fatalf("GatherCandidates: %v", err)
	}

	authCh := make(chan [2]string, 1)
	go pollLoop(signalingURL, peerID, agent, authCh)

	var remote [2]string
	select {
	case remote = <-authCh:
	case <-time.After(60 * time.Second):
		log.Fatalf("timed out waiting for partner auth")
	}
	log.Printf("got remote auth from %s", partnerID)

	// No timeout — wait indefinitely for the partner. Each CVM may boot far
	// out of sync with the other (image pull, KMS init, etc.). Container
	// restart policy handles process-level failure.
	ctx := context.Background()

	var conn *ice.Conn
	// Lexicographically smaller peer-id is the controlling side (Dial).
	if peerID < partnerID {
		log.Printf("role: controlling (Dial)")
		conn, err = agent.Dial(ctx, remote[0], remote[1])
	} else {
		log.Printf("role: controlled (Accept)")
		conn, err = agent.Accept(ctx, remote[0], remote[1])
	}
	if err != nil {
		log.Fatalf("ice connect: %v", err)
	}

	pair, err := agent.GetSelectedCandidatePair()
	if err != nil {
		log.Fatalf("GetSelectedCandidatePair: %v", err)
	}
	log.Printf("==========================================================")
	log.Printf("CONNECTED via %s <-> %s", pair.Local.Type(), pair.Remote.Type())
	log.Printf("  local : %s", pair.Local.String())
	log.Printf("  remote: %s", pair.Remote.String())
	log.Printf("==========================================================")

	if peerID < partnerID {
		runEchoSender(conn)
	} else {
		runEchoResponder(conn)
	}
}

func runEchoSender(conn *ice.Conn) {
	buf := make([]byte, 1500)
	for i := 0; i < 20; i++ {
		t := time.Now()
		payload := fmt.Sprintf("ping-%d", i)
		if _, err := conn.Write([]byte(payload)); err != nil {
			log.Fatalf("write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(5 * time.Second))
		n, err := conn.Read(buf)
		if err != nil {
			log.Printf("read err: %v", err)
			break
		}
		log.Printf("rtt=%v reply=%q", time.Since(t), string(buf[:n]))
		time.Sleep(200 * time.Millisecond)
	}
	log.Printf("done")
}

func runEchoResponder(conn *ice.Conn) {
	buf := make([]byte, 1500)
	for {
		n, err := conn.Read(buf)
		if err != nil {
			log.Printf("read err: %v", err)
			return
		}
		if _, err := conn.Write(buf[:n]); err != nil {
			log.Printf("write err: %v", err)
			return
		}
	}
}

// =============================================================================
// helpers
// =============================================================================

func pollLoop(signalingURL, peerID string, agent *ice.Agent, authCh chan<- [2]string) {
	authSent := false
	for {
		resp, err := http.Get(signalingURL + "/poll?peer=" + url.QueryEscape(peerID))
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
					log.Printf("bad auth: %q", m.Data)
					continue
				}
				authCh <- [2]string{parts[0], parts[1]}
				authSent = true
			case "candidate":
				cand, err := ice.UnmarshalCandidate(m.Data)
				if err != nil {
					log.Printf("bad candidate %q: %v", m.Data, err)
					continue
				}
				log.Printf("remote candidate: %s (%s)", cand.String(), cand.Type())
				if err := agent.AddRemoteCandidate(cand); err != nil {
					log.Printf("AddRemoteCandidate: %v", err)
				}
			}
		}
	}
}

func publish(signalingURL, from, to, typ, data string) {
	body, _ := json.Marshal(Message{From: from, Type: typ, Data: data})
	resp, err := http.Post(signalingURL+"/publish?to="+url.QueryEscape(to),
		"application/json", strings.NewReader(string(body)))
	if err != nil {
		log.Printf("publish err: %v", err)
		return
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
}

func makeTurnCreds(secret string, ttl time.Duration) (string, string) {
	exp := time.Now().Add(ttl).Unix()
	user := fmt.Sprintf("%d:phase0", exp)
	h := hmac.New(sha1.New, []byte(secret))
	h.Write([]byte(user))
	pass := base64.StdEncoding.EncodeToString(h.Sum(nil))
	return user, pass
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("missing env %s", k)
	}
	return v
}
