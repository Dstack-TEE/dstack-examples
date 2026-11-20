// webdemo — tiny Connect-mesh sample sitting on the peer-VIP / service-VIP
// fabric.
//
// Binds canonical 127.0.0.1:8080 and serves two endpoints:
//
//   GET /hello  → "hello from <peer-id>"
//   GET /all    → fan-out N times to http://webdemo:8080/hello and
//                 aggregate replies; demonstrates Envoy-LB across peers
//
// Platform plumbing — Consul registration, sidecar provisioning,
// /etc/hosts entries, service-VIP allocation — happens entirely in
// `mesh-sidecar/entrypoint.sh` from `SERVICES_JSON`. The app binary
// has zero awareness of any of it; it just binds and serves.
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

const webdemoPort = 8080

func main() {
	name := envOr("PEER_ID", "webdemo")
	fanoutN := envOr("FANOUT_N", "8")

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
	log.Printf("webdemo: peer=%s listening on %s", name, addr)
	log.Fatal(http.ListenAndServe(addr, nil))
}

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

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
