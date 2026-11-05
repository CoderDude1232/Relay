package store

import (
	"context"
	"errors"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/bcrypt"
)

// Two-step verification: a sign-in by email or phone code (which proves only
// the inbox or the number) to an account that has turned it on must also pass
// one second step. The account turns on one or more methods (an answer to any
// of them passes); the recovery key always works instead, through its own
// sign-in. Passkey and recovery-key sign-ins are strong on their own and
// never need it. two_step_method holds the methods comma-joined in
// methodOrder; "recovery" (older accounts) is only ever on its own.
const (
	TwoStepNone     = ""
	TwoStepTOTP     = "totp"     // an authenticator app code
	TwoStepPasskey  = "passkey"  // one of the account's passkeys
	TwoStepPIN      = "pin"      // the account password (a PIN or password)
	TwoStepRecovery = "recovery" // only the recovery key (older accounts)
)

// methodOrder is the stored order; the first is the one older clients ask for.
var methodOrder = []string{TwoStepPasskey, TwoStepTOTP, TwoStepPIN, TwoStepRecovery}

// ParseTwoStepMethods splits a stored or ticket method list.
func ParseTwoStepMethods(joined string) []string {
	var out []string
	for _, m := range methodOrder {
		for _, part := range strings.Split(joined, ",") {
			if part == m {
				out = append(out, m)
				break
			}
		}
	}
	return out
}

// JoinTwoStepMethods is the stored form of a method set.
func JoinTwoStepMethods(methods []string) string {
	var out []string
	for _, m := range methodOrder {
		if slices.Contains(methods, m) {
			out = append(out, m)
		}
	}
	return strings.Join(out, ",")
}

var (
	ErrTwoStepRequired = errors.New("store: two-step verification required")
	// ErrTwoStepUnavailable: the method needs something the account lacks
	// (a passkey, a PIN, a recovery key).
	ErrTwoStepUnavailable = errors.New("store: two-step method not available")
	// ErrTwoStepInUse: removing this would leave the chosen method unusable.
	ErrTwoStepInUse = errors.New("store: in use by two-step verification")
)

const appAttestKeyRetention = 90 * 24 * time.Hour

// methodForNewAccount: an account created with an account password (older
// clients) keeps it as a registration lock.
func methodForNewAccount(accountPasswordHash []byte) string {
	if len(accountPasswordHash) > 0 {
		return TwoStepPIN
	}
	return TwoStepNone
}

// effectiveMethod resolves a NULL two_step_method (an account from before
// two-step verification) to what protected it then: the account password as
// a registration lock, or else a passkey or recovery key, without which an
// email code alone couldn't take it over.
func effectiveMethod(stored *string, hasPassword, hasPasskey, hasRecovery bool) string {
	if stored != nil {
		return *stored
	}
	switch {
	case hasPassword:
		return TwoStepPIN
	case hasPasskey:
		return TwoStepPasskey
	case hasRecovery:
		return TwoStepRecovery
	}
	return TwoStepNone
}

const twoStepColumns = `two_step_method, COALESCE(length(account_password_hash), 0) > 0,
	EXISTS (SELECT 1 FROM passkeys p WHERE p.account_id = accounts.id), recovery_key_hash IS NOT NULL`

// TwoStep is an account's two-step setting and what it could use.
type TwoStep struct {
	// Method is the first of Methods ("" when off), for older clients.
	Method         string
	Methods        []string
	HasPIN         bool
	HasPasskey     bool
	HasRecoveryKey bool
	TOTPSecret     []byte // sealed by the caller; nil without an authenticator
	TOTPLastStep   int64
}

func scanTwoStep(row pgx.Row, extra ...any) (TwoStep, error) {
	var r twoStepRow
	if err := row.Scan(r.dest(extra...)...); err != nil {
		return TwoStep{}, err
	}
	return r.twoStep()
}

// twoStepRow receives twoStepColumns, totp_secret, totp_last_step from a scan
// done elsewhere (findByIdentityTx).
type twoStepRow struct {
	t      TwoStep
	stored *string
}

