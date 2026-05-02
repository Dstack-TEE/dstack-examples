// bootstrap-secrets — stage 4 init container.
//
// One-shot. Runs to completion before any other service starts on a CVM.
// Responsibilities:
//
//   1. Use the dstack Go SDK to learn this CVM's identity (AppID,
//      InstanceID, ComposeHash) and to derive cluster-wide secrets
//      (gossip key, TURN secret, Connect-CA seed) deterministically
//      from the app's KMS-bound key. Same secrets across every
//      replica of the same phala_app, never visible to the deploy
//      host.
//
//   2. Claim a stable ordinal (0..N-1) for this CVM by atomic-CAS-ing
//      a slot in Consul KV (workers only — the coordinator is always
//      ordinal 0). The InstanceID is the slot's permanent owner so
//      restarts re-find their own slot.
//
//   3. Write everything dependent services need to a tmpfs volume
//      shared via compose. /run/secrets/{gossip,turn,ca-seed} are
//      mode-0400 binary blobs; /run/instance/info.json carries the
//      identity + ordinal + computed per-protocol ports.
//
//   4. Exit 0 so compose `depends_on` with
//      `condition: service_completed_successfully` can release the
//      next services.
//
// The keystone of the stage-4 design is here: this is the only piece
// that holds plaintext secret material, and it does so entirely
// inside the TEE. The deploy host never sees them.

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	dstack "github.com/Dstack-TEE/dstack/sdk/go/dstack"
	consulapi "github.com/hashicorp/consul/api"
)

func main() {
	flag.Parse()
	cfg := loadConfig()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	// 1. Identity from dstack SDK.
	client := dstack.NewDstackClient()
	info, err := client.Info(ctx)
	if err != nil {
		log.Fatalf("dstack Info: %v", err)
	}
	log.Printf("dstack: app_id=%s instance_id=%s compose_hash=%s",
		info.AppID, info.InstanceID, shortHash(info.ComposeHash))

	// 2. Derive cluster-wide secrets. Same path/purpose triple
	// returns the same 32 bytes on every replica of this app.
	derived := map[string]string{
		"gossip":  "dstack-mesh/gossip",
		"turn":    "dstack-mesh/turn",
		"ca-seed": "dstack-mesh/connect-ca",
	}
	for name, path := range derived {
		seed, err := client.GetKey(ctx, path, cfg.ClusterName, "secp256k1")
		if err != nil {
			log.Fatalf("GetKey %s: %v", path, err)
		}
		keyBytes, err := seed.DecodeKey()
		if err != nil {
			log.Fatalf("decode %s: %v", path, err)
		}
		if err := writeSecret("/run/secrets/"+name, keyBytes); err != nil {
			log.Fatalf("write %s: %v", name, err)
		}
		log.Printf("derived %s (%d bytes) -> /run/secrets/%s", name, len(keyBytes), name)
	}

	// 3. Ordinal claim via Consul KV (workers only).
	//    Coordinator is always ordinal 0 — there's exactly one
	//    coordinator initially, and Consul itself runs there so the
	//    catalog can't bootstrap us before we bootstrap it.
	ordinal := 0
	if cfg.Role != "coordinator" {
		var err error
		ordinal, err = claimOrdinal(cfg, info.InstanceID)
		if err != nil {
			log.Fatalf("ordinal claim: %v", err)
		}
	}

	// 4. Compute per-protocol ports for this ordinal.
	ports := computePorts(cfg.ProtocolBases, ordinal)

	instance := InstanceInfo{
		InstanceID:  info.InstanceID,
		AppID:       info.AppID,
		ComposeHash: info.ComposeHash,
		ClusterName: cfg.ClusterName,
		Role:        cfg.Role,
		Ordinal:     ordinal,
		Ports:       ports,
	}
	if err := writeJSON("/run/instance/info.json", instance); err != nil {
		log.Fatalf("write instance info: %v", err)
	}

	log.Printf("bootstrap done: role=%s ordinal=%d ports=%v", cfg.Role, ordinal, ports)
}

// =============================================================================
// config
// =============================================================================

type Config struct {
	ClusterName      string
	Role             string // coordinator | worker
	ConsulHTTPAddr   string // 127.0.0.1:<port> on the local agent
	ExpectedReplicas int    // upper bound on ordinal slots to try
	ProtocolBases    map[string]int
}

