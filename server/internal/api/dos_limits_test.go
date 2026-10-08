package api

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/relayapp/relay-server/internal/blob"
)

// The unauthenticated provisioning poll and legacy link claim are limited per
// source IP before any store access (the server here has no store).
func TestUnauthenticatedLinkingIPLimits(t *testing.T) {
	for _, l := range allLimiters {
		l.reset()
	}
	s := New(nil, nil, nil, "", "")
	h := s.Handler()
	do := func(method, path, remote string) int {
		req := httptest.NewRequest(method, path, strings.NewReader(`{}`))
		req.RemoteAddr = remote
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec.Code
	}
	const ip = "203.0.113.50"
	for !provisioningPollIPLimiter.exhausted(ip) {
		provisioningPollIPLimiter.allow(ip)
	}
	if got := do("GET", "/v1/provisioning-sessions/abc", ip+":1"); got != http.StatusTooManyRequests {
		t.Fatalf("provisioning poll over budget: got %d, want 429", got)
	}
	for !linkClaimIPLimiter.exhausted(ip) {
		linkClaimIPLimiter.allow(ip)
	}
	if got := do("POST", "/v1/devices/link-claims", ip+":1"); got != http.StatusTooManyRequests {
		t.Fatalf("link claim over budget: got %d, want 429", got)
	}
	// Another source is unaffected (400: the empty body fails validation
	// before the store is touched).
	if got := do("POST", "/v1/devices/link-claims", "198.51.100.9:1"); got != http.StatusBadRequest {
		t.Fatalf("other source: got %d, want 400", got)
	}
}

// Once the blob directory reaches the disk watermark, uploads get 507 before
// any reservation is consumed.
func TestAttachmentDiskWatermark(t *testing.T) {
	for _, l := range allLimiters {
		l.reset()
	}
	blobs, err := blob.Open(filepath.Join(t.TempDir(), "blobs"), 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	s := New(nil, nil, blobs, "", "")
	s.SetAttachmentDiskCap(1000)
	id, _ := blobs.NewID()
	if err := blobs.Reserve(id); err != nil {
		t.Fatal(err)
	}
	upload := func() int {
		req := httptest.NewRequest("PUT", "/v1/attachments/"+id, bytes.NewReader(make([]byte, 600)))
		rec := httptest.NewRecorder()
		s.Handler().ServeHTTP(rec, req)
		return rec.Code
	}
	filler, _ := blobs.NewID()
	if err := blobs.Put(filler, bytes.NewReader(make([]byte, 1000))); err != nil {
		t.Fatal(err)
	}
	if got := upload(); got != http.StatusInsufficientStorage {
		t.Fatalf("upload at the watermark: got %d, want 507", got)
	}
	// The reservation survived: with room again the same id uploads.
	s.SetAttachmentDiskCap(0)
	if got := upload(); got != http.StatusNoContent {
		t.Fatalf("upload after the watermark cleared: got %d, want 204", got)
	}
}

// TestPerAccountDailyCaps covers the contact-invite and username-change caps
// and the allocation-side disk watermark.
func TestPerAccountDailyCaps(t *testing.T) {
	env := newTestEnv(t)
	c := env.register("caps", "password-caps")
	for i := 0; i < 50; i++ {
		env.doJSON("POST", "/v1/contact-invites", c.authUser(), c.password, nil, http.StatusCreated, nil)
	}
	env.doJSON("POST", "/v1/contact-invites", c.authUser(), c.password, nil, http.StatusTooManyRequests, nil)

	// A "taken" answer spends nothing; five completed changes do.
	other := env.register("caps-other", "password-other")
	env.doJSON("PUT", "/v1/accounts/me/username", c.authUser(), c.password,
		map[string]string{"username": other.username}, http.StatusConflict, nil)
	for i := 0; i < 5; i++ {
		env.doJSON("PUT", "/v1/accounts/me/username", c.authUser(), c.password,
			map[string]string{"username": uniqueUsername("renamed")}, http.StatusNoContent, nil)
	}
	env.doJSON("PUT", "/v1/accounts/me/username", c.authUser(), c.password,
		map[string]string{"username": uniqueUsername("renamed")}, http.StatusTooManyRequests, nil)

	env.api.SetAttachmentDiskCap(1)
	filler, _ := env.api.blobs.NewID()
	if err := env.api.blobs.Put(filler, bytes.NewReader([]byte("x"))); err != nil {
		t.Fatal(err)
	}
	env.doJSON("POST", "/v1/attachments", c.authUser(), c.password, nil, http.StatusInsufficientStorage, nil)
}

// A WebSocket that keeps sending garbage is closed after maxMalformedFrames.
func TestWebSocketClosesOnMalformedFrames(t *testing.T) {
	env := newTestEnv(t)
	c := env.register("wsjunk", "password-junk")
	ws := c.connectWS()
	for i := 0; i < maxMalformedFrames; i++ {
		ws.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
		if err := ws.conn.WriteMessage(websocket.BinaryMessage, []byte{0xff, 0xff, 0xff}); err != nil {
			t.Fatalf("write %d: %v", i, err)
		}
	}
	ws.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		_, _, err := ws.conn.ReadMessage()
		if err == nil {
			continue
		}
		if !websocket.IsCloseError(err, websocket.ClosePolicyViolation) {
			t.Fatalf("socket not closed with 1008 after garbage: %v", err)
		}
		return
	}
}
