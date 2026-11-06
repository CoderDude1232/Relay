package store

import (
	"context"
	"crypto/subtle"
	"errors"

	"github.com/jackc/pgx/v5"
)

// Encrypted profiles: each account keeps one fixed-size blob, encrypted under
// a profile key only its contacts hold, at an id derived from that key. The
// relay can't tell whose a profile is: writes and reads are anonymous, and
// nothing ties a row to an account. A row records only the blob, the hash of
// the write secret that may replace it, and the day it was last written; the
// owner rewrites it weekly, so one nobody has written for ProfileRetentionDays
// (a deleted account's, or one abandoned for a new key) is deleted.

const (
	// ProfileBlobSize is every stored profile's size: clients pad to it, so
	// sizes don't tell profiles with and without a photo apart.
	ProfileBlobSize = 64 << 10
	// ProfileRetentionDays without a write deletes a profile.
	ProfileRetentionDays = 30
	// MaxProfiles caps the table, since writes aren't tied to accounts.
	MaxProfiles = 200_000
)

// ErrProfileWriteKey: the id exists under a different write secret.
var ErrProfileWriteKey = errors.New("store: profile write key mismatch")

// ErrProfilesFull: MaxProfiles reached; only existing profiles can be written.
var ErrProfilesFull = errors.New("store: profile storage full")

// PutProfile stores blob at id. The first write sets writeHash; later writes
// (and DeleteProfile) must present the same one.
func (s *Store) PutProfile(id, writeHash, blob []byte, day int64) error {
	ctx := context.Background()
	return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		var stored []byte
		err := tx.QueryRow(ctx, `SELECT write_hash FROM profiles WHERE id = $1 FOR UPDATE`, id).Scan(&stored)
		switch {
		case err == nil:
			if subtle.ConstantTimeCompare(stored, writeHash) != 1 {
				return ErrProfileWriteKey
			}
			_, err = tx.Exec(ctx, `UPDATE profiles SET blob = $2, written_day = $3 WHERE id = $1`, id, blob, day)
			return err
		case errors.Is(err, pgx.ErrNoRows):
			var n int64
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM profiles`).Scan(&n); err != nil {
				return err
			}
			if n >= MaxProfiles {
				return ErrProfilesFull
			}
			_, err = tx.Exec(ctx, `INSERT INTO profiles (id, write_hash, blob, written_day) VALUES ($1, $2, $3, $4)
				ON CONFLICT (id) DO NOTHING`, id, writeHash, blob, day)
			return err
		default:
			return err
		}
	})
}

// Profile returns the blob at id, or ErrNotFound.
func (s *Store) Profile(id []byte) ([]byte, error) {
	var blob []byte
	err := s.db.QueryRow(context.Background(), `SELECT blob FROM profiles WHERE id = $1`, id).Scan(&blob)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	return blob, err
}

// DeleteProfile removes the profile at id if writeHash matches. A missing id
// is not an error.
func (s *Store) DeleteProfile(id, writeHash []byte) error {
	ctx := context.Background()
	var stored []byte
	err := s.db.QueryRow(ctx, `SELECT write_hash FROM profiles WHERE id = $1`, id).Scan(&stored)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	} else if err != nil {
		return err
	}
	if subtle.ConstantTimeCompare(stored, writeHash) != 1 {
		return ErrProfileWriteKey
	}
	_, err = s.db.Exec(ctx, `DELETE FROM profiles WHERE id = $1 AND write_hash = $2`, id, writeHash)
	return err
}
