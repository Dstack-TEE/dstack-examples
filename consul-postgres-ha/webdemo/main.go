// webdemo — tiny Connect-mesh sample sitting on the peer-VIP / service-VIP
// fabric.
//
// Each instance:
//   - listens on canonical 127.0.0.1:8080 (the workload itself)
//   - registers itself as Consul service `webdemo` with a Connect
//     sidecar advertised at 127.50.0.<SELF_VIP>:21000 (the peer's
//     mesh-routable address for inbound mTLS)
//   - declares ONE upstream: `webdemo` itself, with the local Envoy
//     listener bound to the service VIP for `webdemo` (resolved from
//     UPSTREAMS_JSON env). /etc/hosts on every container maps the
//     service name to that VIP, so dialing http://webdemo:8080/hello
//     hits the local Envoy and fans out across all peers' webdemo
//     instances over Connect mTLS.
//
// All cross-peer ports / arithmetic are gone — the only numbers in
// this file are 8080 (canonical webdemo port), 21000 (canonical
// webdemo sidecar port), and the service VIPs read from env.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	webdemoPort = 8080  // canonical app port — same on every CVM
	sidecarPort = 21000 // canonical Envoy public mTLS port for webdemo
)

func main() {
	name := mustEnv("PEER_ID")
	selfVip := mustEnv("SELF_VIP")
	consulAddr := envOr("CONSUL_HTTP_ADDR", "127.0.0.1:8500")
	fanoutN := envOr("FANOUT_N", "8")
	webdemoUpstreamVip := upstreamVip("webdemo")

	go registerForever(consulAddr, name, selfVip, webdemoUpstreamVip)

	http.HandleFunc("/hello", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "hello from %s\n", name)
	})
	http.HandleFunc("/all", func(w http.ResponseWriter, r *http.Request) {
		// Hit `webdemo:8080/hello` (resolved via /etc/hosts → service
		// VIP → local Envoy upstream). Envoy's load-balancer rotates
		// across all registered webdemo instances; with enough samples
		// we should reach each peer at least once.
		var n int
		fmt.Sscanf(fanoutN, "%d", &n)
		results := fanOut(n)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"from":    name,
			"samples": n,
			"results": results,
		})
	})

	addr := fmt.Sprintf("127.0.0.1:%d", webdemoPort)
	log.Printf("webdemo: peer=%s vip=%s listening on %s, sidecar=%d",
		name, selfVip, addr, sidecarPort)
	log.Fatal(http.ListenAndServe(addr, nil))
}

// =============================================================================
// Connect-aware registration
// =============================================================================

func registerForever(consulAddr, name, selfVip string, upstreamVip int) {
	body := fmt.Sprintf(`{
		"Name": "webdemo",
		"ID": "webdemo-%s",
		"Address": "127.0.0.1",
		"Port": %d,
		"Tags": ["peer=%s"],
		"Check": {
			"HTTP": "http://127.0.0.1:%d/hello",
			"Interval": "10s",
			"Timeout": "2s",
			"DeregisterCriticalServiceAfter": "1m"
		},
		"Connect": {
			"SidecarService": {
				"Address": "127.50.0.%s",
				"Port": %d,
				"Proxy": {
					"LocalServiceAddress": "127.0.0.1",
					"LocalServicePort": %d,
					"Upstreams": [
						{
							"DestinationName": "webdemo",
							"LocalBindAddress": "127.10.0.%d",
							"LocalBindPort": %d
						}
					]
				}
			}
		}
	}`, name, webdemoPort, name, webdemoPort, selfVip, sidecarPort, webdemoPort, upstreamVip, webdemoPort)

	for {
		req, _ := http.NewRequest("PUT",
			"http://"+consulAddr+"/v1/agent/service/register",
			strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err == nil && resp.StatusCode < 300 {
			resp.Body.Close()
			log.Printf("registered with consul (peer=%s, sidecar=127.50.0.%s:%d)",
				name, selfVip, sidecarPort)
			return
		}
		if resp != nil {
			b, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			log.Printf("register failed (status=%d): %s", resp.StatusCode, b)
		} else {
			log.Printf("register err: %v", err)
		}
		time.Sleep(2 * time.Second)
	}
}

// =============================================================================
// Fan-out via the local sidecar's `webdemo` upstream
// =============================================================================

func fanOut(n int) map[string]int {
	results := make(map[string]int)
	var mu sync.Mutex
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			client := &http.Client{Timeout: 3 * time.Second}
			resp, err := client.Get(fmt.Sprintf("http://webdemo:%d/hello", webdemoPort))
			body := ""
			if err != nil {
				body = "error: " + err.Error()
			} else {
				b, _ := io.ReadAll(resp.Body)
				resp.Body.Close()
				body = strings.TrimSpace(string(b))
			}
			mu.Lock()
			results[body]++
			mu.Unlock()
		}()
	}
	wg.Wait()
	return results
}

// upstreamVip parses UPSTREAMS_JSON env (shape: [{name, vip, port}, ...])
// and returns the VIP octet for the named service, or fatals.
func upstreamVip(name string) int {
	raw := mustEnv("UPSTREAMS_JSON")
	var list []struct {
		Name string `json:"name"`
		Vip  int    `json:"vip"`
		Port int    `json:"port"`
	}
	if err := json.Unmarshal([]byte(raw), &list); err != nil {
		log.Fatalf("UPSTREAMS_JSON parse: %v", err)
	}
	for _, u := range list {
		if u.Name == name {
			return u.Vip
		}
	}
	log.Fatalf("upstream %q not in UPSTREAMS_JSON", name)
	return 0
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
