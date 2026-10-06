package blob

import (
	"errors"
	"os"
)

// Upload reservations. Attachment GET/PUT are unauthenticated (the 128-bit id
// is the capability), so the relay must not accept a PUT to an arbitrary id:
// only an id handed out by the authenticated allocate call, and only once.
// Reserve drops an empty "<id>.alloc" marker; Claim removes it atomically, so
// exactly one upload can ever claim a given id. Markers are reaped by GC like
// blobs. (The ".alloc" suffix never matches idPattern, so a marker can't be
// fetched or overwritten as a blob.)

const allocSuffix = ".alloc"

// Reserve records id as allocated and not yet written.
func (s *Store) Reserve(id string) error {
	p, ok := s.path(id)
	if !ok {
		return ErrNotFound
	}
	f, err := os.OpenFile(p+allocSuffix, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	return f.Close()
}

// Claim consumes id's reservation. It returns ErrNotFound if id was never
// allocated, its reservation expired, or it has already been claimed (so a
// blob can be written at most once).
func (s *Store) Claim(id string) error {
	p, ok := s.path(id)
	if !ok {
		return ErrNotFound
	}
	if err := os.Remove(p + allocSuffix); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return ErrNotFound
		}
		return err
	}
	if _, err := os.Stat(p); err == nil {
		return ErrNotFound // already written (defensive; markers are single-use)
	}
	return nil
}
