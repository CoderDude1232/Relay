package api

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

// signHeaders sets Relay-Sig v2 headers on req for (accountID, deviceID) with key.
func signHeaders(t *testing.T, req *http.Request, key *ecdsa.PrivateKey, cred string, accountID string, deviceID uint32, body []byte, nonce string, tsMs int64) {
	t.Helper()
	ts := strconv.FormatInt(tsMs, 10)
	sum := sha256.Sum256(body)
	canonical := sigAuthCanonical(req.Method, req.URL.RequestURI(), accountID, deviceID, ts, nonce, hex.EncodeToString(sum[:]))
	digest := sha256.Sum256([]byte(canonical))
	sig, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", sigAuthScheme+" "+cred+":"+base64.StdEncoding.EncodeToString(sig))
	req.Header.Set("X-Relay-Timestamp", ts)
	req.Header.Set("X-Relay-Nonce", nonce)
}

// sign attaches fresh Relay-Sig headers for this client's device auth key.
func (c *client) sign(req *http.Request, body []byte) {
	c.env.t.Helper()
	signHeaders(c.env.t, req, c.authKey, c.authUser(), c.accountID, c.deviceID, body, randomNonce(c.env.t), time.Now().UnixMilli())
}

// signedRequest builds a bodyless Relay-Sig request for the client's device auth key.
func (c *client) signedRequest(method, path, nonce string, tsMs int64) *http.Request {
	c.env.t.Helper()
	req, err := http.NewRequest(method, c.env.srv.URL+path, nil)
	if err != nil {
		c.env.t.Fatal(err)
	}
	signHeaders(c.env.t, req, c.authKey, c.authUser(), c.accountID, c.deviceID, nil, nonce, tsMs)
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

func TestParseCredentialRejectsNonCanonicalDeviceIDs(t *testing.T) {
	if _, id, err := parseCredential("acct.12"); err != nil || id != 12 {
		t.Fatalf("canonical id: got %d, %v", id, err)
	}
	for _, bad := range []string{"acct.012", "acct.+1", "acct.", "acct", ".1", "acct.1 ", "acct.4294967296"} {
		if _, _, err := parseCredential(bad); err == nil {
			t.Errorf("parseCredential(%q) accepted a non-canonical credential", bad)
		}
	}
}

func TestParseSigAuthHeadersNonceLength(t *testing.T) {
	now := time.Now()
	mk := func(nonceLen int) *http.Request {
		r := httptest.NewRequest("GET", "/v1/keys/count", nil)
		r.Header.Set("Authorization", sigAuthScheme+" acct.1:"+base64.StdEncoding.EncodeToString([]byte("sig")))
		r.Header.Set("X-Relay-Timestamp", strconv.FormatInt(now.UnixMilli(), 10))
		r.Header.Set("X-Relay-Nonce", base64.StdEncoding.EncodeToString(make([]byte, nonceLen)))
		return r
	}
	for _, n := range []int{0, 8, 15, 65, 128} {
		if _, err := parseSigAuthHeaders(mk(n), now); err == nil {
			t.Errorf("nonce of %d bytes accepted", n)
		}
	}
	for _, n := range []int{16, 32, 64} {
		if _, err := parseSigAuthHeaders(mk(n), now); err != nil {
			t.Errorf("nonce of %d bytes rejected: %v", n, err)
		}
	}
	stale := mk(16)
	stale.Header.Set("X-Relay-Timestamp", strconv.FormatInt(now.Add(-sigAuthSkew-time.Minute).UnixMilli(), 10))
	if _, err := parseSigAuthHeaders(stale, now); err == nil {
		t.Error("stale timestamp accepted")
	}
}

// The signature binds method, full URI (incl. query), identity and body.
func TestSigAuthCanonicalBindsRequest(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	pub := elliptic.Marshal(elliptic.P256(), key.X, key.Y)
	body := []byte(`{"x":1}`)

	req := httptest.NewRequest("PUT", "/v1/keys/abc?device=2", bytes.NewReader(body))
	signHeaders(t, req, key, "acct.1", "acct", 1, body, randomNonce(t), time.Now().UnixMilli())
	h, err := parseSigAuthHeaders(req, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	digest, err := requestBodyDigest(req)
	if err != nil {
		t.Fatal(err)
	}
	// The body is still readable by the handler after hashing.
	if got, _ := io.ReadAll(req.Body); !bytes.Equal(got, body) {
		t.Fatalf("body not rewound: %q", got)
	}
	ok := func(method, uri, acct string, dev uint32, bodyHex string) bool {
		return verifySigAuth(pub, sigAuthCanonical(method, uri, acct, dev, h.timestamp, h.nonce, bodyHex), h.sig) == nil
	}
	if !ok("PUT", "/v1/keys/abc?device=2", "acct", 1, digest) {
		t.Fatal("valid signature rejected")
	}
	other := sha256.Sum256([]byte(`{"x":2}`))
	for name, bad := range map[string]bool{
		"method":  ok("POST", "/v1/keys/abc?device=2", "acct", 1, digest),
		"query":   ok("PUT", "/v1/keys/abc?device=3", "acct", 1, digest),
		"path":    ok("PUT", "/v1/keys/abd?device=2", "acct", 1, digest),
		"account": ok("PUT", "/v1/keys/abc?device=2", "acct2", 1, digest),
		"device":  ok("PUT", "/v1/keys/abc?device=2", "acct", 2, digest),
		"body":    ok("PUT", "/v1/keys/abc?device=2", "acct", 1, hex.EncodeToString(other[:])),
	} {
		if bad {
			t.Errorf("signature still valid after changing the %s", name)
		}
	}
}

func TestRequestBodyDigestDeclared(t *testing.T) {
	body := []byte("hello world")
	sum := sha256.Sum256(body)
	good := hex.EncodeToString(sum[:])

	// Small body + wrong declared digest → rejected up front.
	r := httptest.NewRequest("PUT", "/x", bytes.NewReader(body))
	r.Header.Set(bodyHashHeader, strings.Repeat("0", 64))
	if _, err := requestBodyDigest(r); err == nil {
		t.Fatal("mismatched declared digest accepted")
	}

	// Streamed (unknown length) body: declared digest is used, mismatch fails at EOF.
	r = httptest.NewRequest("PUT", "/x", io.NopCloser(bytes.NewReader(body)))
	r.ContentLength = -1
	r.Header.Set(bodyHashHeader, strings.Repeat("0", 64))
	d, err := requestBodyDigest(r)
	if err != nil || d != strings.Repeat("0", 64) {
		t.Fatalf("declared digest not used: %q %v", d, err)
	}
	if _, err := io.ReadAll(r.Body); err != errBodyHashMismatch {
		t.Fatalf("streamed mismatch not detected: %v", err)
	}

	r = httptest.NewRequest("PUT", "/x", io.NopCloser(bytes.NewReader(body)))
	r.ContentLength = -1
	r.Header.Set(bodyHashHeader, good)
	if _, err := requestBodyDigest(r); err != nil {
		t.Fatal(err)
	}
	if got, err := io.ReadAll(r.Body); err != nil || !bytes.Equal(got, body) {
		t.Fatalf("streamed matching body: %q %v", got, err)
	}
}

func TestSignatureAuth(t *testing.T) {
	env := newTestEnv(t)
	c := env.registerAs(uniqueUsername("siguser"), "password123")

	const path = "/v1/keys/count"
	now := time.Now().UnixMilli()

	// A valid signature authenticates with no Basic credentials.
	do := func(req *http.Request) int {
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if got := do(c.signedRequest("GET", path, randomNonce(t), now)); got != http.StatusOK {
		t.Fatalf("valid signature: got %d, want 200", got)
	}

	// A tampered signature is rejected.
	bad := c.signedRequest("GET", path, randomNonce(t), now)
	bad.Header.Set("Authorization", sigAuthScheme+" "+c.authUser()+":"+base64.StdEncoding.EncodeToString([]byte("not-a-real-signature")))
	if got := do(bad); got != http.StatusUnauthorized {
		t.Fatalf("tampered signature: got %d, want 401", got)
	}

	// Replaying the exact same signed request (same nonce) is rejected.
	nonce := randomNonce(t)
	if got := do(c.signedRequest("GET", path, nonce, time.Now().UnixMilli())); got != http.StatusOK {
		t.Fatalf("first use of nonce: got %d, want 200", got)
	}
	if got := do(c.signedRequest("GET", path, nonce, time.Now().UnixMilli())); got != http.StatusUnauthorized {
		t.Fatalf("replayed nonce: got %d, want 401", got)
	}

	// A stale timestamp (outside the skew window) is rejected.
	if got := do(c.signedRequest("GET", path, randomNonce(t), now-int64((sigAuthSkew+time.Minute)/time.Millisecond))); got != http.StatusUnauthorized {
		t.Fatalf("stale timestamp: got %d, want 401", got)
	}

	// Once the device has an auth key, HTTP Basic is refused.
	basic, _ := http.NewRequest("GET", env.srv.URL+path, nil)
	basic.SetBasicAuth(c.authUser(), c.password)
	if got := do(basic); got != http.StatusUnauthorized {
		t.Fatalf("basic after auth key: got %d, want 401", got)
	}
}
