package store

import (
	"context"
	"crypto/subtle"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// PIN guard (internal/pinguard, docs/DISTRESS_PIN_PLAN.md): one secret OPRF
// scalar per device, the verifier the device proves a correct PIN with, and
// how many PINs have been tried since the last correct one. Rows go with
// their device (foreign key, ON DELETE CASCADE).

// ErrPinGuardExhausted: too many PINs were tried, and the key is now deleted.
var ErrPinGuardExhausted = errors.New("store: pin guard exhausted")

// ErrPinGuardVerifierSet: enrolment already finished; enrol again to replace it.
var ErrPinGuardVerifierSet = errors.New("store: pin guard verifier already set")

// EnrolPinGuard gives the device a fresh scalar, replacing any earlier one
// (which makes whatever it protected unrecoverable). The verifier stays unset
// until SetPinGuardVerifier finishes enrolment.
func (s *Store) EnrolPinGuard(accountID string, deviceID uint32, scalar []byte) error {
	// Day precision, like account storage.
	now := time.Now().UTC().Truncate(24 * time.Hour).UnixMilli()
	_, err := s.db.Exec(context.Background(),
		`INSERT INTO pin_guard (account_id, device_id, scalar, verifier, attempts, created_at)
         VALUES ($1, $2, $3, NULL, 0, $4)
         ON CONFLICT (account_id, device_id)
         DO UPDATE SET scalar = EXCLUDED.scalar, verifier = NULL, attempts = 0, created_at = EXCLUDED.created_at`,
		accountID, deviceID, scalar, now)
	return err
}

// PinGuardEnrolmentScalar returns the scalar of an enrolment that hasn't set
// its verifier yet (ErrNotFound if there is none, ErrPinGuardVerifierSet if
// enrolment is finished). It doesn't count as an attempt: until the verifier
// is set, nothing is protected by the key.
func (s *Store) PinGuardEnrolmentScalar(accountID string, deviceID uint32) ([]byte, error) {
	var scalar, verifier []byte
	err := s.db.QueryRow(context.Background(),
		`SELECT scalar, verifier FROM pin_guard WHERE account_id = $1 AND device_id = $2`,
		accountID, deviceID).Scan(&scalar, &verifier)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if verifier != nil {
		return nil, ErrPinGuardVerifierSet
	}
	return scalar, nil
}

// SetPinGuardVerifier finishes enrolment. ErrNotFound if the device hasn't
// enrolled, ErrPinGuardVerifierSet if it already finished.
func (s *Store) SetPinGuardVerifier(accountID string, deviceID uint32, verifier []byte) error {
	ctx := context.Background()
	tag, err := s.db.Exec(ctx,
		`UPDATE pin_guard SET verifier = $3, attempts = 0
         WHERE account_id = $1 AND device_id = $2 AND verifier IS NULL`,
		accountID, deviceID, verifier)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 1 {
		return nil
	}
	var exists bool
	if err := s.db.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM pin_guard WHERE account_id = $1 AND device_id = $2)`,
		accountID, deviceID).Scan(&exists); err != nil {
		return err
	}
	if exists {
		return ErrPinGuardVerifierSet
	}
	return ErrNotFound
}

// TakePinGuardAttempt counts one PIN attempt and returns the scalar to answer
// it with, plus how many attempts are left after this one. Once maxAttempts
// have been used with no correct PIN in between, the row is deleted and
// ErrPinGuardExhausted returned. ErrNotFound if the device has no finished
// enrolment.
func (s *Store) TakePinGuardAttempt(accountID string, deviceID uint32, maxAttempts int) (scalar []byte, left int, err error) {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, 0, err
	}
	defer tx.Rollback(ctx)
	var verifier []byte
	var attempts int
	err = tx.QueryRow(ctx,
		`SELECT scalar, verifier, attempts FROM pin_guard
         WHERE account_id = $1 AND device_id = $2 FOR UPDATE`,
		accountID, deviceID).Scan(&scalar, &verifier, &attempts)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, 0, ErrNotFound
	}
	if err != nil {
		return nil, 0, err
	}
	if verifier == nil {
		return nil, 0, ErrNotFound
	}
	if attempts >= maxAttempts {
		if _, err := tx.Exec(ctx,
			`DELETE FROM pin_guard WHERE account_id = $1 AND device_id = $2`, accountID, deviceID); err != nil {
			return nil, 0, err
		}
		if err := tx.Commit(ctx); err != nil {
			return nil, 0, err
		}
		return nil, 0, ErrPinGuardExhausted
	}
	// Counted before the answer leaves, so a dropped connection still costs
	// the attempt.
	if _, err := tx.Exec(ctx,
		`UPDATE pin_guard SET attempts = attempts + 1 WHERE account_id = $1 AND device_id = $2`,
		accountID, deviceID); err != nil {
		return nil, 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, 0, err
	}
	return scalar, maxAttempts - attempts - 1, nil
}

// ConfirmPinGuard resets the attempt count if verifier matches the stored one.
// It reports whether it matched; ErrNotFound if there's no finished enrolment.
func (s *Store) ConfirmPinGuard(accountID string, deviceID uint32, verifier []byte) (bool, error) {
	ctx := context.Background()
	var stored []byte
	err := s.db.QueryRow(ctx,
		`SELECT verifier FROM pin_guard WHERE account_id = $1 AND device_id = $2`,
		accountID, deviceID).Scan(&stored)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && stored == nil) {
		return false, ErrNotFound
	}
	if err != nil {
		return false, err
	}
	if subtle.ConstantTimeCompare(stored, verifier) != 1 {
		return false, nil
	}
	// Only while the verifier is still the one compared: an enrolment that
	// replaced it in between doesn't get its count reset.
	tag, err := s.db.Exec(ctx,
		`UPDATE pin_guard SET attempts = 0 WHERE account_id = $1 AND device_id = $2 AND verifier = $3`,
		accountID, deviceID, stored)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

// DeletePinGuard removes the device's key (turning the lock off, or the
// distress PIN). Deleting a key that isn't there is not an error.
func (s *Store) DeletePinGuard(accountID string, deviceID uint32) error {
	_, err := s.db.Exec(context.Background(),
		`DELETE FROM pin_guard WHERE account_id = $1 AND device_id = $2`, accountID, deviceID)
	return err
}
