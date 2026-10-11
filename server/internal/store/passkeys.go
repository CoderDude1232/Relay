package store

import (
	"context"
	"crypto/rand"
	"errors"

	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/bcrypt"
)

// Passkeys: WebAuthn credentials that sign an account in on a fresh install.
// The relay stores each credential's public key record (as JSON, opaque here)
// under a random per-account user handle.

// MaxPasskeysPerAccount caps the passkeys one account may register.
const MaxPasskeysPerAccount = 10

var (
	ErrPasskeyLimit  = errors.New("store: passkey limit reached")
	ErrPasskeyExists = errors.New("store: passkey already registered")
)

// Passkey is one stored credential. Credential is the marshalled
// webauthn.Credential.
type Passkey struct {
	CredentialID []byte
	Credential   []byte
	Name         string
	CreatedAt    int64
}

// PasskeyUserHandle returns the account's WebAuthn user handle (creating a
// random 32-byte one on first use) and its username.
func (s *Store) PasskeyUserHandle(accountID string) (handle []byte, username string, err error) {
	ctx := context.Background()
	var fresh [32]byte
	if _, err = rand.Read(fresh[:]); err != nil {
		return nil, "", err
	}
	if _, err = s.db.Exec(ctx,
		`UPDATE accounts SET passkey_user_handle = $2 WHERE id = $1 AND passkey_user_handle IS NULL`,
		accountID, fresh[:]); err != nil {
		return nil, "", err
	}
	err = s.db.QueryRow(ctx,
		`SELECT passkey_user_handle, username FROM accounts WHERE id = $1`, accountID).Scan(&handle, &username)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, "", ErrNotFound
	}
	return handle, username, err
}

// PasskeyAccount resolves a user handle to its account (ErrNotFound if none).
func (s *Store) PasskeyAccount(handle []byte) (accountID, username string, demo bool, err error) {
	if len(handle) == 0 {
		return "", "", false, ErrNotFound
	}
	err = s.db.QueryRow(context.Background(),
		`SELECT id, username, is_demo FROM accounts WHERE passkey_user_handle = $1`, handle).Scan(&accountID, &username, &demo)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", false, ErrNotFound
	}
	return accountID, username, demo, err
}

