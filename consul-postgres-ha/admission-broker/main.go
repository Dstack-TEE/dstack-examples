package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/hex"
	"encoding/json"
	"errors"
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
)

const (
	defaultListenAddr  = "127.0.0.1:8787"
	defaultVerifierURL = "http://127.0.0.1:8080/verify"
	defaultConsulURL   = "http://127.0.0.1:8500"
	defaultTokenTTL    = time.Hour
)

func main() {
	var (
		listenAddr  = flag.String("listen", envOr("ADMISSION_BROKER_LISTEN", defaultListenAddr), "HTTP listen address")
		verifierURL = flag.String("verifier-url", envOr("DSTACK_VERIFIER_URL", defaultVerifierURL), "dstack-verifier /verify URL")
		consulURL   = flag.String("consul-url", envOr("CONSUL_HTTP_ADDR", defaultConsulURL), "Consul HTTP API URL")
		policyPath  = flag.String("policy", os.Getenv("ADMISSION_POLICY_FILE"), "path to admission policy JSON")
		tokenTTL    = flag.Duration("token-ttl", durationEnvOr("ADMISSION_TOKEN_TTL", defaultTokenTTL), "issued Consul ACL token TTL")
	)
	flag.Parse()

	policyJSON := []byte(os.Getenv("ADMISSION_POLICY_JSON"))
	if *policyPath != "" {
		b, err := os.ReadFile(*policyPath)
		if err != nil {
			log.Fatalf("read policy: %v", err)
		}
		policyJSON = b
	}
	if len(bytes.TrimSpace(policyJSON)) == 0 {
		log.Fatal("ADMISSION_POLICY_JSON or -policy is required")
	}

	policy, err := ParsePolicy(policyJSON)
	if err != nil {
		log.Fatalf("parse policy: %v", err)
	}

	consulToken := os.Getenv("CONSUL_MANAGEMENT_TOKEN")
	if consulToken == "" {
		log.Fatal("CONSUL_MANAGEMENT_TOKEN is required to issue ACL tokens")
	}

	s := &Server{
		policy:      policy,
		nonces:      NewNonceStore(time.Minute),
		verifier:    &VerifierClient{URL: *verifierURL, HTTP: http.DefaultClient},
		issuer:      &ConsulIssuer{BaseURL: normalizeHTTPBaseURL(*consulURL), ManagementToken: consulToken, HTTP: http.DefaultClient},
		tokenTTL:    *tokenTTL,
		now:         time.Now,
		nonceRandom: rand.Reader,
	}

	log.Printf("admission-broker listening on %s; policy_epoch=%d workloads=%d", *listenAddr, policy.PolicyEpoch, len(policy.Workloads))
	if err := http.ListenAndServe(*listenAddr, s.routes()); err != nil {
		log.Fatal(err)
	}
}

type Policy struct {
	Cluster     string     `json:"cluster"`
	PolicyEpoch int        `json:"policy_epoch"`
	Workloads   []Workload `json:"workloads"`

	byIdentity map[string][]Workload
}

type Workload struct {
	WorkloadID            string            `json:"workload_id"`
	Identity              string            `json:"identity"`
	ConsulService         string            `json:"consul_service"`
	ConsulPermissions     ConsulPermissions `json:"consul_permissions,omitempty"`
	AllowedComposeHashes  []string          `json:"allowed_compose_hashes"`
	Evidence              json.RawMessage   `json:"evidence,omitempty"`
	allowedComposeHashSet map[string]struct{}
}

type ConsulPermissions struct {
	KeyPrefixes   []string `json:"key_prefixes,omitempty"`
	SessionWrite  bool     `json:"session_write,omitempty"`
	AgentReadSelf bool     `json:"agent_read_self,omitempty"`
}

