// Package store is the relay's persistence layer, backed by SQLite.
//
// The relay stores only what it must to route ciphertext: accounts,
// devices, public prekey material, and queued (still-encrypted) envelopes
// awaiting delivery. No plaintext, no private keys, ever.
package store

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
	_ "modernc.org/sqlite"
)

var (
	ErrNotFound       = errors.New("store: not found")
	ErrUsernameTaken  = errors.New("store: username already taken")
	ErrAuthFailed     = errors.New("store: authentication failed")
)

type Store struct {
	db *sql.DB
}

func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)")
	if err != nil {
		return nil, err
	}
	// modernc.org/sqlite serializes access per connection; a single
	// connection avoids table-lock races between the pool's connections.
	db.SetMaxOpenConns(1)
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) migrate() error {
	_, err := s.db.Exec(`
CREATE TABLE IF NOT EXISTS accounts (
    id            TEXT PRIMARY KEY,
    username      TEXT NOT NULL UNIQUE,
    created_at    INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
    account_id      TEXT NOT NULL REFERENCES accounts(id),
    device_id       INTEGER NOT NULL,
    password_hash   BLOB NOT NULL,
    registration_id INTEGER NOT NULL DEFAULT 0,
    identity_key    BLOB,
    apns_token      TEXT,
    created_at      INTEGER NOT NULL,
    PRIMARY KEY (account_id, device_id)
);
CREATE TABLE IF NOT EXISTS signed_prekeys (
    account_id  TEXT NOT NULL,
    device_id   INTEGER NOT NULL,
    key_id      INTEGER NOT NULL,
    public_key  BLOB NOT NULL,
    signature   BLOB NOT NULL,
    created_at  INTEGER NOT NULL,
    PRIMARY KEY (account_id, device_id),
    FOREIGN KEY (account_id, device_id) REFERENCES devices(account_id, device_id)
);
CREATE TABLE IF NOT EXISTS kyber_prekeys (
    account_id  TEXT NOT NULL,
    device_id   INTEGER NOT NULL,
    key_id      INTEGER NOT NULL,
    public_key  BLOB NOT NULL,
    signature   BLOB NOT NULL,
    created_at  INTEGER NOT NULL,
    PRIMARY KEY (account_id, device_id),
    FOREIGN KEY (account_id, device_id) REFERENCES devices(account_id, device_id)
);
CREATE TABLE IF NOT EXISTS one_time_prekeys (
    account_id  TEXT NOT NULL,
    device_id   INTEGER NOT NULL,
    key_id      INTEGER NOT NULL,
    public_key  BLOB NOT NULL,
    PRIMARY KEY (account_id, device_id, key_id),
    FOREIGN KEY (account_id, device_id) REFERENCES devices(account_id, device_id)
);
CREATE TABLE IF NOT EXISTS message_queue (
    envelope_id TEXT NOT NULL,
    account_id  TEXT NOT NULL,
    device_id   INTEGER NOT NULL,
    envelope    BLOB NOT NULL,
    created_at  INTEGER NOT NULL,
    PRIMARY KEY (envelope_id, account_id, device_id)
);
CREATE INDEX IF NOT EXISTS idx_queue_recipient
    ON message_queue (account_id, device_id, created_at);
`)
	return err
}

// ---------------------------------------------------------------------------
// Accounts and devices
// ---------------------------------------------------------------------------

type Device struct {
	AccountID      string
	DeviceID       uint32
	RegistrationID uint32
}

// CreateAccount registers a new account and its primary device (device 1).
func (s *Store) CreateAccount(username, password string) (accountID string, deviceID uint32, err error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return "", 0, err
	}
	accountID = newUUID()
	now := time.Now().UnixMilli()

	tx, err := s.db.Begin()
	if err != nil {
		return "", 0, err
	}
	defer tx.Rollback()

	if _, err = tx.Exec(`INSERT INTO accounts (id, username, created_at) VALUES (?, ?, ?)`,
		accountID, username, now); err != nil {
		if isUniqueViolation(err) {
			return "", 0, ErrUsernameTaken
		}
		return "", 0, err
	}
	if _, err = tx.Exec(`INSERT INTO devices (account_id, device_id, password_hash, created_at) VALUES (?, 1, ?, ?)`,
		accountID, hash, now); err != nil {
		return "", 0, err
	}
	return accountID, 1, tx.Commit()
}

// AddDevice registers an additional device for an existing account and
// returns its new device id.
func (s *Store) AddDevice(accountID, password string) (uint32, error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return 0, err
	}
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	var next uint32
	if err := tx.QueryRow(`SELECT COALESCE(MAX(device_id), 0) + 1 FROM devices WHERE account_id = ?`, accountID).Scan(&next); err != nil {
		return 0, err
	}
	if next == 1 {
		return 0, ErrNotFound // account doesn't exist
	}
	if _, err := tx.Exec(`INSERT INTO devices (account_id, device_id, password_hash, created_at) VALUES (?, ?, ?, ?)`,
		accountID, next, hash, time.Now().UnixMilli()); err != nil {
		return 0, err
	}
	return next, tx.Commit()
}

