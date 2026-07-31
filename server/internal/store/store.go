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
CREATE TABLE IF NOT EXISTS groups (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    distribution_id TEXT NOT NULL,   -- current sender-key epoch (uuid)
    revision        INTEGER NOT NULL,
    created_at      INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS group_members (
    group_id   TEXT NOT NULL REFERENCES groups(id),
    account_id TEXT NOT NULL,
    PRIMARY KEY (group_id, account_id)
);
CREATE INDEX IF NOT EXISTS idx_group_members_account
    ON group_members (account_id);
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

// APNSToken returns the device's APNs token, or "" if it hasn't registered one.
func (s *Store) APNSToken(accountID string, deviceID uint32) (string, error) {
	var token sql.NullString
	err := s.db.QueryRow(
		`SELECT apns_token FROM devices WHERE account_id = ? AND device_id = ?`,
		accountID, deviceID,
	).Scan(&token)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	return token.String, nil
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
// Groups (server-stored roster)
// ---------------------------------------------------------------------------

var ErrNotMember = errors.New("store: not a group member")

type Group struct {
	ID             string
	Name           string
	DistributionID string
	Revision       int64
	Members        []string
}

func (s *Store) group(tx *sql.Tx, groupID string) (*Group, error) {
	g := &Group{ID: groupID}
	err := tx.QueryRow(`SELECT name, distribution_id, revision FROM groups WHERE id = ?`, groupID).
		Scan(&g.Name, &g.DistributionID, &g.Revision)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	rows, err := tx.Query(`SELECT account_id FROM group_members WHERE group_id = ? ORDER BY account_id`, groupID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var m string
		if err := rows.Scan(&m); err != nil {
			return nil, err
		}
		g.Members = append(g.Members, m)
	}
	return g, rows.Err()
}

func (g *Group) hasMember(accountID string) bool {
	for _, m := range g.Members {
		if m == accountID {
			return true
		}
	}
	return false
}

// CreateGroup creates a group whose members are the creator plus `members`.
func (s *Store) CreateGroup(creator, name string, members []string) (*Group, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	id, dist, now := newUUID(), newUUID(), time.Now().UnixMilli()
	if _, err := tx.Exec(`INSERT INTO groups (id, name, distribution_id, revision, created_at) VALUES (?, ?, ?, 1, ?)`,
		id, name, dist, now); err != nil {
		return nil, err
	}
	roster := map[string]bool{creator: true}
	for _, m := range members {
		roster[m] = true
	}
	for m := range roster {
		if _, err := tx.Exec(`INSERT INTO group_members (group_id, account_id) VALUES (?, ?)`, id, m); err != nil {
			return nil, err
		}
	}
	g, err := s.group(tx, id)
	if err != nil {
		return nil, err
	}
	return g, tx.Commit()
}

// GetGroup returns the group if `requester` is a member.
func (s *Store) GetGroup(groupID, requester string) (*Group, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	g, err := s.group(tx, groupID)
	if err != nil {
		return nil, err
	}
	if !g.hasMember(requester) {
		return nil, ErrNotMember
	}
	return g, tx.Commit()
}

// AddMember adds `target`; the requester must be a member. Adding does not
// rotate the sender key (new members can't rewind the ratchet).
func (s *Store) AddMember(groupID, requester, target string) (*Group, error) {
	return s.mutateGroup(groupID, requester, false, func(tx *sql.Tx) error {
		_, err := tx.Exec(`INSERT OR IGNORE INTO group_members (group_id, account_id) VALUES (?, ?)`, groupID, target)
		return err
	})
}

// RemoveMember removes `target` and rotates the sender-key epoch so the
// removed member can't read future messages. `leave` allows removing self.
func (s *Store) RemoveMember(groupID, requester, target string) (*Group, error) {
	return s.mutateGroup(groupID, requester, true, func(tx *sql.Tx) error {
		_, err := tx.Exec(`DELETE FROM group_members WHERE group_id = ? AND account_id = ?`, groupID, target)
		return err
	})
}

// RenameGroup sets a new name.
func (s *Store) RenameGroup(groupID, requester, name string) (*Group, error) {
	return s.mutateGroup(groupID, requester, false, func(tx *sql.Tx) error {
		_, err := tx.Exec(`UPDATE groups SET name = ? WHERE id = ?`, name, groupID)
		return err
	})
}

// mutateGroup applies `change` inside a transaction after verifying the
// requester is a member, bumps the revision, optionally rotates the
// distribution id, and returns the updated group.
func (s *Store) mutateGroup(groupID, requester string, rotate bool, change func(*sql.Tx) error) (*Group, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	g, err := s.group(tx, groupID)
	if err != nil {
		return nil, err
	}
	if !g.hasMember(requester) {
		return nil, ErrNotMember
	}
	if err := change(tx); err != nil {
		return nil, err
	}
	if rotate {
		if _, err := tx.Exec(`UPDATE groups SET distribution_id = ? WHERE id = ?`, newUUID(), groupID); err != nil {
			return nil, err
		}
	}
	if _, err := tx.Exec(`UPDATE groups SET revision = revision + 1 WHERE id = ?`, groupID); err != nil {
		return nil, err
	}
	updated, err := s.group(tx, groupID)
	if err != nil {
		return nil, err
	}
	return updated, tx.Commit()
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
