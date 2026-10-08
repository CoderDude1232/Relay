package blob

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestUsageTracking(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "blobs")
	s, err := Open(dir, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if s.Usage() != 0 {
		t.Fatalf("empty store usage = %d", s.Usage())
	}
	a, _ := s.NewID()
	b, _ := s.NewID()
	if err := s.Put(a, bytes.NewReader(make([]byte, 300))); err != nil {
		t.Fatal(err)
	}
	if err := s.Put(b, bytes.NewReader(make([]byte, 200))); err != nil {
		t.Fatal(err)
	}
	if s.Usage() != 500 {
		t.Fatalf("usage after puts = %d, want 500", s.Usage())
	}
	// A rejected (oversized) upload leaves no trace in usage.
	c, _ := s.NewID()
	small, _ := Open(dir, 100)
	if err := small.Put(c, bytes.NewReader(make([]byte, 101))); err != ErrTooLarge {
		t.Fatal(err)
	}
	if small.Usage() != 500 {
		t.Fatalf("reopened store measured %d, want 500", small.Usage())
	}

	// GC subtracts what it removes.
	old := time.Now().Add(-48 * time.Hour)
	if err := os.Chtimes(filepath.Join(dir, a), old, old); err != nil {
		t.Fatal(err)
	}
	if err := s.GC(24 * time.Hour); err != nil {
		t.Fatal(err)
	}
	if s.Usage() != 200 {
		t.Fatalf("usage after GC = %d, want 200", s.Usage())
	}
}
