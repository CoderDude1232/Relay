package blob

import (
	"bytes"
	"errors"
	"path/filepath"
	"testing"
)

func TestReservationIsSingleUse(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "blobs"), 1024)
	if err != nil {
		t.Fatal(err)
	}
	unallocated, _ := s.NewID()
	if err := s.Claim(unallocated); !errors.Is(err, ErrNotFound) {
		t.Fatalf("claim of never-allocated id: %v, want ErrNotFound", err)
	}

	id, _ := s.NewID()
	if err := s.Reserve(id); err != nil {
		t.Fatal(err)
	}
	if err := s.Reserve(id); err == nil {
		t.Fatal("double reservation accepted")
	}
	if err := s.Claim(id); err != nil {
		t.Fatalf("claim: %v", err)
	}
	if err := s.Put(id, bytes.NewReader([]byte("ct"))); err != nil {
		t.Fatal(err)
	}
	if err := s.Claim(id); !errors.Is(err, ErrNotFound) {
		t.Fatalf("second claim: %v, want ErrNotFound", err)
	}
	// The marker is never addressable as a blob.
	if _, err := s.Get(id + allocSuffix); !errors.Is(err, ErrNotFound) {
		t.Fatalf("marker readable as blob: %v", err)
	}
	if err := s.Claim("../etc/passwd"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("path traversal: %v", err)
	}
}