func (r *twoStepRow) dest(extra ...any) []any {
	return append([]any{&r.stored, &r.t.HasPIN, &r.t.HasPasskey, &r.t.HasRecoveryKey, &r.t.TOTPSecret, &r.t.TOTPLastStep}, extra...)
}

func (r *twoStepRow) twoStep() (TwoStep, error) {
	t := r.t
	t.Methods = ParseTwoStepMethods(effectiveMethod(r.stored, t.HasPIN, t.HasPasskey, t.HasRecoveryKey))
	if len(t.Methods) > 0 {
		t.Method = t.Methods[0]
	}
	return t, nil
}

// Has reports whether method is one of the account's.
func (t TwoStep) Has(method string) bool { return slices.Contains(t.Methods, method) }

// Joined is the method set as stored and as carried in tickets.
func (t TwoStep) Joined() string { return JoinTwoStepMethods(t.Methods) }

// TwoStepFor reads the account's setting.
func (s *Store) TwoStepFor(accountID string) (TwoStep, error) {
	t, err := scanTwoStep(s.db.QueryRow(context.Background(),
		`SELECT `+twoStepColumns+`, totp_secret, totp_last_step FROM accounts WHERE id = $1`, accountID))
	if errors.Is(err, pgx.ErrNoRows) {
		return TwoStep{}, ErrAccountNotFound
	}
	return t, err
}

// SetTwoStepMethod chooses the method (TwoStepNone turns it off). The
// authenticator method is set with SetTOTP instead. Leaving it clears the
// authenticator secret. ErrTwoStepUnavailable if the account lacks what the
// method needs.
func (s *Store) SetTwoStepMethod(accountID, method string) error {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	t, err := scanTwoStep(tx.QueryRow(ctx,
		`SELECT `+twoStepColumns+`, totp_secret, totp_last_step FROM accounts WHERE id = $1 FOR UPDATE`, accountID))
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrAccountNotFound
	} else if err != nil {
		return err
	}
	switch method {
	case TwoStepNone:
	case TwoStepPasskey:
		if !t.HasPasskey {
			return ErrTwoStepUnavailable
		}
	case TwoStepPIN:
		if !t.HasPIN {
			return ErrTwoStepUnavailable
		}
	case TwoStepRecovery:
		if !t.HasRecoveryKey {
			return ErrTwoStepUnavailable
		}
	default:
		return ErrTwoStepUnavailable
	}
	if _, err := tx.Exec(ctx,
		`UPDATE accounts SET two_step_method = $2, totp_secret = NULL, totp_last_step = 0 WHERE id = $1`,
		accountID, method); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// SetTwoStepEnabled turns one method on or off, keeping the others. The
// authenticator is turned on with SetTOTP; turning it off clears its secret.
// "recovery" only ever stands alone: turning it on replaces the others, and
// turning another on replaces it.
func (s *Store) SetTwoStepEnabled(accountID, method string, enabled bool) error {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	t, err := scanTwoStep(tx.QueryRow(ctx,
		`SELECT `+twoStepColumns+`, totp_secret, totp_last_step FROM accounts WHERE id = $1 FOR UPDATE`, accountID))
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrAccountNotFound
	} else if err != nil {
		return err
	}
	methods := slices.DeleteFunc(slices.Clone(t.Methods), func(m string) bool { return m == method })
	if enabled {
		switch method {
		case TwoStepPasskey:
			if !t.HasPasskey {
				return ErrTwoStepUnavailable
			}
		case TwoStepPIN:
			if !t.HasPIN {
				return ErrTwoStepUnavailable
			}
		case TwoStepRecovery:
			if !t.HasRecoveryKey {
				return ErrTwoStepUnavailable
			}
			methods = nil
		default: // the authenticator goes through SetTOTP
			return ErrTwoStepUnavailable
		}
		if method != TwoStepRecovery {
			methods = slices.DeleteFunc(methods, func(m string) bool { return m == TwoStepRecovery })
		}
		methods = append(methods, method)
	}
	clearTOTP := !slices.Contains(methods, TwoStepTOTP)
	if _, err := tx.Exec(ctx,
		`UPDATE accounts SET two_step_method = $2,
		   totp_secret = CASE WHEN $3 THEN NULL ELSE totp_secret END,
		   totp_last_step = CASE WHEN $3 THEN 0 ELSE totp_last_step END
		 WHERE id = $1`,
		accountID, JoinTwoStepMethods(methods), clearTOTP); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// SetTOTP turns on the authenticator method (alongside the others) with a
