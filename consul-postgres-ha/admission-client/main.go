package main

import (
	"bytes"
	"context"
	"crypto/sha512"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	dstack "github.com/Dstack-TEE/dstack/sdk/go/dstack"
)

func main() {
	var (
		identity   = flag.String("identity", os.Getenv("ADMISSION_IDENTITY"), "claimed SPIFFE identity")
		brokerURLs = flag.String("broker-urls", os.Getenv("ADMISSION_BROKER_URLS"), "comma-separated broker base URLs")
		tokenFile  = flag.String("token-file", os.Getenv("CONSUL_HTTP_TOKEN_FILE"), "path to write the issued Consul token")
		cluster    = flag.String("cluster", os.Getenv("CLUSTER_NAME"), "cluster name")
		peerID     = flag.String("peer-id", os.Getenv("PEER_ID"), "local peer id")
		timeout    = flag.Duration("timeout", 2*time.Minute, "overall admission timeout")
	)
	flag.Parse()

	if *identity == "" {
		log.Fatal("-identity is required")
	}
	if *brokerURLs == "" {
		log.Fatal("-broker-urls is required")
	}
	if *tokenFile == "" {
		log.Fatal("-token-file is required")
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	client := dstack.NewDstackClient()
	info, err := client.Info(ctx)
	if err != nil {
		log.Fatalf("dstack Info: %v", err)
	}
	if info.VmConfig == "" {
		log.Fatal("dstack Info did not return vm_config; cannot verify OS image binding")
	}

	statement := BindingStatement{
		Version:     1,
		Identity:    *identity,
		Cluster:     *cluster,
		PeerID:      *peerID,
		AppID:       info.AppID,
		InstanceID:  info.InstanceID,
		ComposeHash: strings.TrimPrefix(strings.ToLower(info.ComposeHash), "0x"),
		IssuedAt:    time.Now().UTC().Format(time.RFC3339),
	}
	statementBytes, err := json.Marshal(statement)
	if err != nil {
		log.Fatalf("marshal binding statement: %v", err)
	}

	token, err := admit(ctx, http.DefaultClient, client, splitCSV(*brokerURLs), *identity, statementBytes, info.VmConfig)
	if err != nil {
		log.Fatal(err)
	}
	if err := writeToken(*tokenFile, token); err != nil {
		log.Fatal(err)
	}
	log.Printf("admission accepted: identity=%s compose_hash=%s token_file=%s", *identity, shortHash(statement.ComposeHash), *tokenFile)
}

type BindingStatement struct {
	Version     int    `json:"version"`
	Identity    string `json:"identity"`
	Cluster     string `json:"cluster,omitempty"`
	PeerID      string `json:"peer_id,omitempty"`
	AppID       string `json:"app_id"`
	InstanceID  string `json:"instance_id"`
	ComposeHash string `json:"compose_hash"`
	IssuedAt    string `json:"issued_at"`
}

type quoteClient interface {
	Attest(context.Context, []byte) (*dstack.AttestResponse, error)
}

func admit(ctx context.Context, httpClient *http.Client, dstackClient quoteClient, brokerURLs []string, identity string, statementBytes []byte, vmConfig string) (string, error) {
	if len(brokerURLs) == 0 {
		return "", fmt.Errorf("no broker URLs configured")
	}
	var errs []string
	for _, brokerURL := range brokerURLs {
		token, err := admitOne(ctx, httpClient, dstackClient, strings.TrimRight(brokerURL, "/"), identity, statementBytes, vmConfig)
		if err == nil {
			return token, nil
		}
		errs = append(errs, fmt.Sprintf("%s: %v", brokerURL, err))
	}
	return "", fmt.Errorf("all admission brokers rejected or failed: %s", strings.Join(errs, "; "))
}

func admitOne(ctx context.Context, httpClient *http.Client, dstackClient quoteClient, brokerURL, identity string, statementBytes []byte, vmConfig string) (string, error) {
	nonce, err := challenge(ctx, httpClient, brokerURL)
	if err != nil {
		return "", err
	}
	reportData, err := reportData(statementBytes, nonce)
	if err != nil {
		return "", err
	}
	attestation, err := dstackClient.Attest(ctx, reportData)
	if err != nil {
		return "", fmt.Errorf("Attest: %w", err)
	}
	return attest(ctx, httpClient, brokerURL, attestRequest{
		Identity:    identity,
		Binding:     hex.EncodeToString(statementBytes),
		Nonce:       nonce,
		Attestation: hex.EncodeToString(attestation.Attestation),
		VMConfig:    vmConfig,
	})
}

func challenge(ctx context.Context, httpClient *http.Client, brokerURL string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, brokerURL+"/v1/admission/challenge", nil)
	if err != nil {
		return "", err
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return "", fmt.Errorf("challenge HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var out struct {
		Nonce string `json:"nonce"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", err
	}
	if _, err := hex.DecodeString(out.Nonce); err != nil {
		return "", fmt.Errorf("broker returned invalid nonce: %w", err)
	}
	return out.Nonce, nil
}

type attestRequest struct {
	Identity    string `json:"identity"`
	Binding     string `json:"binding"`
	Nonce       string `json:"nonce"`
	Attestation string `json:"attestation"`
	VMConfig    string `json:"vm_config"`
}

func attest(ctx context.Context, httpClient *http.Client, brokerURL string, payload attestRequest) (string, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, brokerURL+"/v1/admission/attest", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return "", fmt.Errorf("attest HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var out struct {
		ConsulACLToken string `json:"consul_acl_token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", err
	}
	if out.ConsulACLToken == "" {
		return "", fmt.Errorf("broker response missing consul_acl_token")
	}
	return out.ConsulACLToken, nil
}

func reportData(statementBytes []byte, nonceHex string) ([]byte, error) {
	nonce, err := hex.DecodeString(strings.TrimPrefix(strings.ToLower(strings.TrimSpace(nonceHex)), "0x"))
	if err != nil {
		return nil, fmt.Errorf("nonce must be hex: %w", err)
	}
	if len(nonce) != 32 {
		return nil, fmt.Errorf("nonce must be 32 bytes, got %d", len(nonce))
	}
	h := sha512.New()
	h.Write(statementBytes)
	h.Write(nonce)
	return h.Sum(nil), nil
}

func writeToken(path, token string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(token+"\n"), 0o600)
}

func splitCSV(s string) []string {
	var out []string
	for _, item := range strings.Split(s, ",") {
		item = strings.TrimSpace(item)
		if item != "" {
			out = append(out, item)
		}
	}
	return out
}

func shortHash(h string) string {
	if len(h) <= 12 {
		return h
	}
	return h[:12]
}