// Authenticate verifies device credentials and returns the device row.
func (s *Store) Authenticate(accountID string, deviceID uint32, password string) (*Device, error) {
	var hash []byte
	var regID uint32
	err := s.db.QueryRow(`SELECT password_hash, registration_id FROM devices WHERE account_id = ? AND device_id = ?`,
		accountID, deviceID).Scan(&hash, &regID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrAuthFailed
	}
	if err != nil {
		return nil, err
	}
	if bcrypt.CompareHashAndPassword(hash, []byte(password)) != nil {
		return nil, ErrAuthFailed
	}
	return &Device{AccountID: accountID, DeviceID: deviceID, RegistrationID: regID}, nil
}

// LookupAccountID resolves a username to an account id.
func (s *Store) LookupAccountID(username string) (string, error) {
	var id string
	err := s.db.QueryRow(`SELECT id FROM accounts WHERE username = ?`, username).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return id, err
}

// LookupUsername resolves an account id to its username.
func (s *Store) LookupUsername(accountID string) (string, error) {
	var username string
	err := s.db.QueryRow(`SELECT username FROM accounts WHERE id = ?`, accountID).Scan(&username)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return username, err
}

// Devices returns all devices registered to an account.
func (s *Store) Devices(accountID string) ([]Device, error) {
	rows, err := s.db.Query(`SELECT device_id, registration_id FROM devices WHERE account_id = ? ORDER BY device_id`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Device
	for rows.Next() {
		d := Device{AccountID: accountID}
		if err := rows.Scan(&d.DeviceID, &d.RegistrationID); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

func (s *Store) SetAPNSToken(accountID string, deviceID uint32, token string) error {
	_, err := s.db.Exec(`UPDATE devices SET apns_token = ? WHERE account_id = ? AND device_id = ?`,
		token, accountID, deviceID)
	return err
}

// ---------------------------------------------------------------------------
// Prekeys
// ---------------------------------------------------------------------------

type SignedPreKey struct {
	KeyID     uint32
	PublicKey []byte
	Signature []byte
}

type OneTimePreKey struct {
	KeyID     uint32
	PublicKey []byte
}

// PreKeyBundle is everything a sender needs to run PQXDH with one device.
// The Kyber prekey is mandatory (libsignal requires it in every bundle);
// OneTime is nil when the device's one-time prekey pool is exhausted, in
// which case the session is established from the signed prekeys alone.
type PreKeyBundle struct {
	DeviceID       uint32
	RegistrationID uint32
	IdentityKey    []byte
	SignedPreKey   SignedPreKey
	KyberPreKey    SignedPreKey
	OneTime        *OneTimePreKey
}

// SetKeys replaces the device's identity key, registration id, signed
// prekey and last-resort Kyber prekey, and appends the given one-time
// prekeys to its pool.
func (s *Store) SetKeys(accountID string, deviceID uint32, registrationID uint32, identityKey []byte, spk SignedPreKey, kyber SignedPreKey, oneTime []OneTimePreKey) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	res, err := tx.Exec(`UPDATE devices SET registration_id = ?, identity_key = ? WHERE account_id = ? AND device_id = ?`,
		registrationID, identityKey, accountID, deviceID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	if _, err := tx.Exec(`INSERT INTO signed_prekeys (account_id, device_id, key_id, public_key, signature, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT (account_id, device_id) DO UPDATE SET key_id = excluded.key_id,
            public_key = excluded.public_key, signature = excluded.signature, created_at = excluded.created_at`,
		accountID, deviceID, spk.KeyID, spk.PublicKey, spk.Signature, time.Now().UnixMilli()); err != nil {
		return err
	}
	if _, err := tx.Exec(`INSERT INTO kyber_prekeys (account_id, device_id, key_id, public_key, signature, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT (account_id, device_id) DO UPDATE SET key_id = excluded.key_id,
            public_key = excluded.public_key, signature = excluded.signature, created_at = excluded.created_at`,
		accountID, deviceID, kyber.KeyID, kyber.PublicKey, kyber.Signature, time.Now().UnixMilli()); err != nil {
		return err
	}
	for _, k := range oneTime {
		if _, err := tx.Exec(`INSERT OR REPLACE INTO one_time_prekeys (account_id, device_id, key_id, public_key) VALUES (?, ?, ?, ?)`,
			accountID, deviceID, k.KeyID, k.PublicKey); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// OneTimePreKeyCount reports how many unconsumed one-time prekeys a device
// has left, so clients can decide when to replenish.
func (s *Store) OneTimePreKeyCount(accountID string, deviceID uint32) (int, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM one_time_prekeys WHERE account_id = ? AND device_id = ?`,
		accountID, deviceID).Scan(&n)
	return n, err
}

// TakePreKeyBundles returns a bundle for each requested device of the
// account (all devices when deviceIDs is nil), consuming one one-time
// prekey per bundle when available.
func (s *Store) TakePreKeyBundles(accountID string, deviceIDs []uint32) ([]PreKeyBundle, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	if deviceIDs == nil {
		rows, err := tx.Query(`SELECT device_id FROM devices WHERE account_id = ? ORDER BY device_id`, accountID)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var id uint32
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return nil, err
			}
			deviceIDs = append(deviceIDs, id)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return nil, err
		}
	}
	if len(deviceIDs) == 0 {
		return nil, ErrNotFound
	}

	var bundles []PreKeyBundle
	for _, devID := range deviceIDs {
		b := PreKeyBundle{DeviceID: devID}
		err := tx.QueryRow(`SELECT d.registration_id, d.identity_key, s.key_id, s.public_key, s.signature,
            k.key_id, k.public_key, k.signature
            FROM devices d
            JOIN signed_prekeys s ON s.account_id = d.account_id AND s.device_id = d.device_id
            JOIN kyber_prekeys k ON k.account_id = d.account_id AND k.device_id = d.device_id
            WHERE d.account_id = ? AND d.device_id = ? AND d.identity_key IS NOT NULL`,
			accountID, devID).Scan(&b.RegistrationID, &b.IdentityKey,
			&b.SignedPreKey.KeyID, &b.SignedPreKey.PublicKey, &b.SignedPreKey.Signature,
			&b.KyberPreKey.KeyID, &b.KyberPreKey.PublicKey, &b.KyberPreKey.Signature)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound // device unknown or hasn't uploaded keys yet
		}
		if err != nil {
			return nil, err
		}

		var otk OneTimePreKey
		err = tx.QueryRow(`SELECT key_id, public_key FROM one_time_prekeys
            WHERE account_id = ? AND device_id = ? ORDER BY key_id LIMIT 1`,
			accountID, devID).Scan(&otk.KeyID, &otk.PublicKey)
		switch {
		case errors.Is(err, sql.ErrNoRows):
			// Pool exhausted: degraded but valid — signed prekey only.
		case err != nil:
			return nil, err
		default:
			if _, err := tx.Exec(`DELETE FROM one_time_prekeys WHERE account_id = ? AND device_id = ? AND key_id = ?`,
				accountID, devID, otk.KeyID); err != nil {
				return nil, err
			}
			b.OneTime = &otk
		}
		bundles = append(bundles, b)
	}
	return bundles, tx.Commit()
}

// ---------------------------------------------------------------------------
// Offline message queue
// ---------------------------------------------------------------------------

// Enqueue stores a serialized envelope for a device until it is acked.
func (s *Store) Enqueue(envelopeID, accountID string, deviceID uint32, envelope []byte) error {
	_, err := s.db.Exec(`INSERT OR IGNORE INTO message_queue (envelope_id, account_id, device_id, envelope, created_at)
        VALUES (?, ?, ?, ?, ?)`,
		envelopeID, accountID, deviceID, envelope, time.Now().UnixMilli())
	return err
}

// QueuedEnvelopes returns all pending envelopes for a device, oldest first.
func (s *Store) QueuedEnvelopes(accountID string, deviceID uint32) ([][]byte, error) {
	rows, err := s.db.Query(`SELECT envelope FROM message_queue
        WHERE account_id = ? AND device_id = ? ORDER BY created_at, envelope_id`,
		accountID, deviceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out [][]byte
	for rows.Next() {
		var blob []byte
		if err := rows.Scan(&blob); err != nil {
			return nil, err
		}
		out = append(out, blob)
	}
	return out, rows.Err()
}

// Dequeue removes an envelope after the client has acked it.
func (s *Store) Dequeue(envelopeID, accountID string, deviceID uint32) error {
	_, err := s.db.Exec(`DELETE FROM message_queue WHERE envelope_id = ? AND account_id = ? AND device_id = ?`,
		envelopeID, accountID, deviceID)
	return err
}

// ---------------------------------------------------------------------------

func newUUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(fmt.Sprintf("store: crypto/rand failed: %v", err))
	}
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant 10
	dst := make([]byte, 36)
	hex.Encode(dst[0:8], b[0:4])
	dst[8] = '-'
	hex.Encode(dst[9:13], b[4:6])
	dst[13] = '-'
	hex.Encode(dst[14:18], b[6:8])
	dst[18] = '-'
	hex.Encode(dst[19:23], b[8:10])
	dst[23] = '-'
	hex.Encode(dst[24:36], b[10:16])
	return string(dst)
}

func isUniqueViolation(err error) bool {
	// modernc.org/sqlite reports SQLITE_CONSTRAINT_UNIQUE in the error text.
	return err != nil && strings.Contains(err.Error(), "constraint failed")
}
