package store

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
)

// Relay Supporter books (see internal/supporter). Both tables hold only keyed
// hashes: supporter_issuance counts credentials issued per App Store
// transaction, supporter_spent remembers redeemed credentials until their
// period ends. Neither references an account.

// ErrCredentialSpent: the credential was already redeemed.
var ErrCredentialSpent = errors.New("store: supporter credential already redeemed")

// ClaimSupporterIssuance counts one issuance for a transaction, refusing once
// it has had max. expiresAt (unix ms) is when the row can go.
func (s *Store) ClaimSupporterIssuance(txTag []byte, expiresAt int64, max int) (bool, error) {
	var count int
	err := s.db.QueryRow(context.Background(), `
		INSERT INTO supporter_issuance (tx_tag, count, expires_at) VALUES ($1, 1, $2)
		ON CONFLICT (tx_tag) DO UPDATE SET count = supporter_issuance.count + 1
		WHERE supporter_issuance.count < $3
		RETURNING count`, txTag, expiresAt, max).Scan(&count)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// RedeemSupporterCredential spends a credential and extends the account's
// supporter status to periodEnd (unix ms), returning the new value.
func (s *Store) RedeemSupporterCredential(accountID string, nonceTag []byte, periodEnd int64) (int64, error) {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	tag, err := tx.Exec(ctx, `INSERT INTO supporter_spent (nonce_tag, expires_at) VALUES ($1, $2)
		ON CONFLICT DO NOTHING`, nonceTag, periodEnd)
	if err != nil {
		return 0, err
	}
	if tag.RowsAffected() == 0 {
		return 0, ErrCredentialSpent
	}
	var until int64
	err = tx.QueryRow(ctx, `UPDATE accounts SET supporter_until = GREATEST(supporter_until, $1)
		WHERE id = $2 RETURNING supporter_until`, periodEnd, accountID).Scan(&until)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, ErrAccountNotFound
	}
	if err != nil {
		return 0, err
	}
	return until, tx.Commit(ctx)
}

// SupporterUntil is when the account's supporter perks end (unix ms; 0 =
// never had them).
func (s *Store) SupporterUntil(accountID string) (int64, error) {
	var until int64
	err := s.db.QueryRow(context.Background(),
		`SELECT supporter_until FROM accounts WHERE id = $1`, accountID).Scan(&until)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, ErrAccountNotFound
	}
	return until, err
}
