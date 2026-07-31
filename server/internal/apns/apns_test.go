package apns

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Writes a throwaway P-256 key in PKCS#8 PEM (same shape as an Apple .p8).
func writeTestKey(t *testing.T) (string, *ecdsa.PrivateKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	path := filepath.Join(t.TempDir(), "AuthKey_TEST12345.p8")
	if err := os.WriteFile(path, pemBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	return path, key
}

func TestAuthTokenIsValidES256(t *testing.T) {
	path, key := writeTestKey(t)
	p, err := New(path, "KEY123ABCD", "TEAM123456", "com.example.app", false)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if p.host != hostSandbox {
		t.Fatalf("expected sandbox host, got %s", p.host)
	}

	token, err := p.authToken()
	if err != nil {
		t.Fatalf("authToken: %v", err)
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("expected 3 JWT segments, got %d", len(parts))
	}

	// Header carries alg + kid.
	header, _ := base64.RawURLEncoding.DecodeString(parts[0])
	if !strings.Contains(string(header), `"ES256"`) || !strings.Contains(string(header), "KEY123ABCD") {
		t.Fatalf("unexpected header: %s", header)
	}

	// Signature verifies against the public key over "header.claims".
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		t.Fatalf("bad signature encoding: %v len=%d", err, len(sig))
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r := new(big.Int).SetBytes(sig[:32])
	s := new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(&key.PublicKey, digest[:], r, s) {
		t.Fatal("signature did not verify")
	}

	// Cached within the refresh window.
	if again, _ := p.authToken(); again != token {
		t.Fatal("expected cached token")
	}
}

func TestProductionHost(t *testing.T) {
	path, _ := writeTestKey(t)
	p, err := New(path, "K", "T", "topic", true)
	if err != nil {
		t.Fatal(err)
	}
	if p.host != hostProduction {
		t.Fatalf("expected production host, got %s", p.host)
	}
}
