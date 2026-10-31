package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Chat-history backup segments: opaque, client-encrypted blobs numbered by the
// client. A row records each segment's size and where its blob lives (the
// blob itself is in internal/history, named by a keyed hash of account and
// seq). Rows go with the account; a sign-in that replaces devices keeps them,
// since restoring onto a new device is their purpose.

const (
	// MaxHistoryBytes caps an account's stored segments.
	MaxHistoryBytes = 64 << 20
	// MaxHistorySegments caps an account's segment count, so the byte quota
	// can't be spent as millions of one-byte rows.
	MaxHistorySegments = 512
	// Relay Supporter accounts also back up photos and files.
	SupporterHistoryBytes    = 2 << 30
	SupporterHistorySegments = 8192
)

// HistoryLimits is an account's quota: larger while it has supporter perks.
func HistoryLimits(supporterUntil int64) (maxBytes, maxSegments int64) {
	if supporterUntil > time.Now().UnixMilli() {
		return SupporterHistoryBytes, SupporterHistorySegments
	}
	return MaxHistoryBytes, MaxHistorySegments
}

// ErrHistoryQuota: the write would take the account over MaxHistoryBytes or
// MaxHistorySegments.
var ErrHistoryQuota = errors.New("store: history quota exceeded")

// HistorySegment is one stored segment.
type HistorySegment struct {
	Seq      int64
	Size     int
	Location string
}

// HistoryBlobRef names a segment's blob for the orphan sweep.
type HistoryBlobRef struct {
	AccountID string
	Seq       int64
	Location  string
}

// HistorySegments lists an account's segments by seq, with their total size.
func (s *Store) HistorySegments(accountID string) ([]HistorySegment, int64, error) {
	rows, err := s.db.Query(context.Background(),
		`SELECT seq, size, location FROM history_segments WHERE account_id = $1 ORDER BY seq`, accountID)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	out := []HistorySegment{}
	var used int64
	for rows.Next() {
		var h HistorySegment
		if err := rows.Scan(&h.Seq, &h.Size, &h.Location); err != nil {
			return nil, 0, err
		}
		used += int64(h.Size)
		out = append(out, h)
	}
	return out, used, rows.Err()
}

// HistorySegment returns one segment (ErrNotFound if none).
func (s *Store) HistorySegment(accountID string, seq int64) (HistorySegment, error) {
	h := HistorySegment{Seq: seq}
	err := s.db.QueryRow(context.Background(),
		`SELECT size, location FROM history_segments WHERE account_id = $1 AND seq = $2`,
		accountID, seq).Scan(&h.Size, &h.Location)
	if errors.Is(err, pgx.ErrNoRows) {
		return HistorySegment{}, ErrNotFound
	}
	return h, err
}

type querier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

func checkHistoryQuota(ctx context.Context, q querier, accountID string, seq int64, size int) error {
	var used, count, supporterUntil int64
	if err := q.QueryRow(ctx,
		`SELECT COALESCE(SUM(size), 0), COUNT(*),
			COALESCE((SELECT supporter_until FROM accounts WHERE id = $1), 0)
		FROM history_segments WHERE account_id = $1 AND seq <> $2`,
		accountID, seq).Scan(&used, &count, &supporterUntil); err != nil {
		return err
	}
	maxBytes, maxSegments := HistoryLimits(supporterUntil)
	if used+int64(size) > maxBytes || count+1 > maxSegments {
		return ErrHistoryQuota
	}
	return nil
}

// CheckHistoryQuota reports ErrHistoryQuota if storing size bytes as seq
// (replacing any segment already there) would exceed the quota. It lets an
// upload be refused before its blob is written; PutHistorySegment checks
// again under the account lock.
func (s *Store) CheckHistoryQuota(accountID string, seq int64, size int) error {
	return checkHistoryQuota(context.Background(), s.db, accountID, seq, size)
}

// PutHistorySegment records a segment whose blob is already written, replacing
// any row with the same seq, and returns the replaced row (nil if none) so the
// caller can delete its blob. ErrNotFound if the account is gone,
// ErrHistoryQuota if it would go over quota.
func (s *Store) PutHistorySegment(accountID string, seq int64, size int, location string) (*HistorySegment, error) {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	// Serializes this account's writes (the quota check) and conflicts with
	// DeleteAccount's FOR UPDATE.
	var one int
	if err := tx.QueryRow(ctx, `SELECT 1 FROM accounts WHERE id = $1 FOR NO KEY UPDATE`, accountID).Scan(&one); errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	} else if err != nil {
		return nil, err
	}
	if err := checkHistoryQuota(ctx, tx, accountID, seq, size); err != nil {
		return nil, err
	}
	var prev *HistorySegment
	old := HistorySegment{Seq: seq}
	err = tx.QueryRow(ctx, `SELECT size, location FROM history_segments WHERE account_id = $1 AND seq = $2`,
		accountID, seq).Scan(&old.Size, &old.Location)
	if err == nil {
		prev = &old
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	// Day precision, like the other creation times.
	if _, err := tx.Exec(ctx, `
		INSERT INTO history_segments (account_id, seq, size, location, created_at) VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (account_id, seq) DO UPDATE SET size = EXCLUDED.size, location = EXCLUDED.location, created_at = EXCLUDED.created_at`,
		accountID, seq, size, location, coarseDayMillis()); err != nil {
		return nil, err
	}
	return prev, tx.Commit(ctx)
}

// DeleteHistorySegment removes one segment's row and returns it (nil if there
// was none) so the caller can delete its blob.
func (s *Store) DeleteHistorySegment(accountID string, seq int64) (*HistorySegment, error) {
	h := HistorySegment{Seq: seq}
	err := s.db.QueryRow(context.Background(),
		`DELETE FROM history_segments WHERE account_id = $1 AND seq = $2 RETURNING size, location`,
		accountID, seq).Scan(&h.Size, &h.Location)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &h, nil
}

// DeleteHistory removes all of an account's segment rows and returns them.
func (s *Store) DeleteHistory(accountID string) ([]HistorySegment, error) {
	return deleteHistoryTx(context.Background(), s.db, accountID)
}

type rowsQuerier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

func deleteHistoryTx(ctx context.Context, q rowsQuerier, accountID string) ([]HistorySegment, error) {
	rows, err := q.Query(ctx,
		`DELETE FROM history_segments WHERE account_id = $1 RETURNING seq, size, location`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []HistorySegment
	for rows.Next() {
		var h HistorySegment
		if err := rows.Scan(&h.Seq, &h.Size, &h.Location); err != nil {
			return nil, err
		}
		out = append(out, h)
	}
	return out, rows.Err()
}

// AllHistoryBlobs lists every segment's (account, seq, location), for the
// orphan sweep.
func (s *Store) AllHistoryBlobs() ([]HistoryBlobRef, error) {
	rows, err := s.db.Query(context.Background(), `SELECT account_id, seq, location FROM history_segments`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []HistoryBlobRef
	for rows.Next() {
		var h HistoryBlobRef
		if err := rows.Scan(&h.AccountID, &h.Seq, &h.Location); err != nil {
			return nil, err
		}
		out = append(out, h)
	}
	return out, rows.Err()
}
