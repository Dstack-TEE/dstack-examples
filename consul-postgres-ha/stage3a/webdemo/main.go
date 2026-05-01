// webdemo — tiny HTTP service that:
//   - registers itself with the local Consul agent as service "webdemo"
//   - exposes /hello returning "hello from <peer>"
//   - exposes /all that fans out /hello to every peer instance found
//     in Consul's catalog (using addresses Consul gave us, which
//     resolve to 127.0.0.1:<peer-port> via the mesh-conn overlay)
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
	consulAddr := mustEnv("CONSUL_HTTP_ADDR") // e.g. 127.0.0.1:18201

	go registerForever(consulAddr, name, port)

	http.HandleFunc("/hello", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "hello from %s\n", name)
	})
	http.HandleFunc("/all", func(w http.ResponseWriter, r *http.Request) {
		peers, err := listService(consulAddr, "webdemo")
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		results := fanOutHello(peers)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"from":    name,
			"peers":   peers,
			"results": results,
		})
	})

	addr := "127.0.0.1:" + port
	log.Printf("webdemo: peer=%s listening on %s, consul=%s", name, addr, consulAddr)
	log.Fatal(http.ListenAndServe(addr, nil))
}

// =============================================================================
// Consul registration / discovery
// =============================================================================

type catalogEntry struct {
	ServiceID      string
	ServiceName    string
	ServiceAddress string
	ServicePort    int
}

func registerForever(consulAddr, name, port string) {
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
		}
	}`, name, port, name, port)

	for {
		req, _ := http.NewRequest("PUT",
			"http://"+consulAddr+"/v1/agent/service/register",
			strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err == nil && resp.StatusCode < 300 {
			resp.Body.Close()
			log.Printf("registered with consul (peer=%s, port=%s)", name, port)
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

func listService(consulAddr, service string) ([]catalogEntry, error) {
	resp, err := http.Get("http://" + consulAddr + "/v1/catalog/service/" + service)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("catalog %d: %s", resp.StatusCode, b)
	}
	var entries []catalogEntry
	if err := json.NewDecoder(resp.Body).Decode(&entries); err != nil {
		return nil, err
	}
	return entries, nil
}

// =============================================================================
// Fan-out
// =============================================================================

func fanOutHello(peers []catalogEntry) map[string]string {
	results := make(map[string]string, len(peers))
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, p := range peers {
		p := p
		wg.Add(1)
		go func() {
			defer wg.Done()
			endpoint := fmt.Sprintf("http://%s:%d/hello", p.ServiceAddress, p.ServicePort)
			client := &http.Client{Timeout: 3 * time.Second}
			body := ""
			resp, err := client.Get(endpoint)
			if err != nil {
				body = "error: " + err.Error()
			} else {
				b, _ := io.ReadAll(resp.Body)
				resp.Body.Close()
				body = strings.TrimSpace(string(b))
			}
			mu.Lock()
			results[p.ServiceID] = body
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