// sealed secret, having accepted a code at step (which can't be used again).
func (s *Store) SetTOTP(accountID string, sealedSecret []byte, step int64) error {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	t, err := scanTwoStep(tx.QueryRow(ctx,
		`SELECT `+twoStepColumns+`, totp_secret, totp_last_step FROM accounts WHERE id = $1 FOR UPDATE`, accountID))
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrAccountNotFound
	} else if err != nil {
		return err
	}
	methods := slices.DeleteFunc(slices.Clone(t.Methods), func(m string) bool { return m == TwoStepRecovery })
	methods = append(methods, TwoStepTOTP)
	if _, err := tx.Exec(ctx,
		`UPDATE accounts SET two_step_method = $2, totp_secret = $3, totp_last_step = $4 WHERE id = $1`,
		accountID, JoinTwoStepMethods(methods), sealedSecret, step); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// UseTOTPStep records an accepted code's time step, so neither it nor an
// earlier one works again. False if a code at or after step was already used.
func (s *Store) UseTOTPStep(accountID string, step int64) (bool, error) {
	tag, err := s.db.Exec(context.Background(),
		`UPDATE accounts SET totp_last_step = $2 WHERE id = $1 AND totp_last_step < $2 AND totp_secret IS NOT NULL`,
		accountID, step)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

// CheckAccountPassword verifies the account password (the PIN) without
// signing in. False when the account has none.
func (s *Store) CheckAccountPassword(accountID string, p AccountPassword) (bool, error) {
	var hash []byte
	err := s.db.QueryRow(context.Background(),
		`SELECT account_password_hash FROM accounts WHERE id = $1`, accountID).Scan(&hash)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, ErrAccountNotFound
	} else if err != nil {
		return false, err
	}
	if len(hash) == 0 {
		p.burn()
		return false, nil
	}
	ok, upgraded, err := p.verify(hash)
	if err != nil || !ok {
		return false, err
	}
	if upgraded != nil {
		_, _ = s.db.Exec(context.Background(),
			`UPDATE accounts SET account_password_hash = $1 WHERE id = $2`, upgraded, accountID)
	}
	return true, nil
}

// ClearAccountPassword removes the account password. ErrTwoStepInUse while
// it is a two-step method.
func (s *Store) ClearAccountPassword(accountID string) error {
	return s.clearIfNotTwoStep(accountID, TwoStepPIN, `UPDATE accounts SET account_password_hash = NULL WHERE id = $1`)
}

// RefuseIfTwoStep returns ErrTwoStepInUse when method is one of the account's
// two-step methods and removing the last passkey or the recovery key would
// leave it unusable. lastOne says whether the thing being removed is the
// only one of its kind.
func (s *Store) RefuseIfTwoStep(accountID, method string, lastOne bool) error {
	if !lastOne {
		return nil
	}
	t, err := s.TwoStepFor(accountID)
	if err != nil {
		return err
	}
	if t.Has(method) {
		return ErrTwoStepInUse
	}
	return nil
}

func (s *Store) clearIfNotTwoStep(accountID, method, update string) error {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	t, err := scanTwoStep(tx.QueryRow(ctx,
		`SELECT `+twoStepColumns+`, totp_secret, totp_last_step FROM accounts WHERE id = $1 FOR UPDATE`, accountID))
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrAccountNotFound
	} else if err != nil {
		return err
	}
	if t.Has(method) {
		return ErrTwoStepInUse
	}
	if _, err := tx.Exec(ctx, update, accountID); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// MARK: Phone sign-in