func ParsePolicy(b []byte) (*Policy, error) {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()

	var p Policy
	if err := dec.Decode(&p); err != nil {
		return nil, err
	}
	if strings.TrimSpace(p.Cluster) == "" {
		return nil, errors.New("cluster is required")
	}
	if p.PolicyEpoch <= 0 {
		return nil, errors.New("policy_epoch must be positive")
	}
	if len(p.Workloads) == 0 {
		return nil, errors.New("workloads must not be empty")
	}

	p.byIdentity = make(map[string][]Workload)
	seenID := make(map[string]struct{})
	for i := range p.Workloads {
		w := &p.Workloads[i]
		if strings.TrimSpace(w.WorkloadID) == "" {
			return nil, fmt.Errorf("workloads[%d].workload_id is required", i)
		}
		if _, ok := seenID[w.WorkloadID]; ok {
			return nil, fmt.Errorf("duplicate workload_id %q", w.WorkloadID)
		}
		seenID[w.WorkloadID] = struct{}{}

		if strings.TrimSpace(w.Identity) == "" {
			return nil, fmt.Errorf("workloads[%d].identity is required", i)
		}
		if strings.TrimSpace(w.ConsulService) == "" {
			return nil, fmt.Errorf("workloads[%d].consul_service is required", i)
		}
		for j, prefix := range w.ConsulPermissions.KeyPrefixes {
			prefix = strings.Trim(prefix, "/")
			if prefix == "" {
				return nil, fmt.Errorf("workloads[%d].consul_permissions.key_prefixes[%d] is empty", i, j)
			}
			w.ConsulPermissions.KeyPrefixes[j] = prefix
		}
		if len(w.AllowedComposeHashes) == 0 {
			return nil, fmt.Errorf("workloads[%d].allowed_compose_hashes must not be empty", i)
		}
		w.allowedComposeHashSet = make(map[string]struct{}, len(w.AllowedComposeHashes))
		for j, h := range w.AllowedComposeHashes {
			normalized, err := normalizeComposeHash(h)
			if err != nil {
				return nil, fmt.Errorf("workloads[%d].allowed_compose_hashes[%d]: %w", i, j, err)
			}
			w.AllowedComposeHashes[j] = normalized
			w.allowedComposeHashSet[normalized] = struct{}{}
		}
		p.byIdentity[w.Identity] = append(p.byIdentity[w.Identity], *w)
	}
	return &p, nil
}

func (p *Policy) Match(identity, composeHash string) (*Workload, error) {
	normalized, err := normalizeComposeHash(composeHash)
	if err != nil {
		return nil, fmt.Errorf("invalid compose_hash from quote: %w", err)
	}
	for _, w := range p.byIdentity[identity] {
		if _, ok := w.allowedComposeHashSet[normalized]; ok {
			return &w, nil
		}
	}
	return nil, fmt.Errorf("identity %q is not allowed for compose_hash %s", identity, normalized)
}

func normalizeComposeHash(h string) (string, error) {
	h = strings.TrimSpace(strings.TrimPrefix(strings.ToLower(h), "0x"))
	if len(h) != 64 {
		return "", fmt.Errorf("expected 32-byte hex hash, got %d hex chars", len(h))
	}
	if _, err := hex.DecodeString(h); err != nil {
		return "", err
	}
	return h, nil
}

type Server struct {
	policy      *Policy
	nonces      *NonceStore
	verifier    *VerifierClient
	issuer      TokenIssuer
	tokenTTL    time.Duration
	now         func() time.Time
	nonceRandom io.Reader
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/admission/challenge", s.handleChallenge)
	mux.HandleFunc("POST /v1/admission/attest", s.handleAttest)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	return mux
}

func (s *Server) handleChallenge(w http.ResponseWriter, r *http.Request) {
	nonce := make([]byte, 32)
	if _, err := io.ReadFull(s.nonceRandom, nonce); err != nil {
		writeError(w, http.StatusInternalServerError, "NONCE_GENERATION_FAILED", err.Error())
		return
	}
	nonceHex := hex.EncodeToString(nonce)
	s.nonces.Issue(nonceHex, s.now())
	writeJSON(w, http.StatusOK, map[string]string{"nonce": nonceHex})
}

