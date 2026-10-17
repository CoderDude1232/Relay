package history

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var testSecret = []byte("0123456789abcdef0123456789abcdef")

func newTestBlobServer(t *testing.T, maxBytes int64) (*BlobServer, *httptest.Server) {
	t.Helper()
	store, err := OpenDir(filepath.Join(t.TempDir(), "blobs"))
	if err != nil {
		t.Fatal(err)
	}
	bs := NewBlobServer(store, testSecret, maxBytes)
	bs.freeBytes = func(string) (int64, error) { return 100 << 30, nil }
	srv := httptest.NewServer(bs.Handler())
	t.Cleanup(srv.Close)
	return bs, srv
}

func send(t *testing.T, srv *httptest.Server, method, path string, body []byte, auth string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, srv.URL+path, bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if auth != "" {
		req.Header.Set(AuthHeader, auth)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func signed(t *testing.T, srv *httptest.Server, method, path string, body []byte) *http.Response {
	t.Helper()
	return send(t, srv, method, path, body, SignRequest(testSecret, method, path, body, time.Now()))
}

func TestBlobServerRoundTrip(t *testing.T) {
	_, srv := newTestBlobServer(t, 0)
	key := BlobKey([]byte("names"), "acct", 1001)
	path := "/v1/blob/" + key
	if got := signed(t, srv, "GET", path, nil).StatusCode; got != http.StatusNotFound {
		t.Fatalf("get before put: %d", got)
	}
	if got := signed(t, srv, "PUT", path, []byte("ciphertext")).StatusCode; got != http.StatusNoContent {
		t.Fatalf("put: %d", got)
	}
	resp := signed(t, srv, "GET", path, nil)
	if body, _ := io.ReadAll(resp.Body); resp.StatusCode != http.StatusOK || string(body) != "ciphertext" {
		t.Fatalf("get: %d %q", resp.StatusCode, body)
	}
	if got := signed(t, srv, "PUT", path, []byte("replaced")).StatusCode; got != http.StatusNoContent {
		t.Fatalf("replace: %d", got)
	}
	if body, _ := io.ReadAll(signed(t, srv, "GET", path, nil).Body); string(body) != "replaced" {
		t.Fatalf("after replace: %q", body)
	}
	if got := signed(t, srv, "PUT", path, nil).StatusCode; got != http.StatusBadRequest {
		t.Fatalf("empty put: %d", got)
	}
	if got := signed(t, srv, "PUT", "/v1/blob/not-a-key", []byte("x")).StatusCode; got != http.StatusBadRequest {
		t.Fatalf("bad key: %d", got)
	}
	if got := signed(t, srv, "DELETE", path, nil).StatusCode; got != http.StatusNoContent {
		t.Fatalf("delete: %d", got)
	}
	if got := signed(t, srv, "DELETE", path, nil).StatusCode; got != http.StatusNoContent {
		t.Fatalf("second delete: %d", got)
	}
	if got := signed(t, srv, "GET", path, nil).StatusCode; got != http.StatusNotFound {
		t.Fatalf("get after delete: %d", got)
	}
}

func TestBlobServerAuth(t *testing.T) {
	_, srv := newTestBlobServer(t, 0)
	path := "/v1/blob/" + strings.Repeat("a", 64)
	body := []byte("data")
	now := time.Now()
	cases := map[string]string{
		"missing":      "",
		"garbage":      "nonsense",
		"wrong secret": SignRequest([]byte("another-secret-another-secret-xx"), "PUT", path, body, now),
		"stale":        SignRequest(testSecret, "PUT", path, body, now.Add(-6*time.Minute)),
		"future":       SignRequest(testSecret, "PUT", path, body, now.Add(6*time.Minute)),
		"other method": SignRequest(testSecret, "DELETE", path, body, now),
		"other path":   SignRequest(testSecret, "PUT", "/v1/blob/"+strings.Repeat("b", 64), body, now),
		"other body":   SignRequest(testSecret, "PUT", path, []byte("tampered"), now),
	}
	for name, auth := range cases {
		if got := send(t, srv, "PUT", path, body, auth).StatusCode; got != http.StatusUnauthorized {
			t.Errorf("%s: got %d, want 401", name, got)
		}
	}
	if got := send(t, srv, "GET", "/health", nil, "").StatusCode; got != http.StatusUnauthorized {
		t.Errorf("unsigned health: %d", got)
	}
	if got := send(t, srv, "PUT", path, body, SignRequest(testSecret, "PUT", path, body, now.Add(-4*time.Minute))).StatusCode; got != http.StatusNoContent {
		t.Errorf("within skew: %d", got)
	}
}

func TestBlobServerLimits(t *testing.T) {
	bs, srv := newTestBlobServer(t, 3<<20)
	key := func(i int64) string { return BlobKey([]byte("names"), "acct", i) }
	big := bytes.Repeat([]byte{1}, MaxSegmentBytes+1)
	if got := signed(t, srv, "PUT", "/v1/blob/"+key(1), big).StatusCode; got != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized: %d", got)
	}
	full := bytes.Repeat([]byte{2}, MaxSegmentBytes)
	if got := signed(t, srv, "PUT", "/v1/blob/"+key(1), full).StatusCode; got != http.StatusNoContent {
		t.Fatalf("max-size segment: %d", got)
	}
	// 2 MiB stored of a 3 MiB cap: another 2 MiB doesn't fit, but replacing
	// the first does.
	if got := signed(t, srv, "PUT", "/v1/blob/"+key(2), full).StatusCode; got != http.StatusInsufficientStorage {
		t.Fatalf("over -max-bytes: %d", got)
	}
	if got := signed(t, srv, "PUT", "/v1/blob/"+key(1), full).StatusCode; got != http.StatusNoContent {
		t.Fatalf("replace within cap: %d", got)
	}
	if bs.store.Usage() != MaxSegmentBytes {
		t.Fatalf("usage %d after a replace", bs.store.Usage())
	}
	// The free-disk floor applies regardless of -max-bytes.
	bs.freeBytes = func(string) (int64, error) { return MinDiskFree + 10, nil }
	if got := signed(t, srv, "PUT", "/v1/blob/"+key(3), []byte("0123456789x")).StatusCode; got != http.StatusInsufficientStorage {
		t.Fatalf("below free-disk floor: %d", got)
	}
}

func TestRemoteClientAndHealth(t *testing.T) {
	bs, srv := newTestBlobServer(t, 0)
	r := NewRemote(srv.URL, testSecret)
	ctx := context.Background()
	if r.Healthy() {
		t.Fatal("healthy before any probe")
	}
	if !r.Probe(ctx) || !r.Healthy() {
		t.Fatal("probe of a healthy historyd failed")
	}
	key := BlobKey([]byte("names"), "acct", 7)
	if err := r.Put(ctx, key, []byte("segment")); err != nil {
		t.Fatal(err)
	}
	if got, err := r.Get(ctx, key); err != nil || string(got) != "segment" {
		t.Fatalf("get: %q %v", got, err)
	}
	list, err := r.List(ctx)
	if err != nil || len(list) != 1 || list[0].Key != key {
		t.Fatalf("list: %+v %v", list, err)
	}
	if err := r.Delete(ctx, key); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Get(ctx, key); err != ErrNotFound {
		t.Fatalf("get after delete: %v", err)
	}
	// A full disk makes the remote unhealthy.
	bs.freeBytes = func(string) (int64, error) { return MinDiskFree, nil }
	if r.Probe(ctx) || r.Healthy() {
		t.Fatal("a full historyd probed healthy")
	}
	// So does a wrong secret.
	bs.freeBytes = func(string) (int64, error) { return 100 << 30, nil }
	if NewRemote(srv.URL, []byte("another-secret-another-secret-xx")).Probe(ctx) {
		t.Fatal("probe with the wrong secret succeeded")
	}
}

func TestDirStoreAndSweep(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "h")
	d, err := OpenDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	s := NewStorage([]byte("names"), d, 0, nil)
	ctx := context.Background()
	live, orphan := s.Key("acct", 1), s.Key("acct", 2)
	for _, k := range []string{live, orphan} {
		if loc, err := s.Put(ctx, k, []byte("x")); err != nil || loc != Local {
			t.Fatalf("put: %v %v", loc, err)
		}
	}
	info, err := os.Stat(filepath.Join(dir, live))
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("blob mode: %v %v", info, err)
	}
	// Too young to sweep.
	s.Sweep(ctx, map[Location]map[string]bool{Local: {live: true}}, time.Hour)
	if _, err := d.Get(orphan); err != nil {
		t.Fatal("swept a blob inside the grace period")
	}
	s.Sweep(ctx, map[Location]map[string]bool{Local: {live: true}}, 0)
	if _, err := d.Get(orphan); err != ErrNotFound {
		t.Fatal("orphan survived the sweep")
	}
	if _, err := d.Get(live); err != nil {
		t.Fatal("sweep removed a live blob")
	}
	// Rows whose blobs are all missing while others exist: refuse.
	s.Sweep(ctx, map[Location]map[string]bool{Local: {s.Key("other", 1): true}}, 0)
	if _, err := d.Get(live); err != nil {
		t.Fatal("sweep deleted everything after an apparent naming-key change")
	}
	// Low local disk and no remote: no space.
	s.SetMinFree(1 << 62)
	if _, err := s.Put(ctx, s.Key("acct", 3), []byte("x")); err != ErrNoSpace {
		t.Fatalf("put with a full disk and no remote: %v", err)
	}
}

