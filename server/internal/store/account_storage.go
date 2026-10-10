package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Account storage: one opaque, client-encrypted blob per account (the user's
// chat and group list, no messages), so a fresh sign-in can restore it. The key
// is derived on the client from the account password; the relay only ever sees
// ciphertext and its (padded) size.

// MaxAccountStorageBytes caps the blob.
const MaxAccountStorageBytes = 512 << 10

// ErrStorageVersionConflict: the caller's base version is stale (another
// device wrote first); it should re-read, merge and retry.
var ErrStorageVersionConflict = errors.New("store: account storage version conflict")

// AccountStorage returns the blob and its version (ErrNotFound if none).
func (s *Store) AccountStorage(accountID string) (blob []byte, version int64, err error) {
	err = s.db.QueryRow(context.Background(),
		`SELECT blob, version FROM account_storage WHERE account_id = $1`, accountID).Scan(&blob, &version)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, 0, ErrNotFound
	}
	return blob, version, err
}

// PutAccountStorage stores a new blob if baseVersion matches the current one
// (0 when there is none yet) and returns the new version.
func (s *Store) PutAccountStorage(accountID string, blob []byte, baseVersion int64) (int64, error) {
	ctx := context.Background()
	now := time.Now().UnixMilli()
	var version int64
	if baseVersion == 0 {
		err := s.db.QueryRow(ctx,
			`INSERT INTO account_storage (account_id, blob, version, updated_at) VALUES ($1, $2, 1, $3)
             ON CONFLICT (account_id) DO NOTHING RETURNING version`, accountID, blob, now).Scan(&version)
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, ErrStorageVersionConflict
		}
		return version, err
	}
	err := s.db.QueryRow(ctx,
		`UPDATE account_storage SET blob = $2, version = version + 1, updated_at = $3
         WHERE account_id = $1 AND version = $4 RETURNING version`, accountID, blob, now, baseVersion).Scan(&version)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, ErrStorageVersionConflict
	}
	return version, err
}
