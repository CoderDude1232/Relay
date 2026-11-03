package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

func TestParseFallbackHosts(t *testing.T) {
	got := parseFallbackHosts("# comment\nEdge-a1.example.workers.dev\n\nbad host!\nnodot\nedge-b2.example.workers.dev\n")
	want := []string{"edge-a1.example.workers.dev", "edge-b2.example.workers.dev"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestFallbacksEndpointFollowsFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hosts")
	if err := os.WriteFile(path, []byte("edge-a1.example.workers.dev\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	s := &Server{}
	s.SetFallbackHostsFile(path)
	read := func() []string {
		w := httptest.NewRecorder()
		s.handleFallbacks(w, httptest.NewRequest("GET", "/v1/fallbacks", nil), nil)
		var body struct{ Hosts []string }
		if err := json.NewDecoder(w.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		return body.Hosts
	}
	if got := read(); len(got) != 1 || got[0] != "edge-a1.example.workers.dev" {
		t.Fatalf("first read: %v", got)
	}
	// A rotation rewrites the file.
	later := time.Now().Add(2 * time.Second)
	if err := os.WriteFile(path, []byte("edge-c3.example.workers.dev\nedge-a1.example.workers.dev\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	_ = os.Chtimes(path, later, later)
	if got := read(); len(got) != 2 || got[0] != "edge-c3.example.workers.dev" {
		t.Fatalf("after rotation: %v", got)
	}
	// Unconfigured: an empty list, not null.
	w := httptest.NewRecorder()
	(&Server{}).handleFallbacks(w, httptest.NewRequest("GET", "/v1/fallbacks", nil), nil)
	if body := w.Body.String(); body != "{\"hosts\":[]}\n" && body != "{\"hosts\":[]}" {
		t.Fatalf("unconfigured body %q", body)
	}
}

func TestFallbackClientAddrNeedsKey(t *testing.T) {
	t.Cleanup(func() { SetFallbackKey("") })
	r := httptest.NewRequest("GET", "/v1/ping", nil)
	r.RemoteAddr = "203.0.113.9:443"
	r.Header.Set("X-Relay-Client-IP", "198.51.100.7")

	SetFallbackKey("")
	r.Header.Set("X-Relay-Fallback-Key", "")
	if got := forwardedSourceAddr(r); got != r.RemoteAddr {
		t.Fatalf("no key configured: %q", got)
	}
	SetFallbackKey("s3cret")
	r.Header.Set("X-Relay-Fallback-Key", "wrong")
	if got := forwardedSourceAddr(r); got != r.RemoteAddr {
		t.Fatalf("wrong key honoured: %q", got)
	}
	r.Header.Set("X-Relay-Fallback-Key", "s3cret")
	if got := forwardedSourceAddr(r); got != "198.51.100.7" {
		t.Fatalf("right key: %q", got)
	}
}

func TestPing(t *testing.T) {
	w := httptest.NewRecorder()
	(&Server{}).handlePing(w, httptest.NewRequest("GET", "/v1/ping", nil))
	if w.Code != http.StatusNoContent || w.Header().Get("X-Relay") != "1" {
		t.Fatalf("ping: %d %q", w.Code, w.Header().Get("X-Relay"))
	}
}

func TestSpeedTestSizeAndCap(t *testing.T) {
	s := &Server{}
	for _, tc := range []struct {
		query string
		want  int
	}{{"", 256 * 1024}, {"?kb=4", 4096}, {"?kb=99999", maxSpeedTestKB * 1024}} {
		w := httptest.NewRecorder()
		r := httptest.NewRequest("GET", "/v1/speedtest"+tc.query, nil)
		r.RemoteAddr = "192.0.2." + strconv.Itoa(len(tc.query)) + ":1"
		s.handleSpeedTest(w, r)
		if w.Code != 200 || w.Body.Len() != tc.want {
			t.Fatalf("%q: status %d, %d bytes, want %d", tc.query, w.Code, w.Body.Len(), tc.want)
		}
	}
}