func TestStorageFailover(t *testing.T) {
	_, srv := newTestBlobServer(t, 0)
	remote := NewRemote(srv.URL, testSecret)
	ctx := context.Background()
	remote.Probe(ctx)
	local, err := OpenDir(filepath.Join(t.TempDir(), "local"))
	if err != nil {
		t.Fatal(err)
	}
	s := NewStorage([]byte("names"), local, 0, remote)
	k1, k2 := s.Key("acct", 1), s.Key("acct", 2)
	if loc, err := s.Put(ctx, k1, []byte("on local")); err != nil || loc != Local {
		t.Fatalf("roomy local disk: %v %v", loc, err)
	}
	s.freeBytes = func(string) (int64, error) { return 1 << 20, nil }
	s.SetMinFree(2 << 30)
	if loc, err := s.Put(ctx, k2, []byte("on remote")); err != nil || loc != Remote {
		t.Fatalf("low local disk: %v %v", loc, err)
	}
	if _, err := local.Get(k2); err != ErrNotFound {
		t.Fatal("segment written locally below the free-space floor")
	}
	for loc, want := range map[Location]string{Local: "on local", Remote: "on remote"} {
		key := k1
		if loc == Remote {
			key = k2
		}
		if got, err := s.Get(ctx, loc, key); err != nil || string(got) != want {
			t.Fatalf("get %s: %q %v", loc, got, err)
		}
	}
	if err := s.Delete(ctx, Remote, k2); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Get(ctx, Remote, k2); err != ErrNotFound {
		t.Fatalf("remote get after delete: %v", err)
	}
	// Remote down: no space, and it's marked unhealthy at once.
	srv.Close()
	if _, err := s.Put(ctx, k2, []byte("x")); err != ErrNoSpace {
		t.Fatalf("put with the remote down: %v", err)
	}
	if remote.Healthy() {
		t.Fatal("remote still healthy after a failed write")
	}
}

func TestBlobKeyIsKeyed(t *testing.T) {
	a := BlobKey([]byte("k1"), "acct", 1)
	if !ValidKey(a) || a == BlobKey([]byte("k2"), "acct", 1) || a == BlobKey([]byte("k1"), "acct", 2) ||
		a == BlobKey([]byte("k1"), "acct2", 1) || strings.Contains(a, "acct") {
		t.Fatal("blob keys must depend on key, account and seq")
	}
}
