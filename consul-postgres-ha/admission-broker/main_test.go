package main

import (
	"bytes"
	"context"
	"crypto/sha512"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

const testHash = "1434154969cb663afc5a73393b84cc31a1319ab6c65c9766fadd0c86bb59ef37"

func TestPolicyMatchAllowsSharedComposeHashPerIdentity(t *testing.T) {
	policy := mustPolicy(t, `{
	  "cluster": "demo",
	  "policy_epoch": 1,
	  "workloads": [
	    {
	      "workload_id": "demo/worker/0/webdemo",
	      "identity": "spiffe://demo/webdemo",
	      "consul_service": "webdemo",
	      "allowed_compose_hashes": ["`+testHash+`"]
	    },
	    {
	      "workload_id": "demo/worker/0/postgres",
	      "identity": "spiffe://demo/postgres",
	      "consul_service": "demo",
	      "allowed_compose_hashes": ["0x`+testHash+`"]
	    }
	  ]
	}`)

	web, err := policy.Match("spiffe://demo/webdemo", testHash)
	if err != nil {
		t.Fatal(err)
	}
	if web.WorkloadID != "demo/worker/0/webdemo" {
		t.Fatalf("wrong web workload: %s", web.WorkloadID)
	}

	pg, err := policy.Match("spiffe://demo/postgres", testHash)
	if err != nil {
		t.Fatal(err)
	}
	if pg.WorkloadID != "demo/worker/0/postgres" {
		t.Fatalf("wrong postgres workload: %s", pg.WorkloadID)
	}
}

func TestPolicyRejectsUnknownComposeHash(t *testing.T) {
	policy := mustPolicy(t, `{
	  "cluster": "demo",
	  "policy_epoch": 1,
	  "workloads": [{
	    "workload_id": "demo/worker/0/webdemo",
	    "identity": "spiffe://demo/webdemo",
	    "consul_service": "webdemo",
	    "allowed_compose_hashes": ["`+testHash+`"]
	  }]
	}`)

	_, err := policy.Match("spiffe://demo/webdemo", "2434154969cb663afc5a73393b84cc31a1319ab6c65c9766fadd0c86bb59ef37")
	if err == nil {
		t.Fatal("expected reject")
	}
}

func TestReportDataHexBindsStatementAndNonce(t *testing.T) {
	binding := "abcd"
	nonce := "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
	got, err := reportDataHex(binding, nonce)
	if err != nil {
		t.Fatal(err)
	}
	bindingBytes, _ := hex.DecodeString(binding)
	nonceBytes, _ := hex.DecodeString(nonce)
	h := sha512.New()
	h.Write(bindingBytes)
	h.Write(nonceBytes)
	want := hex.EncodeToString(h.Sum(nil))
	if got != want {
		t.Fatalf("report_data mismatch\nwant %s\n got %s", want, got)
	}
}

func TestAttestFlow(t *testing.T) {
	var verifierSaw VerifyRequest
	var expectedReportData string
	verifier := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := json.NewDecoder(r.Body).Decode(&verifierSaw); err != nil {
			t.Fatal(err)
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"is_valid": true,
			"details": map[string]any{
				"quote_verified":     true,
				"event_log_verified": true,
				"report_data":        expectedReportData,
				"app_info":           map[string]string{"compose_hash": testHash, "app_id": "app_abc"},
			},
		})
	}))
	defer verifier.Close()

	issuer := &recordingIssuer{token: "secret-token"}
	now := time.Unix(100, 0).UTC()
	s := &Server{
		policy:      mustPolicy(t, `{"cluster":"demo","policy_epoch":7,"workloads":[{"workload_id":"demo/worker/0/webdemo","identity":"spiffe://demo/webdemo","consul_service":"webdemo","allowed_compose_hashes":["`+testHash+`"]}]}`),
		nonces:      NewNonceStore(time.Minute),
		verifier:    &VerifierClient{URL: verifier.URL, HTTP: verifier.Client()},
		issuer:      issuer,
		tokenTTL:    time.Hour,
		now:         func() time.Time { return now },
		nonceRandom: bytes.NewReader(bytes.Repeat([]byte{0x11}, 32)),
	}

	ts := httptest.NewServer(s.routes())
	defer ts.Close()

	challengeResp, err := http.Post(ts.URL+"/v1/admission/challenge", "application/json", nil)
	if err != nil {
		t.Fatal(err)
	}
	var challenge struct {
		Nonce string `json:"nonce"`
	}
	if err := json.NewDecoder(challengeResp.Body).Decode(&challenge); err != nil {
		t.Fatal(err)
	}
	_ = challengeResp.Body.Close()

	statement := `{"identity":"spiffe://demo/webdemo","peer_id":"worker-1"}`
	expectedReportData, err = reportDataHex(hex.EncodeToString([]byte(statement)), challenge.Nonce)
	if err != nil {
		t.Fatal(err)
	}
	body := map[string]any{
		"identity":    "spiffe://demo/webdemo",
		"binding":     hex.EncodeToString([]byte(statement)),
		"nonce":       challenge.Nonce,
		"attestation": "aabbcc",
	}
	buf, _ := json.Marshal(body)
	resp, err := http.Post(ts.URL+"/v1/admission/attest", "application/json", bytes.NewReader(buf))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	var attest AttestResponse
	if err := json.NewDecoder(resp.Body).Decode(&attest); err != nil {
		t.Fatal(err)
	}
	if attest.ConsulACLToken != "secret-token" || attest.WorkloadID != "demo/worker/0/webdemo" || attest.PolicyEpoch != 7 {
		t.Fatalf("bad response: %+v", attest)
	}
	if verifierSaw.Attestation != "aabbcc" {
		t.Fatalf("verifier did not receive attestation: %+v", verifierSaw)
	}
	if issuer.req.ConsulService != "webdemo" {
		t.Fatalf("wrong consul service: %s", issuer.req.ConsulService)
	}
	if issuer.req.PeerID != "worker-1" {
		t.Fatalf("wrong peer id: %s", issuer.req.PeerID)
	}
}