type AttestRequest struct {
	Identity    string          `json:"identity"`
	Binding     string          `json:"binding"`
	CertPubKey  string          `json:"cert_pubkey,omitempty"`
	Nonce       string          `json:"nonce"`
	Attestation string          `json:"attestation,omitempty"`
	Quote       string          `json:"quote,omitempty"`
	EventLog    json.RawMessage `json:"event_log,omitempty"`
	VMConfig    string          `json:"vm_config,omitempty"`
}

type AttestResponse struct {
	ConsulACLToken string    `json:"consul_acl_token"`
	ExpiresAt      time.Time `json:"expires_at"`
	WorkloadID     string    `json:"workload_id"`
	ComposeHash    string    `json:"compose_hash"`
	PolicyEpoch    int       `json:"policy_epoch"`
}

func (s *Server) handleAttest(w http.ResponseWriter, r *http.Request) {
	var req AttestRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", err.Error())
		return
	}

	binding := firstNonEmpty(req.Binding, req.CertPubKey)
	bindingStatement, err := parseBindingStatement(req.Identity, binding)
	if err != nil {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", err.Error())
		return
	}

	reportData, err := reportDataHex(binding, req.Nonce)
	if err != nil {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", err.Error())
		return
	}
	if !s.nonces.Consume(req.Nonce, s.now()) {
		writeError(w, http.StatusBadRequest, "NONCE_INVALID", "nonce is unknown, expired, or already consumed")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()

	verified, err := s.verifier.Verify(ctx, VerifyRequest{
		Attestation: req.Attestation,
		Quote:       req.Quote,
		EventLog:    rawJSONAsString(req.EventLog),
		VMConfig:    req.VMConfig,
	})
	if err != nil {
		writeError(w, http.StatusBadGateway, "VERIFIER_FAILED", err.Error())
		return
	}
	if !verified.Valid {
		writeError(w, http.StatusBadRequest, "QUOTE_INVALID", verified.Reason)
		return
	}
	if !strings.EqualFold(strings.TrimPrefix(verified.ReportData, "0x"), reportData) {
		writeError(w, http.StatusForbidden, "REPORT_DATA_MISMATCH", "attestation report_data does not match binding statement and nonce")
		return
	}

	workload, err := s.policy.Match(req.Identity, verified.ComposeHash)
	if err != nil {
		writeError(w, http.StatusForbidden, "ADMISSION_REJECTED", err.Error())
		return
	}

	expiresAt := s.now().Add(s.tokenTTL)
	token, err := s.issuer.IssueToken(ctx, TokenRequest{
		Description:       fmt.Sprintf("attested %s %s", workload.WorkloadID, verified.ComposeHash),
		ConsulService:     workload.ConsulService,
		ConsulPermissions: workload.ConsulPermissions,
		PeerID:            bindingStatement.PeerID,
		TTL:               s.tokenTTL,
	})
	if err != nil {
		writeError(w, http.StatusBadGateway, "TOKEN_ISSUE_FAILED", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, AttestResponse{
		ConsulACLToken: token,
		ExpiresAt:      expiresAt,
		WorkloadID:     workload.WorkloadID,
		ComposeHash:    verified.ComposeHash,
		PolicyEpoch:    s.policy.PolicyEpoch,
	})
}

func reportDataHex(bindingHex, nonceHex string) (string, error) {
	binding, err := hex.DecodeString(strings.TrimPrefix(strings.ToLower(strings.TrimSpace(bindingHex)), "0x"))
	if err != nil {
		return "", fmt.Errorf("binding must be hex: %w", err)
	}
	if len(binding) == 0 {
		return "", errors.New("binding must not be empty")
	}
	nonce, err := hex.DecodeString(strings.TrimPrefix(strings.ToLower(strings.TrimSpace(nonceHex)), "0x"))
	if err != nil {
		return "", fmt.Errorf("nonce must be hex: %w", err)
	}
	if len(nonce) != 32 {
		return "", fmt.Errorf("nonce must be 32 bytes, got %d", len(nonce))
	}
	h := sha512.New()
	h.Write(binding)
	h.Write(nonce)
	return hex.EncodeToString(h.Sum(nil)), nil
}

func rawJSONAsString(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	return string(raw)
}

type BindingStatement struct {
	Version     int    `json:"version"`
	Identity    string `json:"identity"`
	Cluster     string `json:"cluster,omitempty"`
	PeerID      string `json:"peer_id,omitempty"`
	AppID       string `json:"app_id,omitempty"`
	InstanceID  string `json:"instance_id,omitempty"`
	ComposeHash string `json:"compose_hash,omitempty"`
	IssuedAt    string `json:"issued_at,omitempty"`
}

func parseBindingStatement(identity, bindingHex string) (*BindingStatement, error) {
	if bindingHex == "" {
		return nil, errors.New("binding is required")
	}
	binding, err := hex.DecodeString(strings.TrimPrefix(strings.ToLower(strings.TrimSpace(bindingHex)), "0x"))
	if err != nil {
		return nil, fmt.Errorf("binding must be hex: %w", err)
	}
	if len(binding) == 0 {
		return nil, errors.New("binding must not be empty")
	}
	var statement BindingStatement
	if err := json.Unmarshal(binding, &statement); err != nil {
		return nil, fmt.Errorf("binding must be canonical JSON statement bytes encoded as hex: %w", err)
	}
	if statement.Identity != identity {
		return nil, fmt.Errorf("binding identity %q does not match request identity %q", statement.Identity, identity)
	}
	return &statement, nil
}

type NonceStore struct {
	ttl    time.Duration
	mu     sync.Mutex
	issued map[string]time.Time
}

func NewNonceStore(ttl time.Duration) *NonceStore {
	return &NonceStore{ttl: ttl, issued: make(map[string]time.Time)}
}

func (s *NonceStore) Issue(nonce string, now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.gc(now)
	s.issued[nonce] = now.Add(s.ttl)
}

func (s *NonceStore) Consume(nonce string, now time.Time) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.gc(now)
	expires, ok := s.issued[nonce]
	if !ok || now.After(expires) {
		delete(s.issued, nonce)
		return false
	}
	delete(s.issued, nonce)
	return true
}

