package blob

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPutGetRoundTripAndLimits(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "blobs"), 1024)
	if err != nil {
		t.Fatal(err)
	}

	id, err := s.NewID()
	if err != nil {
		t.Fatal(err)
	}
	payload := bytes.Repeat([]byte{0xAB}, 512)
	if err := s.Put(id, bytes.NewReader(payload)); err != nil {
		t.Fatalf("put: %v", err)
	}
	got, err := s.Get(id)
	if err != nil || !bytes.Equal(got, payload) {
		t.Fatalf("get mismatch: err=%v len=%d", err, len(got))
	}

	// Over the size cap is rejected.
	if err := s.Put(id, bytes.NewReader(bytes.Repeat([]byte{1}, 2048))); err != ErrTooLarge {
		t.Fatalf("expected ErrTooLarge, got %v", err)
	}

	// Path-traversal / malformed ids are rejected, not written.
	if err := s.Put("../evil", bytes.NewReader(payload)); err != ErrNotFound {
		t.Fatalf("expected ErrNotFound for bad id, got %v", err)
	}
	if _, err := s.Get("nope"); err != ErrNotFound {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
}

func TestGCRemovesOldBlobs(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "blobs")
	s, err := Open(dir, 1024)
	if err != nil {
		t.Fatal(err)
	}
	id, _ := s.NewID()
	if err := s.Put(id, bytes.NewReader([]byte("x"))); err != nil {
		t.Fatal(err)
	}
	// Backdate the file well past the TTL.
	old := time.Now().Add(-48 * time.Hour)
	os.Chtimes(filepath.Join(dir, id), old, old)

	if err := s.GC(24 * time.Hour); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Get(id); err != ErrNotFound {
		t.Fatalf("expected blob reaped, got %v", err)
	}
}