func loadConfig() *Config {
	cfg := &Config{
		ClusterName:      mustEnv("CLUSTER_NAME"),
		Role:             mustEnv("ROLE"),
		ConsulHTTPAddr:   os.Getenv("CONSUL_HTTP_ADDR"), // empty for coordinator
		ExpectedReplicas: 16,                            // generous upper bound
	}
	// PROTOCOL_BASES: JSON object of name -> base port.
	rawBases := mustEnv("PROTOCOL_BASES")
	if err := json.Unmarshal([]byte(rawBases), &cfg.ProtocolBases); err != nil {
		log.Fatalf("PROTOCOL_BASES not valid JSON: %v", err)
	}
	if r := os.Getenv("EXPECTED_REPLICAS"); r != "" {
		n, err := strconv.Atoi(r)
		if err != nil || n <= 0 {
			log.Fatalf("EXPECTED_REPLICAS invalid: %v", err)
		}
		cfg.ExpectedReplicas = n
	}
	return cfg
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("missing env %s", k)
	}
	return v
}

// =============================================================================
// ordinal claim — Consul KV CAS
// =============================================================================

// claimOrdinal walks slot indices 0..ExpectedReplicas-1, finds either
//
//   - a slot whose value is already this InstanceID (we're rejoining), or
//   - the lowest empty slot (CAS-claim it).
//
// First match wins. Returns the slot index. Slot ownership is
// permanent for the InstanceID's lifetime; cleanup of stale slots
// (when an instance is permanently retired) is a separate operator
// task — note in stage-4 README.
func claimOrdinal(cfg *Config, instanceID string) (int, error) {
	if cfg.ConsulHTTPAddr == "" {
		return 0, fmt.Errorf("CONSUL_HTTP_ADDR required for non-coordinator role")
	}
	cli, err := consulapi.NewClient(&consulapi.Config{
		Address: cfg.ConsulHTTPAddr,
		Scheme:  "http",
	})
	if err != nil {
		return 0, fmt.Errorf("consul client: %w", err)
	}
	kv := cli.KV()

	keyPrefix := fmt.Sprintf("cluster/%s/slots", cfg.ClusterName)

	// Retry the whole walk a few times — pollLoop racing with peers
	// could cause CAS misses; on a miss, try the next slot or restart
	// the walk.
	for attempt := 0; attempt < 20; attempt++ {
		for i := 0; i < cfg.ExpectedReplicas; i++ {
			key := fmt.Sprintf("%s/%d", keyPrefix, i)
			existing, _, err := kv.Get(key, nil)
			if err != nil {
				return 0, fmt.Errorf("kv get %s: %w", key, err)
			}
			switch {
			case existing != nil && string(existing.Value) == instanceID:
				log.Printf("rejoining slot %d (already owned)", i)
				return i, nil
			case existing == nil:
				ok, _, err := kv.CAS(&consulapi.KVPair{
					Key:         key,
					Value:       []byte(instanceID),
					ModifyIndex: 0,
				}, nil)
				if err != nil {
					return 0, fmt.Errorf("kv cas %s: %w", key, err)
				}
				if ok {
					log.Printf("claimed slot %d (fresh)", i)
					return i, nil
				}
				// CAS lost the race; some other peer claimed
				// this slot first. Try the next slot.
			default:
				// owned by another instance; skip
			}
		}
		// Exhausted slots without claiming or rejoining; either the
		// cluster is over-replicated or there's a stale slot. Sleep
		// briefly and retry — gives a slot a chance to clear if a
		// peer is in transient state.
		time.Sleep(2 * time.Second)
	}
	return 0, fmt.Errorf("no available slot in cluster %q (max=%d) — cluster over-replicated or has stale slots",
		cfg.ClusterName, cfg.ExpectedReplicas)
}

// =============================================================================
// instance info + tmpfs writes
// =============================================================================

type InstanceInfo struct {
	InstanceID  string         `json:"instance_id"`
	AppID       string         `json:"app_id"`
	ComposeHash string         `json:"compose_hash"`
	ClusterName string         `json:"cluster_name"`
	Role        string         `json:"role"`
	Ordinal     int            `json:"ordinal"`
	Ports       map[string]int `json:"ports"`
}

func computePorts(bases map[string]int, ordinal int) map[string]int {
	out := make(map[string]int, len(bases))
	for name, base := range bases {
		out[name] = base + ordinal
	}
	return out
}

func writeSecret(path string, b []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	// Hex-encode so non-binary-safe consumers (Consul -encrypt-key-file
	// expects a base64-or-hex string in a file) can use the file
	// directly.
	encoded := hex.EncodeToString(b) + "\n"
	return os.WriteFile(path, []byte(encoded), 0o400)
}

func writeJSON(path string, v any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0o444)
}

func shortHash(s string) string {
	if len(s) < 12 {
		return s
	}
	return s[:12] + "..."
}

// silence unused import on Linux if go vet complains about strings
var _ = strings.HasPrefix
var _ = sha256.New
