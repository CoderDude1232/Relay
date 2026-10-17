// Package history stores the opaque segments of encrypted chat-history
// backups. The relay holds only ciphertext it has no key for. Each segment is a
// file named by a keyed hash of (account, seq), so neither file names nor the
// remote store reveal which account a segment belongs to.
//
// Segments go to a local directory while its filesystem has room, and to
// historyd on another host (see cmd/historyd) when it doesn't. The database
// row records where each segment went; reads and deletes follow it.
package history

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"log/slog"
	"regexp"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/relayapp/relay-server/internal/privlog"
)

// MaxSegmentBytes caps one segment.
const MaxSegmentBytes = 2 << 20

// Location says where a segment's blob lives.
type Location string

const (
	Local  Location = "local"
	Remote Location = "remote"
)

var (
	ErrNotFound = errors.New("history: blob not found")
	// ErrNoSpace means neither the local disk nor the remote store can take a
	// segment right now.
	ErrNoSpace = errors.New("history: no storage available")
)

var keyPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

// ValidKey reports whether key is a blob key (64 lowercase hex chars). It also
// keeps keys from naming anything outside the blob directory.
func ValidKey(key string) bool { return keyPattern.MatchString(key) }

// BlobKey names a segment's blob: hex HMAC-SHA256(nameKey, account id, seq).
func BlobKey(nameKey []byte, accountID string, seq int64) string {
	m := hmac.New(sha256.New, nameKey)
	m.Write([]byte("relay-history-blob-v1\n" + accountID + "\n" + strconv.FormatInt(seq, 10)))
	return hex.EncodeToString(m.Sum(nil))
}

// FreeBytes is the space available to an unprivileged writer on dir's
// filesystem.
func FreeBytes(dir string) (int64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(dir, &st); err != nil {
		return 0, err
	}
	return int64(st.Bavail) * int64(st.Bsize), nil
}

// Storage places segments locally or remotely and reads them back.
type Storage struct {
	nameKey []byte
	local   *DirStore
	remote  *RemoteClient // nil = no failover
	minFree int64

	freeBytes func(dir string) (int64, error) // FreeBytes; replaced in tests

	mu      sync.Mutex
	current string // last placement outcome: "local", "remote", "none" or ""
}

// NewStorage stores segments in local while its filesystem keeps at least
// minFree bytes free, then in remote (which may be nil).
func NewStorage(nameKey []byte, local *DirStore, minFree int64, remote *RemoteClient) *Storage {
	return &Storage{nameKey: nameKey, local: local, remote: remote, minFree: minFree, freeBytes: FreeBytes}
}

// SetMinFree changes the local free-space floor.
func (s *Storage) SetMinFree(n int64) {
	s.mu.Lock()
	s.minFree = n
	s.mu.Unlock()
}

// Key names the blob for (accountID, seq).
func (s *Storage) Key(accountID string, seq int64) string { return BlobKey(s.nameKey, accountID, seq) }

// Put writes data under key and returns where it went, or ErrNoSpace.
func (s *Storage) Put(ctx context.Context, key string, data []byte) (Location, error) {
	s.mu.Lock()
	minFree := s.minFree
	s.mu.Unlock()
	why := ""
	if free, err := s.freeBytes(s.local.Dir()); err != nil {
		why = "local free space unknown"
	} else if free < minFree {
		why = "local disk below -history-min-free"
	} else if err := s.local.Put(key, data); err != nil {
		slog.Warn("history: local write failed", "err", privlog.Error(err))
		why = "local write failed"
	} else {
		s.placed("local", "")
		return Local, nil
	}
	if s.remote != nil && s.remote.Healthy() {
		if err := s.remote.Put(ctx, key, data); err == nil {
			s.placed("remote", why)
			return Remote, nil
		}
		// A full remote also fails its health probe, so either way it stays
		// out of rotation until a probe says otherwise.
		s.remote.Failed()
		why += "; remote write failed"
	} else if s.remote != nil {
		why += "; remote store unhealthy"
	}
	s.placed("none", why)
	return "", ErrNoSpace
}