func (s *NonceStore) gc(now time.Time) {
	for nonce, expires := range s.issued {
		if now.After(expires) {
			delete(s.issued, nonce)
		}
	}
}

type VerifyRequest struct {
	Attestation string `json:"attestation,omitempty"`
	Quote       string `json:"quote"`
	EventLog    string `json:"event_log"`
	VMConfig    string `json:"vm_config"`
}

type VerifiedQuote struct {
	Valid       bool
	Reason      string
	ComposeHash string
	AppID       string
	ReportData  string
}

type VerifierClient struct {
	URL  string
	HTTP *http.Client
}

func (c *VerifierClient) Verify(ctx context.Context, req VerifyRequest) (*VerifiedQuote, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.URL, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := c.HTTP.Do(httpReq)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return nil, fmt.Errorf("verifier returned HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(respBody)))
	}

	var parsed struct {
		IsValid          bool   `json:"is_valid"`
		QuoteVerified    bool   `json:"quote_verified"`
		EventLogVerified bool   `json:"event_log_verified"`
		Error            string `json:"error"`
		Reason           string `json:"reason"`
		ReportData       string `json:"report_data"`
		AppInfo          struct {
			AppID       string `json:"app_id"`
			ComposeHash string `json:"compose_hash"`
		} `json:"app_info"`
		Details struct {
			QuoteVerified    bool   `json:"quote_verified"`
			EventLogVerified bool   `json:"event_log_verified"`
			ReportData       string `json:"report_data"`
			AppInfo          struct {
				AppID       string `json:"app_id"`
				ComposeHash string `json:"compose_hash"`
			} `json:"app_info"`
		} `json:"details"`
	}
	if err := json.Unmarshal(respBody, &parsed); err != nil {
		return nil, err
	}

	quoteVerified := parsed.QuoteVerified || parsed.Details.QuoteVerified
	eventLogVerified := parsed.EventLogVerified || parsed.Details.EventLogVerified
	reportData := firstNonEmpty(parsed.ReportData, parsed.Details.ReportData)
	appID := firstNonEmpty(parsed.AppInfo.AppID, parsed.Details.AppInfo.AppID)
	composeHashRaw := firstNonEmpty(parsed.AppInfo.ComposeHash, parsed.Details.AppInfo.ComposeHash)

	valid := parsed.IsValid && quoteVerified && eventLogVerified
	reason := firstNonEmpty(parsed.Reason, parsed.Error)
	if !valid && reason == "" {
		reason = "verifier rejected quote"
	}
	if valid && composeHashRaw == "" {
		return nil, errors.New("verifier response missing app_info.compose_hash")
	}
	if valid && reportData == "" {
		return nil, errors.New("verifier response missing report_data")
	}
	composeHash := ""
	if composeHashRaw != "" {
		composeHash, err = normalizeComposeHash(composeHashRaw)
		if err != nil {
			return nil, fmt.Errorf("verifier app_info.compose_hash: %w", err)
		}
	}
	return &VerifiedQuote{
		Valid:       valid,
		Reason:      reason,
		ComposeHash: composeHash,
		AppID:       appID,
		ReportData:  strings.TrimPrefix(strings.ToLower(strings.TrimSpace(reportData)), "0x"),
	}, nil
}

