package api

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"net/http"
	"strconv"
	"testing"
	"time"
)

// signedRequest builds a Relay-Sig request for the client's device auth key.
func (c *client) signedRequest(method, path, nonce string, tsMs int64) *http.Request {
	c.env.t.Helper()
	ts := strconv.FormatInt(tsMs, 10)
	digest := sha256.Sum256([]byte(sigAuthCanonical(method, path, ts, nonce)))
	sig, err := ecdsa.SignASN1(rand.Reader, c.authKey, digest[:])
	if err != nil {
		c.env.t.Fatal(err)
	}
	req, err := http.NewRequest(method, c.env.srv.URL+path, nil)
	if err != nil {
		c.env.t.Fatal(err)
	}
	req.Header.Set("Authorization", sigAuthScheme+" "+c.authUser()+":"+base64.StdEncoding.EncodeToString(sig))
	req.Header.Set("X-Relay-Timestamp", ts)
	req.Header.Set("X-Relay-Nonce", nonce)
	return req
}

func randomNonce(t *testing.T) string {
	t.Helper()
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(b)
}

func TestSignatureAuth(t *testing.T) {
	env := newTestEnv(t)
	c := env.register("siguser", "password123")

	const path = "/v1/keys/count"
	now := time.Now().UnixMilli()

	// A valid signature authenticates with no Basic credentials.
	req := c.signedRequest("GET", path, randomNonce(t), now)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("valid signature: got %d, want 200", resp.StatusCode)
	}

	// A tampered signature is rejected.
	bad := c.signedRequest("GET", path, randomNonce(t), now)
	bad.Header.Set("Authorization", sigAuthScheme+" "+c.authUser()+":"+base64.StdEncoding.EncodeToString([]byte("not-a-real-signature")))
	resp, err = http.DefaultClient.Do(bad)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("tampered signature: got %d, want 401", resp.StatusCode)
	}

	// Replaying the exact same signed request (same nonce) is rejected.
	nonce := randomNonce(t)
	first := c.signedRequest("GET", path, nonce, time.Now().UnixMilli())
	resp, err = http.DefaultClient.Do(first)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("first use of nonce: got %d, want 200", resp.StatusCode)
	}
	replay := c.signedRequest("GET", path, nonce, time.Now().UnixMilli())
	resp, err = http.DefaultClient.Do(replay)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("replayed nonce: got %d, want 401", resp.StatusCode)
	}

	// A stale timestamp (outside the skew window) is rejected.
	stale := c.signedRequest("GET", path, randomNonce(t), now-int64((sigAuthSkew+time.Minute)/time.Millisecond))
	resp, err = http.DefaultClient.Do(stale)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("stale timestamp: got %d, want 401", resp.StatusCode)
	}
}