// placed logs once each time new segments start going somewhere else.
func (s *Storage) placed(where, why string) {
	s.mu.Lock()
	prev := s.current
	s.current = where
	s.mu.Unlock()
	if prev == where {
		return
	}
	switch {
	case where == "local" && prev != "":
		slog.Warn("history: new segments stored locally again")
	case where == "remote":
		slog.Warn("history: new segments go to the remote store", "why", why)
	case where == "none":
		slog.Error("history: no storage available; segment uploads get 507", "why", why)
	}
}

// Get reads a blob from where its row says it is.
func (s *Storage) Get(ctx context.Context, loc Location, key string) ([]byte, error) {
	switch loc {
	case Local:
		return s.local.Get(key)
	case Remote:
		if s.remote == nil {
			return nil, errors.New("history: segment is remote but no remote store is configured")
		}
		data, err := s.remote.Get(ctx, key)
		if err != nil && !errors.Is(err, ErrNotFound) {
			s.remote.Failed()
		}
		return data, err
	}
	return nil, errors.New("history: unknown location " + string(loc))
}

// Delete removes a blob; a missing one is not an error.
func (s *Storage) Delete(ctx context.Context, loc Location, key string) error {
	switch loc {
	case Local:
		return s.local.Delete(key)
	case Remote:
		if s.remote == nil {
			return errors.New("history: segment is remote but no remote store is configured")
		}
		err := s.remote.Delete(ctx, key)
		if err != nil {
			s.remote.Failed()
		}
		return err
	}
	return errors.New("history: unknown location " + string(loc))
}

// Sweep deletes blobs no row refers to: those left by a failed delete, or a
// write whose row never landed. live holds the keys rows refer to, by
// location. Blobs younger than grace are kept, since an upload writes its
// blob before its row.
func (s *Storage) Sweep(ctx context.Context, live map[Location]map[string]bool, grace time.Duration) {
	s.local.CleanTemp(grace)
	if list, err := s.local.List(); err != nil {
		slog.Warn("history sweep: listing local blobs failed", "err", privlog.Error(err))
	} else {
		for _, key := range orphans(list, live[Local], grace, "local") {
			if err := s.local.Delete(key); err != nil {
				slog.Warn("history sweep: local delete failed", "err", privlog.Error(err))
			}
		}
	}
	if s.remote == nil || !s.remote.Healthy() {
		return
	}
	list, err := s.remote.List(ctx)
	if err != nil {
		s.remote.Failed()
		slog.Warn("history sweep: listing remote blobs failed", "err", privlog.Error(err))
		return
	}
	for _, key := range orphans(list, live[Remote], grace, "remote") {
		if err := s.remote.Delete(ctx, key); err != nil {
			s.remote.Failed()
			slog.Warn("history sweep: remote delete failed", "err", privlog.Error(err))
			return
		}
	}
}

// orphans picks the blobs to delete. If rows exist but none of their blobs
// are present while unknown blobs are, the naming key has most likely changed
// (a different OPRF key), and deleting would destroy every backup; it refuses.
func orphans(list []BlobInfo, live map[string]bool, grace time.Duration, where string) []string {
	cutoff := time.Now().Add(-grace)
	matched := 0
	var out []string
	for _, b := range list {
		if live[b.Key] {
			matched++
		} else if time.Unix(b.Modified, 0).Before(cutoff) {
			out = append(out, b.Key)
		}
	}
	if len(live) > 0 && matched == 0 && len(out) > 0 {
		slog.Error("history sweep: no stored blob matches a row; has the naming key changed? not deleting",
			"where", where, "rows", len(live), "blobs", len(list))
		return nil
	}
	return out
}

// BlobInfo is one stored blob, as listed for the sweeper.
type BlobInfo struct {
	Key      string `json:"key"`
	Modified int64  `json:"modified"` // unix seconds
}