type TokenRequest struct {
	Description       string
	ConsulService     string
	ConsulPermissions ConsulPermissions
	PeerID            string
	TTL               time.Duration
}

type TokenIssuer interface {
	IssueToken(context.Context, TokenRequest) (string, error)
}

type ConsulIssuer struct {
	BaseURL         string
	ManagementToken string
	HTTP            *http.Client
}

func (i *ConsulIssuer) IssueToken(ctx context.Context, req TokenRequest) (string, error) {
	if req.ConsulService == "" {
		return "", errors.New("consul service is required")
	}
	payload := map[string]any{
		"Description":   req.Description,
		"ExpirationTTL": fmt.Sprintf("%ds", int(req.TTL.Seconds())),
		"ServiceIdentities": []map[string]string{
			{"ServiceName": req.ConsulService},
		},
	}
	rules, err := consulACLRules(req.ConsulPermissions, req.PeerID)
	if err != nil {
		return "", err
	}
	if rules != "" {
		policyName, err := i.EnsurePolicy(ctx, "attested-workload-"+shortSHA256(rules, 16), "Additional permissions for attested workloads", rules)
		if err != nil {
			return "", err
		}
		payload["Policies"] = []map[string]string{
			{"Name": policyName},
		}
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPut, i.BaseURL+"/v1/acl/token", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("X-Consul-Token", i.ManagementToken)

	resp, err := i.HTTP.Do(httpReq)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", err
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return "", fmt.Errorf("consul returned HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(respBody)))
	}
	var parsed struct {
		SecretID string `json:"SecretID"`
	}
	if err := json.Unmarshal(respBody, &parsed); err != nil {
		return "", err
	}
	if parsed.SecretID == "" {
		return "", errors.New("consul token response missing SecretID")
	}
	return parsed.SecretID, nil
}

func (i *ConsulIssuer) EnsurePolicy(ctx context.Context, name, description, rules string) (string, error) {
	existing, err := i.readPolicyByName(ctx, name)
	if err == nil {
		if existing.Rules != rules {
			return "", fmt.Errorf("consul ACL policy %q exists with different rules", name)
		}
		return existing.Name, nil
	}
	var httpErr *consulHTTPError
	if !errors.As(err, &httpErr) || httpErr.StatusCode != http.StatusNotFound {
		return "", err
	}

	payload := map[string]any{
		"Name":        name,
		"Description": description,
		"Rules":       rules,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPut, i.BaseURL+"/v1/acl/policy", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("X-Consul-Token", i.ManagementToken)
	resp, err := i.HTTP.Do(httpReq)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", err
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return "", &consulHTTPError{StatusCode: resp.StatusCode, Body: strings.TrimSpace(string(respBody))}
	}
	var created consulPolicy
	if err := json.Unmarshal(respBody, &created); err != nil {
		return "", err
	}
	if created.Name == "" {
		return "", errors.New("consul policy response missing Name")
	}
	return created.Name, nil
}

type consulPolicy struct {
	Name  string `json:"Name"`
	Rules string `json:"Rules"`
}

func (i *ConsulIssuer) readPolicyByName(ctx context.Context, name string) (*consulPolicy, error) {
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodGet, i.BaseURL+"/v1/acl/policy/name/"+url.PathEscape(name), nil)
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("X-Consul-Token", i.ManagementToken)
	resp, err := i.HTTP.Do(httpReq)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return nil, &consulHTTPError{StatusCode: resp.StatusCode, Body: strings.TrimSpace(string(respBody))}
	}
	var policy consulPolicy
	if err := json.Unmarshal(respBody, &policy); err != nil {
		return nil, err
	}
	if policy.Name == "" {
		return nil, errors.New("consul policy response missing Name")
	}
	return &policy, nil
}