// AccountByPhoneToken finds the account a verified number signs in to.
func (s *Store) AccountByPhoneToken(token []byte) (accountID string, demo bool, err error) {
	err = s.db.QueryRow(context.Background(),
		`SELECT id, is_demo FROM accounts WHERE phone_token = $1`, token).Scan(&accountID, &demo)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", false, ErrNotFound
	}
	return accountID, demo, err
}

// CreatePhoneAccount creates an account signed in by a verified phone number
// (its OPRF token), with device 1. ErrUsernameTaken, or ErrIdentityInUse if
// the number already has an account.
func (s *Store) CreatePhoneAccount(username string, phoneToken []byte, discoverable bool, devicePassword string) (AddedDevice, error) {
	deviceHash, err := bcrypt.GenerateFromPassword([]byte(devicePassword), bcrypt.DefaultCost)
	if err != nil {
		return AddedDevice{}, err
	}
	mailboxID, err := newMailboxID()
	if err != nil {
		return AddedDevice{}, err
	}
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return AddedDevice{}, err
	}
	defer tx.Rollback(ctx)
	var exists bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM accounts WHERE phone_token = $1)`, phoneToken).Scan(&exists); err != nil {
		return AddedDevice{}, err
	}
	if exists {
		return AddedDevice{}, ErrIdentityInUse
	}
	if taken, err := s.usernameUnavailableTx(ctx, tx, username, ""); err != nil {
		return AddedDevice{}, err
	} else if taken {
		return AddedDevice{}, ErrUsernameTaken
	}
	dev := AddedDevice{AccountID: newUUID(), Username: username, DeviceID: 1, MailboxID: mailboxID}
	now := coarseDayMillis()
	if _, err := tx.Exec(ctx,
		`INSERT INTO accounts (id, username, phone_token, phone_discoverable, two_step_method, created_at, next_device_id) VALUES ($1, $2, $3, $4, '', $5, 1)`,
		dev.AccountID, username, phoneToken, discoverable, now); err != nil {
		return AddedDevice{}, accountInsertError(err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO devices (account_id, device_id, mailbox_id, password_hash, created_at) VALUES ($1, 1, $2, $3, $4)`,
		dev.AccountID, mailboxID, deviceHash, now); err != nil {
		return AddedDevice{}, err
	}
	if err := s.clearReleasedUsernameTx(ctx, tx, username); err != nil {
		return AddedDevice{}, err
	}
	return dev, tx.Commit(ctx)
}

// MARK: App Attest keys

// PutAppAttestKey stores a newly attested key.
func (s *Store) PutAppAttestKey(keyID, publicKey []byte) error {
	_, err := s.db.Exec(context.Background(),
		`INSERT INTO app_attest_keys (key_id, public_key, counter, used_at) VALUES ($1, $2, 0, $3)
		 ON CONFLICT (key_id) DO NOTHING`, keyID, publicKey, time.Now().UnixMilli())
	return err
}

// AppAttestKey returns a stored key and its last counter. ErrNotFound if unknown.
func (s *Store) AppAttestKey(keyID []byte) (publicKey []byte, counter uint32, err error) {
	var c int64
	err = s.db.QueryRow(context.Background(),
		`SELECT public_key, counter FROM app_attest_keys WHERE key_id = $1`, keyID).Scan(&publicKey, &c)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, 0, ErrNotFound
	}
	return publicKey, uint32(c), err
}

// AdvanceAppAttestCounter records an assertion's counter. False if another
// request already used it or a later one (a replay).
func (s *Store) AdvanceAppAttestCounter(keyID []byte, counter uint32) (bool, error) {
	tag, err := s.db.Exec(context.Background(),
		`UPDATE app_attest_keys SET counter = $2, used_at = $3 WHERE key_id = $1 AND counter < $2`,
		keyID, int64(counter), time.Now().UnixMilli())
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}
