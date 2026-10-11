package store

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
)

// Recovery key: the client generates it and the relay stores only its
// SHA-256 (accounts.recovery_key_hash), which signs the account in on a fresh
// install like a passkey.

// ErrRecoveryKeyInUse is a recovery_key_hash unique conflict.
var ErrRecoveryKeyInUse = errors.New("store: recovery key hash already in use")

// SetRecoveryKeyHash sets or replaces the account's recovery key hash.
func (s *Store) SetRecoveryKeyHash(accountID string, hash []byte) error {
	tag, err := s.db.Exec(context.Background(),
		`UPDATE accounts SET recovery_key_hash = $1 WHERE id = $2`, hash, accountID)
	if err != nil {
		if isUniqueViolation(err) {
			return ErrRecoveryKeyInUse
		}
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrAccountNotFound
	}
	return nil
}

// ClearRecoveryKeyHash removes the account's recovery key.
func (s *Store) ClearRecoveryKeyHash(accountID string) error {
	_, err := s.db.Exec(context.Background(),
		`UPDATE accounts SET recovery_key_hash = NULL WHERE id = $1`, accountID)
	return err
}

// RecoveryKeyAccount resolves a recovery key hash to its account (ErrNotFound
// if none).
func (s *Store) RecoveryKeyAccount(hash []byte) (accountID string, demo bool, err error) {
	if len(hash) == 0 {
		return "", false, ErrNotFound
	}
	err = s.db.QueryRow(context.Background(),
		`SELECT id, is_demo FROM accounts WHERE recovery_key_hash = $1`, hash).Scan(&accountID, &demo)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", false, ErrNotFound
	}
	return accountID, demo, err
}

// SignInMethods is what can sign an account in on a fresh install.
type SignInMethods struct {
	Email           bool // email token or Supabase link
	Passkeys        int
	AccountPassword bool
	RecoveryKey     bool
}

// AccountSignInMethods reports the account's sign-in methods (ErrNotFound if
// the account is gone).
func (s *Store) AccountSignInMethods(accountID string) (m SignInMethods, err error) {
	err = s.db.QueryRow(context.Background(), `
		SELECT COALESCE(length(a.email_token), 0) > 0 OR COALESCE(a.supabase_user_id, '') <> '',
		       (SELECT count(*) FROM passkeys p WHERE p.account_id = a.id),
		       COALESCE(length(a.account_password_hash), 0) > 0,
		       a.recovery_key_hash IS NOT NULL
		FROM accounts a WHERE a.id = $1`, accountID).Scan(&m.Email, &m.Passkeys, &m.AccountPassword, &m.RecoveryKey)
	if errors.Is(err, pgx.ErrNoRows) {
		return SignInMethods{}, ErrNotFound
	}
	return m, err
}

// RemoveAccountEmail unlinks the account's email: it clears the email token
// and Supabase link, turns email discovery off and deletes the email
// directory rows, in one transaction. ErrNotFound if the account is gone.
func (s *Store) RemoveAccountEmail(accountID string) error {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	tag, err := tx.Exec(ctx,
		`UPDATE accounts SET email_token = NULL, supabase_user_id = NULL, email_discoverable = FALSE WHERE id = $1`, accountID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	if _, err := tx.Exec(ctx, `DELETE FROM directory WHERE account_id = $1 AND kind = $2`, accountID, DirectoryKindEmail); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