type consulHTTPError struct {
	StatusCode int
	Body       string
}

func (e *consulHTTPError) Error() string {
	return fmt.Sprintf("consul returned HTTP %d: %s", e.StatusCode, e.Body)
}

func consulACLRules(p ConsulPermissions, peerID string) (string, error) {
	var b strings.Builder
	if p.AgentReadSelf {
		peerID = strings.TrimSpace(peerID)
		if err := validateConsulAgentName(peerID); err != nil {
			return "", fmt.Errorf("agent_read_self requires attested peer_id: %w", err)
		}
		fmt.Fprintf(&b, "agent %q {\n  policy = \"read\"\n}\n", peerID)
	}
	for _, prefix := range p.KeyPrefixes {
		prefix = strings.Trim(prefix, "/")
		if prefix == "" {
			continue
		}
		fmt.Fprintf(&b, "key_prefix %q {\n  policy = \"write\"\n}\n", prefix)
	}
	if p.SessionWrite {
		b.WriteString("session_prefix \"\" {\n  policy = \"write\"\n}\n")
	}
	return b.String(), nil
}

func validateConsulAgentName(name string) error {
	if name == "" {
		return errors.New("peer_id is empty")
	}
	for _, r := range name {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_' || r == '.' {
			continue
		}
		return fmt.Errorf("peer_id %q contains unsupported character %q", name, r)
	}
	return nil
}

func shortSHA256(s string, hexChars int) string {
	sum := sha256.Sum256([]byte(s))
	out := hex.EncodeToString(sum[:])
	if hexChars > len(out) {
		return out
	}
	return out[:hexChars]
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, reason string) {
	writeJSON(w, status, map[string]string{"code": code, "reason": reason})
}

func envOr(k, fallback string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return fallback
}

func normalizeHTTPBaseURL(v string) string {
	v = strings.TrimRight(strings.TrimSpace(v), "/")
	if strings.HasPrefix(v, "http://") || strings.HasPrefix(v, "https://") {
		return v
	}
	return "http://" + v
}

func durationEnvOr(k string, fallback time.Duration) time.Duration {
	if v := os.Getenv(k); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			log.Fatalf("%s invalid duration: %v", k, err)
		}
		return d
	}
	return fallback
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}