func TestAttestCarriesConsulPermissionsFromPolicy(t *testing.T) {
	var expectedReportData string
	verifier := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"is_valid": true,
			"details": map[string]any{
				"quote_verified":     true,
				"event_log_verified": true,
				"report_data":        expectedReportData,
				"app_info":           map[string]string{"compose_hash": testHash},
			},
		})
	}))
	defer verifier.Close()

	issuer := &recordingIssuer{token: "secret-token"}
	s := &Server{
		policy: mustPolicy(t, `{"cluster":"demo","policy_epoch":1,"workloads":[{
			"workload_id":"demo/worker/0/postgres",
			"identity":"spiffe://demo/postgres",
			"consul_service":"demo",
			"consul_permissions":{"key_prefixes":["/service/demo/"],"session_write":true,"agent_read_self":true},
			"allowed_compose_hashes":["`+testHash+`"]
		}]}`),
		nonces:      NewNonceStore(time.Minute),
		verifier:    &VerifierClient{URL: verifier.URL, HTTP: verifier.Client()},
		issuer:      issuer,
		tokenTTL:    time.Hour,
		now:         func() time.Time { return time.Unix(100, 0).UTC() },
		nonceRandom: bytes.NewReader(bytes.Repeat([]byte{0x33}, 32)),
	}
	ts := httptest.NewServer(s.routes())
	defer ts.Close()

	challengeResp, err := http.Post(ts.URL+"/v1/admission/challenge", "application/json", nil)
	if err != nil {
		t.Fatal(err)
	}
	var challenge struct {
		Nonce string `json:"nonce"`
	}
	if err := json.NewDecoder(challengeResp.Body).Decode(&challenge); err != nil {
		t.Fatal(err)
	}
	_ = challengeResp.Body.Close()

	statement := `{"identity":"spiffe://demo/postgres","peer_id":"worker-1"}`
	expectedReportData, err = reportDataHex(hex.EncodeToString([]byte(statement)), challenge.Nonce)
	if err != nil {
		t.Fatal(err)
	}
	buf, _ := json.Marshal(map[string]any{
		"identity":    "spiffe://demo/postgres",
		"binding":     hex.EncodeToString([]byte(statement)),
		"nonce":       challenge.Nonce,
		"attestation": "aabbcc",
	})
	resp, err := http.Post(ts.URL+"/v1/admission/attest", "application/json", bytes.NewReader(buf))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	if issuer.req.ConsulService != "demo" {
		t.Fatalf("wrong consul service: %s", issuer.req.ConsulService)
	}
	if got := issuer.req.ConsulPermissions.KeyPrefixes; len(got) != 1 || got[0] != "service/demo" {
		t.Fatalf("wrong key prefixes: %#v", got)
	}
	if !issuer.req.ConsulPermissions.SessionWrite {
		t.Fatal("session_write was not carried to issuer")
	}
	if !issuer.req.ConsulPermissions.AgentReadSelf {
		t.Fatal("agent_read_self was not carried to issuer")
	}
	if issuer.req.PeerID != "worker-1" {
		t.Fatalf("wrong peer id: %s", issuer.req.PeerID)
	}
}

func TestConsulACLRules(t *testing.T) {
	got := mustConsulACLRules(t, ConsulPermissions{
		KeyPrefixes:   []string{"service/demo"},
		SessionWrite:  true,
		AgentReadSelf: true,
	}, "worker-1")
	want := "agent \"worker-1\" {\n  policy = \"read\"\n}\nkey_prefix \"service/demo\" {\n  policy = \"write\"\n}\nsession_prefix \"\" {\n  policy = \"write\"\n}\n"
	if got != want {
		t.Fatalf("rules mismatch\nwant:\n%s\ngot:\n%s", want, got)
	}
}

func TestConsulACLRulesRequiresPeerIDForAgentReadSelf(t *testing.T) {
	_, err := consulACLRules(ConsulPermissions{AgentReadSelf: true}, "")
	if err == nil {
		t.Fatal("expected peer_id requirement")
	}
}

