package api

import (
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/relayapp/relay-server/internal/limitkey"
	"github.com/relayapp/relay-server/internal/store"
)

func TestTokenBucketLimiter(t *testing.T) {
	l := newTokenBucketLimiter(3, time.Hour)
	for i := 0; i < 3; i++ {
		if !l.allow("k") {
			t.Fatalf("call %d denied within burst", i)
		}
	}
	if l.allow("k") {
		t.Fatal("call beyond burst allowed")
	}
	if !l.exhausted("k") {
		t.Fatal("exhausted() = false on an empty bucket")
	}
	if !l.allow("other") {
		t.Fatal("keys are not independent")
	}
	// Byte-budget style: consume may overdraw; the key then stays exhausted.
	b := newTokenBucketLimiter(100, time.Hour)
	b.consume("u", 250)
	if !b.exhausted("u") {
		t.Fatal("overdrawn bucket not exhausted")
	}
}

func TestLimiterMapsHoldNoRawKeys(t *testing.T) {
	sw := newSlidingWindowLimiter(5, time.Minute)
	tb := newTokenBucketLimiter(5, time.Minute)
	raw := "203.0.113.7"
	sw.allow(raw)
	tb.allow("acct-a:acct-b")
	for k := range sw.windows {
		if strings.Contains(k, raw) {
			t.Fatalf("sliding-window limiter stored raw key %q", k)
		}
		if k != limitkey.Hash(raw) {
			t.Fatal("sliding-window key is not the salted hash")
		}
	}
	for k := range tb.buckets {
		if strings.Contains(k, "acct-a") {
			t.Fatalf("token-bucket limiter stored raw key %q", k)
		}
	}
}

// TestAuthFailureThrottle drives failures that are rejected before any store
// access (malformed device id), so it needs no database: after the per-IP
// budget is spent, the same /64 gets 429 while another source is unaffected.
func TestAuthFailureThrottle(t *testing.T) {
	s := New(nil, nil, nil, "", "")
	h := s.bootstrapAuth(func(w http.ResponseWriter, r *http.Request, _ *store.Device) {
		t.Fatal("handler reached without valid credentials")
	})
	do := func(remote string) int {
		req := httptest.NewRequest("PUT", "/v1/devices/auth-key", nil)
		req.RemoteAddr = remote
		req.SetBasicAuth("acct.notanumber", "pw")
		rec := httptest.NewRecorder()
		h(rec, req)
		return rec.Code
	}
	for i := 0; i < 50; i++ {
		// Rotate the low 64 bits: same /64, so the same bucket.
		if code := do("[2001:db8:77:1::" + strconv.Itoa(i+1) + "]:5555"); code != http.StatusUnauthorized {
			t.Fatalf("attempt %d: got %d, want 401", i, code)
		}
	}
	if code := do("[2001:db8:77:1::ffff]:1"); code != http.StatusTooManyRequests {
		t.Fatalf("after budget: got %d, want 429", code)
	}
	if code := do("198.51.100.20:1"); code != http.StatusUnauthorized {
		t.Fatalf("unrelated source: got %d, want 401", code)
	}
}

// TestBasicRefusedOutsideBootstrap: every route but the auth-key bootstrap
// refuses HTTP Basic outright, before any store access (the server here has
// no store, so reaching one would panic).
func TestBasicRefusedOutsideBootstrap(t *testing.T) {
	for _, l := range allLimiters {
		l.reset()
	}
	s := New(nil, nil, nil, "", "")
	h := s.auth(func(w http.ResponseWriter, r *http.Request, _ *store.Device) {
		t.Fatal("handler reached with HTTP Basic")
	})
	req := httptest.NewRequest("GET", "/v1/keys/count", nil)
	req.RemoteAddr = "198.51.100.30:1"
	req.SetBasicAuth("acct.1", "some-device-password")
	rec := httptest.NewRecorder()
	h(rec, req)
	if rec.Code != http.StatusUnauthorized || !strings.Contains(rec.Body.String(), "Relay-Sig") {
		t.Fatalf("Basic on a non-bootstrap route: got %d %s", rec.Code, rec.Body.String())
	}
}
