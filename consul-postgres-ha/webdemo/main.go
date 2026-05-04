// webdemo (stage 3b) — same as stage3a, but registered with a Connect
// sidecar so cross-peer traffic flows through Envoy + mTLS.
//
// Differences from stage 3a:
//   - service registration body includes a `Connect.SidecarService`
//     stanza that Consul uses to spin up a sidecar definition. The
//     sidecar's public listener binds the per-peer "sidecar port"
//     (env SIDECAR_PORT), and the sidecar exposes one upstream
//     ("webdemo") on local port 19000.
//   - /all calls the upstream port directly (127.0.0.1:19000/hello).
//     Each request goes app -> local sidecar -> mTLS over the overlay
//     -> remote sidecar -> remote webdemo.
//   - to fan out across all peers we hit /all multiple times so
//     Envoy's load-balancer rotates through the instances.
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

func main() {
	name := mustEnv("PEER_ID")
	port := mustEnv("WEBDEMO_PORT")
	consulAddr := mustEnv("CONSUL_HTTP_ADDR")
	sidecarPort := mustEnv("SIDECAR_PORT")
	upstreamPort := envOr("UPSTREAM_PORT", "19000")
	fanoutN := envOr("FANOUT_N", "8")

	go registerForever(consulAddr, name, port, sidecarPort)

	http.HandleFunc("/hello", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "hello from %s\n", name)
	})
	http.HandleFunc("/all", func(w http.ResponseWriter, r *http.Request) {
		// Hit the local sidecar's upstream a few times; Envoy rotates
		// across instances, so with enough samples we should reach all
		// of them at least once.
		var n int
		fmt.Sscanf(fanoutN, "%d", &n)
		results := fanOut(upstreamPort, n)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"from":    name,
			"samples": n,
			"results": results,
		})
	})

	addr := "127.0.0.1:" + port
	log.Printf("webdemo: peer=%s listening on %s, consul=%s, sidecar=%s, upstream=%s",
		name, addr, consulAddr, sidecarPort, upstreamPort)
	log.Fatal(http.ListenAndServe(addr, nil))
}

// =============================================================================
// Connect-aware registration
// =============================================================================

func registerForever(consulAddr, name, port, sidecarPort string) {
	body := fmt.Sprintf(`{
		"Name": "webdemo",
		"ID": "webdemo-%s",
		"Address": "127.0.0.1",
		"Port": %s,
		"Tags": ["peer=%s"],
		"Check": {
			"HTTP": "http://127.0.0.1:%s/hello",
			"Interval": "10s",
			"Timeout": "2s",
			"DeregisterCriticalServiceAfter": "1m"
		},
		"Connect": {
			"SidecarService": {
				"Port": %s,
				"Proxy": {
					"LocalServiceAddress": "127.0.0.1",
					"LocalServicePort": %s,
					"Upstreams": [
						{
							"DestinationName": "webdemo",
							"LocalBindAddress": "127.0.0.1",
							"LocalBindPort": 19000
						}
					]
				}
			}
		}
	}`, name, port, name, port, sidecarPort, port)

	for {
		req, _ := http.NewRequest("PUT",
			"http://"+consulAddr+"/v1/agent/service/register",
			strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err == nil && resp.StatusCode < 300 {
			resp.Body.Close()
			log.Printf("registered with consul (peer=%s, port=%s, sidecarPort=%s)",
				name, port, sidecarPort)
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
// Fan-out via local sidecar upstream port
// =============================================================================

func fanOut(upstreamPort string, n int) map[string]int {
	results := make(map[string]int)
	var mu sync.Mutex
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			client := &http.Client{Timeout: 3 * time.Second}
			resp, err := client.Get("http://127.0.0.1:" + upstreamPort + "/hello")
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
