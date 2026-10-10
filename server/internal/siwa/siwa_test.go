package siwa

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeApple is a stand-in for appleid.apple.com's /auth/token and
// /auth/revoke that verifies the client-secret JWT against the public key.
type fakeApple struct {
	t        *testing.T
	pub      *ecdsa.PublicKey
	code     string
	mu       sync.Mutex
	revoked  []string
	failCode bool
}

func (f *fakeApple) checkSecret(secret, clientID string) {
	f.t.Helper()
	parts := strings.Split(secret, ".")
	if len(parts) != 3 {
		f.t.Fatalf("client secret is not a JWT")
	}
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if len(sig) != 64 || !ecdsa.Verify(f.pub, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		f.t.Fatal("client secret signature invalid")
	}
	var header map[string]string
	var claims map[string]any
	h, _ := base64.RawURLEncoding.DecodeString(parts[0])
	c, _ := base64.RawURLEncoding.DecodeString(parts[1])
	json.Unmarshal(h, &header)
	json.Unmarshal(c, &claims)
	if header["alg"] != "ES256" || header["kid"] != "KEY123" {
		f.t.Fatalf("header %v", header)
	}
	if claims["iss"] != "TEAM123" || claims["sub"] != clientID || claims["aud"] != "https://appleid.apple.com" {
		f.t.Fatalf("claims %v", claims)
	}
	iat, exp := claims["iat"].(float64), claims["exp"].(float64)
	if exp <= iat || exp-iat > 15777000 {
		f.t.Fatalf("bad iat/exp %v %v", iat, exp)
	}
}

func (f *fakeApple) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /auth/token", func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		f.checkSecret(r.PostForm.Get("client_secret"), r.PostForm.Get("client_id"))
		if r.PostForm.Get("grant_type") != "authorization_code" || r.PostForm.Get("code") != f.code || f.failCode {
			w.WriteHeader(http.StatusBadRequest)
			w.Write([]byte(`{"error":"invalid_grant"}`))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"access_token":"at-1","refresh_token":"rt-1","token_type":"Bearer","expires_in":3600}`))
	})
	mux.HandleFunc("POST /auth/revoke", func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		f.checkSecret(r.PostForm.Get("client_secret"), r.PostForm.Get("client_id"))
		f.mu.Lock()
		f.revoked = append(f.revoked, r.PostForm.Get("token_type_hint")+":"+r.PostForm.Get("token"))
		f.mu.Unlock()
	})
	return mux
}

// newFake returns a Revoker wired to a fake Apple server that accepts only code.
func newFake(t *testing.T, code string) (*Revoker, *fakeApple) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	fake := &fakeApple{t: t, pub: &key.PublicKey, code: code}
	srv := httptest.NewServer(fake.handler())
	t.Cleanup(srv.Close)
	r, err := NewWithKey(key, "KEY123", "TEAM123", "app.relaymsg")
	if err != nil {
		t.Fatal(err)
	}
	r.HTTP = srv.Client()
	r.TokenURL = srv.URL + "/auth/token"
	r.RevokeURL = srv.URL + "/auth/revoke"
	return r, fake
}

func TestRevokeAuthorizationCode(t *testing.T) {
	r, fake := newFake(t, "good-code")
	if err := r.RevokeAuthorizationCode(context.Background(), "good-code"); err != nil {
		t.Fatal(err)
	}
	if len(fake.revoked) != 1 || fake.revoked[0] != "refresh_token:rt-1" {
		t.Fatalf("revoked %v, want the refresh token", fake.revoked)
	}

	err := r.RevokeAuthorizationCode(context.Background(), "secret-bad-code")
	if err == nil || !strings.Contains(err.Error(), "invalid_grant") {
		t.Fatalf("bad code: %v", err)
	}
	if strings.Contains(err.Error(), "secret-bad-code") {
		t.Fatal("error leaks the authorization code")
	}
	if len(fake.revoked) != 1 {
		t.Fatal("revoke called after a failed exchange")
	}

	// A context deadline bounds the whole operation.
	ctx, cancel := context.WithTimeout(context.Background(), time.Nanosecond)
	defer cancel()
	time.Sleep(time.Millisecond)
	if err := r.RevokeAuthorizationCode(ctx, "good-code"); err == nil {
		t.Fatal("expired context did not fail")
	}
}

func TestNewLoadsP8(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "AuthKey_KEY123.p8")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := New(path, "KEY123", "TEAM123", "app.relaymsg"); err != nil {
		t.Fatal(err)
	}
	if _, err := New(path, "", "TEAM123", "app.relaymsg"); err == nil {
		t.Fatal("missing key id accepted")
	}
	if _, err := New(filepath.Join(t.TempDir(), "missing.p8"), "KEY123", "TEAM123", "app.relaymsg"); err == nil {
		t.Fatal("missing key file accepted")
	}
}