func TestConsulIssuerCreatesPolicyForCustomPermissions(t *testing.T) {
	var sawPolicyCreate bool
	var tokenPolicies []map[string]string
	permissions := ConsulPermissions{KeyPrefixes: []string{"service/demo"}, SessionWrite: true, AgentReadSelf: true}
	rules := mustConsulACLRules(t, permissions, "worker-1")
	policyName := "attested-workload-" + shortSHA256(rules, 16)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/v1/acl/policy/name/"+policyName:
			http.NotFound(w, r)
		case r.Method == http.MethodPut && r.URL.Path == "/v1/acl/policy":
			var body struct {
				Name  string `json:"Name"`
				Rules string `json:"Rules"`
			}
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatal(err)
			}
			if body.Name == "" || body.Rules == "" {
				t.Fatalf("bad policy body: %+v", body)
			}
			if body.Name != policyName || body.Rules != rules {
				t.Fatalf("wrong policy body: %+v", body)
			}
			sawPolicyCreate = true
			writeJSON(w, http.StatusOK, map[string]any{"Name": body.Name, "Rules": body.Rules})
		case r.Method == http.MethodPut && r.URL.Path == "/v1/acl/token":
			var body struct {
				Policies []map[string]string `json:"Policies"`
				Rules    string              `json:"Rules"`
			}
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatal(err)
			}
			if body.Rules != "" {
				t.Fatalf("token body must not carry inline rules: %+v", body)
			}
			tokenPolicies = body.Policies
			writeJSON(w, http.StatusOK, map[string]string{"SecretID": "issued-token"})
		default:
			t.Fatalf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
	}))
	defer ts.Close()

	issuer := &ConsulIssuer{BaseURL: ts.URL, ManagementToken: "mgmt", HTTP: ts.Client()}
	token, err := issuer.IssueToken(context.Background(), TokenRequest{
		Description:       "test",
		ConsulService:     "demo",
		ConsulPermissions: permissions,
		PeerID:            "worker-1",
		TTL:               time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	if token != "issued-token" {
		t.Fatalf("wrong token: %s", token)
	}
	if !sawPolicyCreate {
		t.Fatal("policy was not created")
	}
	if len(tokenPolicies) != 1 || tokenPolicies[0]["Name"] == "" {
		t.Fatalf("token did not attach policy: %+v", tokenPolicies)
	}
}

func TestAttestRejectsNonceReplay(t *testing.T) {
	s := &Server{
		policy:      mustPolicy(t, `{"cluster":"demo","policy_epoch":1,"workloads":[{"workload_id":"demo/worker/0/webdemo","identity":"spiffe://demo/webdemo","consul_service":"webdemo","allowed_compose_hashes":["`+testHash+`"]}]}`),
		nonces:      NewNonceStore(time.Minute),
		verifier:    &VerifierClient{URL: "http://127.0.0.1:1", HTTP: http.DefaultClient},
		issuer:      &recordingIssuer{token: "secret-token"},
		tokenTTL:    time.Hour,
		now:         func() time.Time { return time.Unix(100, 0).UTC() },
		nonceRandom: bytes.NewReader(bytes.Repeat([]byte{0x22}, 32)),
	}
	ts := httptest.NewServer(s.routes())
	defer ts.Close()

	challengeResp, err := http.Post(ts.URL+"/v1/admission/challenge", "application/json", nil)
	if err != nil {
		t.Fatal(err)
	}
	var challenge struct {
		Nonce string `json:"nonce"`
	}
	if err := json.NewDecoder(challengeResp.Body).Decode(&challenge); err != nil {
		t.Fatal(err)
	}
	_ = challengeResp.Body.Close()

	if !s.nonces.Consume(challenge.Nonce, time.Unix(100, 0).UTC()) {
		t.Fatal("test failed to consume nonce")
	}

	statement := `{"identity":"spiffe://demo/webdemo"}`
	buf, _ := json.Marshal(map[string]any{
		"identity":    "spiffe://demo/webdemo",
		"binding":     hex.EncodeToString([]byte(statement)),
		"nonce":       challenge.Nonce,
		"attestation": "aabbcc",
	})
	resp, err := http.Post(ts.URL+"/v1/admission/attest", "application/json", bytes.NewReader(buf))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d", resp.StatusCode)
	}
}

type recordingIssuer struct {
	token string
	req   TokenRequest
}

func (i *recordingIssuer) IssueToken(_ context.Context, req TokenRequest) (string, error) {
	i.req = req
	return i.token, nil
}

func mustPolicy(t *testing.T, raw string) *Policy {
	t.Helper()
	p, err := ParsePolicy([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func mustConsulACLRules(t *testing.T, permissions ConsulPermissions, peerID string) string {
	t.Helper()
	rules, err := consulACLRules(permissions, peerID)
	if err != nil {
		t.Fatal(err)
	}
	return rules
}
