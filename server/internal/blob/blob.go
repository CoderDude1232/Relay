// Package blob is a filesystem store for encrypted attachment blobs. The
// relay only ever holds opaque ciphertext (AES-256-GCM sealed by the sender);
// it has no key and cannot read the contents. Blobs are addressed by an
// unguessable random id (which doubles as a capability) and reaped after a
// TTL.
package blob

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sync/atomic"
	"time"
)

var (
	ErrNotFound = errors.New("blob not found")
	ErrTooLarge = errors.New("blob too large")
)

// 16 random bytes → 32 hex chars. Also guards against path traversal.
var idPattern = regexp.MustCompile(`^[a-f0-9]{32}$`)

type Store struct {
	dir     string
	maxSize int64
	// usage is the total size of the files in dir: measured once at Open,
	// then kept current by Put (+) and GC (−), so checking it is O(1).
	usage atomic.Int64
}

func Open(dir string, maxSize int64) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	s := &Store{dir: dir, maxSize: maxSize}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var total int64
	for _, e := range entries {
		if info, err := e.Info(); err == nil && info.Mode().IsRegular() {
			total += info.Size()
		}
	}
	s.usage.Store(total)
	return s, nil
}

// Usage reports the bytes currently stored in the blob directory (used for the
// relay's attachment disk watermark).
func (s *Store) Usage() int64 { return s.usage.Load() }

// NewID allocates an unguessable id. No file exists until Put.
func (s *Store) NewID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func (s *Store) path(id string) (string, bool) {
	if !idPattern.MatchString(id) {
		return "", false
	}
	return filepath.Join(s.dir, id), true
}

// Put streams the ciphertext to disk, rejecting anything over maxSize.
func (s *Store) Put(id string, r io.Reader) error {
	p, ok := s.path(id)
	if !ok {
		return ErrNotFound
	}
	tmp, err := os.CreateTemp(s.dir, "up-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())

	n, err := io.Copy(tmp, io.LimitReader(r, s.maxSize+1))
	if err != nil {
		tmp.Close()
		return err
	}
	if n > s.maxSize {
		tmp.Close()
		return ErrTooLarge
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp.Name(), p); err != nil {
		return err
	}
	s.usage.Add(n)
	return nil
}

func (s *Store) Get(id string) ([]byte, error) {
	p, ok := s.path(id)
	if !ok {
		return nil, ErrNotFound
	}
	data, err := os.ReadFile(p)
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotFound
	}
	return data, err
}

// Open returns the blob as an open file for streaming (the caller closes it).
// Prefer this over Get for serving: it never loads the blob into memory, and
// *os.File is an io.ReadSeeker so http.ServeContent can serve ranges.
func (s *Store) Open(id string) (*os.File, error) {
	p, ok := s.path(id)
	if !ok {
		return nil, ErrNotFound
	}
	f, err := os.Open(p)
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotFound
	}
	return f, err
}

// GC removes blobs older than ttl (by mtime).
func (s *Store) GC(ttl time.Duration) error {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return err
	}
	cutoff := time.Now().Add(-ttl)
	for _, e := range entries {
		info, err := e.Info()
		if err != nil {
			continue
		}
		if info.ModTime().Before(cutoff) {
			if os.Remove(filepath.Join(s.dir, e.Name())) == nil && info.Mode().IsRegular() {
				s.usage.Add(-info.Size())
			}
		}
	}
	return nil
}