// ListPasskeys returns the account's passkeys, oldest first.
func (s *Store) ListPasskeys(accountID string) ([]Passkey, error) {
	rows, err := s.db.Query(context.Background(),
		`SELECT credential_id, credential, name, created_at FROM passkeys WHERE account_id = $1
         ORDER BY created_at, credential_id`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Passkey
	for rows.Next() {
		var p Passkey
		if err := rows.Scan(&p.CredentialID, &p.Credential, &p.Name, &p.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// AddPasskey stores a verified credential, enforcing MaxPasskeysPerAccount.
// Its creation time is rounded to the day.
func (s *Store) AddPasskey(accountID string, credentialID, credential []byte, name string) error {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	// The account row lock serializes concurrent registrations for the cap.
	if err := tx.QueryRow(ctx, `SELECT id FROM accounts WHERE id = $1 FOR UPDATE`, accountID).Scan(&accountID); errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	} else if err != nil {
		return err
	}
	var n int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM passkeys WHERE account_id = $1`, accountID).Scan(&n); err != nil {
		return err
	}
	if n >= MaxPasskeysPerAccount {
		return ErrPasskeyLimit
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO passkeys (credential_id, account_id, credential, name, created_at) VALUES ($1, $2, $3, $4, $5)`,
		credentialID, accountID, credential, name, coarseDayMillis()); err != nil {
		if isUniqueViolation(err) {
			return ErrPasskeyExists
		}
		return err
	}
	return tx.Commit(ctx)
}

// DeletePasskey removes one of the account's passkeys (ErrNotFound if it has
// no such passkey).
func (s *Store) DeletePasskey(accountID string, credentialID []byte) error {
	tag, err := s.db.Exec(context.Background(),
		`DELETE FROM passkeys WHERE account_id = $1 AND credential_id = $2`, accountID, credentialID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ProvisionPasskeyDevice completes a verified passkey sign-in in one
// transaction: it saves the updated credential (sign count, flags), replaces
// the account's devices and adds a new one with devicePassword, like an
// existing-account social login. A verified passkey stands in for the account
// password, so the registration lock isn't checked. Returns ErrNotFound if the
// passkey was removed in the meantime.
func (s *Store) ProvisionPasskeyDevice(accountID string, credentialID, credential []byte, devicePassword string) (dev AddedDevice, err error) {
	ctx := context.Background()
	deviceHash, err := bcrypt.GenerateFromPassword([]byte(devicePassword), bcrypt.DefaultCost)
	if err != nil {
		return AddedDevice{}, err
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return AddedDevice{}, err
	}
	defer tx.Rollback(ctx)
	tag, err := tx.Exec(ctx,
		`UPDATE passkeys SET credential = $3 WHERE credential_id = $1 AND account_id = $2`,
		credentialID, accountID, credential)
	if err != nil {
		return AddedDevice{}, err
	}
	if tag.RowsAffected() == 0 {
		return AddedDevice{}, ErrNotFound
	}
	if dev, err = provisionReplacementTx(ctx, tx, accountID, deviceHash); err != nil {
		return AddedDevice{}, err
	}
	if err = tx.Commit(ctx); err != nil {
		return AddedDevice{}, err
	}
	return dev, nil
}

// ProvisionReplacementDevice replaces the account's devices with one new
// device using devicePassword, in one transaction, without checking the
// registration lock. The caller must already have verified a credential that
// stands in for the account password. ErrNotFound if the account is gone,
// ErrDeviceLimit from the device cap.
func (s *Store) ProvisionReplacementDevice(accountID, devicePassword string) (AddedDevice, error) {
	ctx := context.Background()
	deviceHash, err := bcrypt.GenerateFromPassword([]byte(devicePassword), bcrypt.DefaultCost)
	if err != nil {
		return AddedDevice{}, err
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return AddedDevice{}, err
	}
	defer tx.Rollback(ctx)
	dev, err := provisionReplacementTx(ctx, tx, accountID, deviceHash)
	if err != nil {
		return AddedDevice{}, err
	}
	if err = tx.Commit(ctx); err != nil {
		return AddedDevice{}, err
	}
	return dev, nil
}

func provisionReplacementTx(ctx context.Context, tx pgx.Tx, accountID string, deviceHash []byte) (dev AddedDevice, err error) {
	if err = tx.QueryRow(ctx, `SELECT username FROM accounts WHERE id = $1`, accountID).Scan(&dev.Username); errors.Is(err, pgx.ErrNoRows) {
		return AddedDevice{}, ErrNotFound
	} else if err != nil {
		return AddedDevice{}, err
	}
	dev.AccountID = accountID
	if dev.ReplacedDevices, err = replaceDevicesTx(ctx, tx, accountID); err != nil {
		return AddedDevice{}, err
	}
	if dev.DeviceID, dev.MailboxID, dev.DeviceListVersion, err = addDeviceTx(ctx, tx, accountID, deviceHash); err != nil {
		return AddedDevice{}, err
	}
	return dev, nil
}

// UpdatePasskeyCredential saves a credential record after a verified
// assertion (sign count, flags). ErrNotFound if the account has no such
// passkey.
func (s *Store) UpdatePasskeyCredential(accountID string, credentialID, credential []byte) error {
	tag, err := s.db.Exec(context.Background(),
		`UPDATE passkeys SET credential = $3 WHERE credential_id = $1 AND account_id = $2`,
		credentialID, accountID, credential)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// CreatePasskeyAccount creates an account with no email, Supabase link or
// account password, signed in by the given verified passkey: the account row
// (with passkey user handle), device 1 and the passkeys row, in one
// transaction. ErrUsernameTaken if the name is unavailable, ErrPasskeyExists
// if the credential is registered elsewhere.
func (s *Store) CreatePasskeyAccount(username string, handle, credentialID, credential []byte, credentialName, devicePassword string) (dev AddedDevice, err error) {
	deviceHash, err := bcrypt.GenerateFromPassword([]byte(devicePassword), bcrypt.DefaultCost)
	if err != nil {
		return AddedDevice{}, err
	}
	if dev.MailboxID, err = newMailboxID(); err != nil {
		return AddedDevice{}, err
	}
	dev.AccountID, dev.Username, dev.DeviceID = newUUID(), username, 1
	now := coarseDayMillis()
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return AddedDevice{}, err
	}
	defer tx.Rollback(ctx)
	if taken, err := s.usernameUnavailableTx(ctx, tx, username, ""); err != nil {
		return AddedDevice{}, err
	} else if taken {
		return AddedDevice{}, ErrUsernameTaken
	}
	if _, err = tx.Exec(ctx,
		`INSERT INTO accounts (id, username, passkey_user_handle, created_at, next_device_id) VALUES ($1, $2, $3, $4, 1)`,
		dev.AccountID, username, handle, now); err != nil {
		return AddedDevice{}, accountInsertError(err)
	}
	if _, err = tx.Exec(ctx, `INSERT INTO devices (account_id, device_id, mailbox_id, password_hash, created_at) VALUES ($1, 1, $2, $3, $4)`,
		dev.AccountID, dev.MailboxID, deviceHash, now); err != nil {
		return AddedDevice{}, err
	}
	if _, err = tx.Exec(ctx,
		`INSERT INTO passkeys (credential_id, account_id, credential, name, created_at) VALUES ($1, $2, $3, $4, $5)`,
		credentialID, dev.AccountID, credential, credentialName, now); err != nil {
		if isUniqueViolation(err) {
			return AddedDevice{}, ErrPasskeyExists
		}
		return AddedDevice{}, err
	}
	if err = s.clearReleasedUsernameTx(ctx, tx, username); err != nil {
		return AddedDevice{}, err
	}
	if err = tx.Commit(ctx); err != nil {
		return AddedDevice{}, err
	}
	return dev, nil
}
