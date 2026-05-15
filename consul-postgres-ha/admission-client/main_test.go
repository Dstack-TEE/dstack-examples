package main

import (
	"bytes"
	"context"
	"crypto/sha512"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	dstack "github.com/Dstack-TEE/dstack/sdk/go/dstack"
)

func TestReportDataBindsStatementAndNonce(t *testing.T) {
	statement := []byte(`{"identity":"spiffe://demo/webdemo"}`)
	nonce := "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
	got, err := reportData(statement, nonce)
	if err != nil {
		t.Fatal(err)
	}
	nonceBytes, _ := hex.DecodeString(nonce)
	h := sha512.New()
	h.Write(statement)
	h.Write(nonceBytes)
	if !bytes.Equal(got, h.Sum(nil)) {
		t.Fatalf("report data mismatch")
	}
}

func TestReportDataRejectsWrongNonceSize(t *testing.T) {
	_, err := reportData([]byte("{}"), "abcd")
	if err == nil {
		t.Fatal("expected error")
	}
}

func TestSplitCSV(t *testing.T) {
	got := splitCSV(" http://a, ,http://b ")
	if len(got) != 2 || got[0] != "http://a" || got[1] != "http://b" {
		t.Fatalf("bad split: %#v", got)
	}
}

func TestAdmitRetriesTransientBrokerFailure(t *testing.T) {
	prevRetry := admissionRetryInterval
	admissionRetryInterval = 10 * time.Millisecond
	t.Cleanup(func() { admissionRetryInterval = prevRetry })

	var challenges atomic.Int32
	broker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/admission/challenge":
			if challenges.Add(1) == 1 {
				http.Error(w, "not ready", http.StatusBadGateway)
				return
			}
			w.Write([]byte(`{"nonce":"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"}`))
		case "/v1/admission/attest":
			w.Write([]byte(`{"consul_acl_token":"issued-token"}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(broker.Close)

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	token, err := admit(ctx, broker.Client(), fakeQuoteClient{}, []string{broker.URL}, "spiffe://demo/webdemo", []byte(`{"ok":true}`), "{}")
	if err != nil {
		t.Fatal(err)
	}
	if token != "issued-token" {
		t.Fatalf("wrong token: %q", token)
	}
	if got := challenges.Load(); got != 2 {
		t.Fatalf("expected one retry, got %d challenge requests", got)
	}
}

func TestAdmitDoesNotRetryPermanentBrokerRejection(t *testing.T) {
	prevRetry := admissionRetryInterval
	admissionRetryInterval = 10 * time.Millisecond
	t.Cleanup(func() { admissionRetryInterval = prevRetry })

	var challenges atomic.Int32
	broker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		challenges.Add(1)
		http.Error(w, "admission rejected", http.StatusForbidden)
	}))
	t.Cleanup(broker.Close)

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, err := admit(ctx, broker.Client(), fakeQuoteClient{}, []string{broker.URL}, "spiffe://demo/webdemo", []byte(`{"ok":true}`), "{}")
	if err == nil {
		t.Fatal("expected error")
	}
	if got := challenges.Load(); got != 1 {
		t.Fatalf("permanent rejection should not be retried, got %d challenge requests", got)
	}
}

type fakeQuoteClient struct{}

func (fakeQuoteClient) Attest(context.Context, []byte) (*dstack.AttestResponse, error) {
	return &dstack.AttestResponse{Attestation: []byte("attestation")}, nil
}
