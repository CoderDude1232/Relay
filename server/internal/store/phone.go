package store

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
)

// An optional phone number lets people who have it find the account. The
// relay stores only its OPRF token (accounts.phone_token), the same keyed
// token blinded discovery uses, never the number itself. It is not a way to
// sign in.

// SetAccountPhone records a newly verified number's token and whether it is
// discoverable. A number belongs to one account: if another account had it
// (the number changed hands), it is taken from that account, whose id is
// returned so the caller can reindex it.
func (s *Store) SetAccountPhone(accountID string, token []byte, discoverable bool) (previousOwner string, err error) {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback(ctx)
	err = tx.QueryRow(ctx,
		`UPDATE accounts SET phone_token = NULL, phone_discoverable = FALSE
		  WHERE phone_token = $1 AND id <> $2 RETURNING id`, token, accountID).Scan(&previousOwner)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return "", err
	}
	tag, err := tx.Exec(ctx,
		`UPDATE accounts SET phone_token = $1, phone_discoverable = $2 WHERE id = $3`,
		token, discoverable, accountID)
	if err != nil {
		return "", err
	}
	if tag.RowsAffected() == 0 {
		return "", ErrAccountNotFound
	}
	return previousOwner, tx.Commit(ctx)
}

// SetPhoneDiscoverable turns discovery by phone number on or off.
// ErrNotFound if the account has no phone number.
func (s *Store) SetPhoneDiscoverable(accountID string, discoverable bool) error {
	tag, err := s.db.Exec(context.Background(),
		`UPDATE accounts SET phone_discoverable = $1 WHERE id = $2 AND phone_token IS NOT NULL`,
		discoverable, accountID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ClearAccountPhone removes the account's phone number.
func (s *Store) ClearAccountPhone(accountID string) error {
	_, err := s.db.Exec(context.Background(),
		`UPDATE accounts SET phone_token = NULL, phone_discoverable = FALSE WHERE id = $1`, accountID)
	return err
}

// AccountPhone reports whether the account has a phone number and whether
// it is discoverable.
func (s *Store) AccountPhone(accountID string) (has, discoverable bool, err error) {
	err = s.db.QueryRow(context.Background(),
		`SELECT phone_token IS NOT NULL, phone_discoverable FROM accounts WHERE id = $1`, accountID,
	).Scan(&has, &discoverable)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, false, ErrAccountNotFound
	}
	return has, discoverable, err
}
