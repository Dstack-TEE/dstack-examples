package main

import (
	"bytes"
	"crypto/sha512"
	"encoding/hex"
	"testing"
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
