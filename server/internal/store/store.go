// Package store is the relay's persistence layer, backed by PostgreSQL.
//
// The relay stores only what it must to route ciphertext: accounts,
// devices, public prekey material, and queued (still-encrypted) envelopes
// awaiting delivery. No plaintext, no private keys, ever.
package store

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"
)

var (
	ErrNotFound                  = errors.New("store: not found")
	ErrUsernameTaken             = errors.New("store: username already taken")
	ErrAuthFailed                = errors.New("store: authentication failed")
	ErrNotMember                 = errors.New("store: not a group member")
	ErrNotAdmin                  = errors.New("store: not a group admin")
	ErrGroupFull                 = errors.New("store: group member limit reached")
	ErrQueueFull                 = errors.New("store: queue full")
	ErrEnvelopeTooLarge          = errors.New("store: envelope too large")
	ErrDeviceListVersionMismatch = errors.New("store: device list version mismatch")
	ErrDuplicateNukeCommand      = errors.New("store: nuke command already executed")
)

const maxGroupMembers = 256

const (
	queueTTLMillis         = int64((30 * 24 * time.Hour) / time.Millisecond)
	maxQueuedEnvelopeBytes = 512 * 1024
	maxQueuedPerDevice     = 500
)

type Store struct {
	db *pgxpool.Pool
}

// Open connects to PostgreSQL at dsn, pings it, and runs schema migrations.
// dsn format: postgres://user:password@host:5432/dbname?sslmode=require
func Open(dsn string) (*Store, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	cfg.MaxConns = 20
	cfg.MinConns = 2
	cfg.ConnConfig.Config.DialFunc = func(ctx context.Context, network, addr string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(addr)
		if err != nil {
			return nil, err
		}
		ips, err := net.DefaultResolver.LookupHost(ctx, host)
		if err != nil {
			return nil, err
		}
		var ipv4 string
		for _, ip := range ips {
			if net.ParseIP(ip).To4() != nil {
				ipv4 = ip
				break
			}
		}
		if ipv4 == "" {
			return nil, fmt.Errorf("store: no IPv4 address for %s", host)
		}
		return (&net.Dialer{}).DialContext(ctx, "tcp4", net.JoinHostPort(ipv4, port))
	}

	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(context.Background()); err != nil {
		pool.Close()
		return nil, fmt.Errorf("store: cannot reach postgres: %w", err)
	}
	s := &Store{db: pool}
	if err := s.migrate(); err != nil {
		pool.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { s.db.Close(); return nil }

func (s *Store) migrate() error {
	ctx := context.Background()
	_, err := s.db.Exec(ctx, `
CREATE TABLE IF NOT EXISTS accounts (
    id            TEXT PRIMARY KEY,
    username      TEXT NOT NULL UNIQUE,
    device_list_version BIGINT NOT NULL DEFAULT 0,
    created_at    BIGINT NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
    account_id      TEXT NOT NULL REFERENCES accounts(id),
    device_id       INTEGER NOT NULL,
    mailbox_id      TEXT,
    password_hash   BYTEA NOT NULL,
    registration_id INTEGER NOT NULL DEFAULT 0,
    identity_key    BYTEA,
    auth_public_key BYTEA,
    apns_token      TEXT,
    voip_token      TEXT,
    created_at      BIGINT NOT NULL,
    PRIMARY KEY (account_id, device_id)
);
CREATE TABLE IF NOT EXISTS signed_prekeys (
    account_id  TEXT NOT NULL,
    device_id   INTEGER NOT NULL,
    key_id      INTEGER NOT NULL,
    public_key  BYTEA NOT NULL,
    signature   BYTEA NOT NULL,
    created_at  BIGINT NOT NULL,
    PRIMARY KEY (account_id, device_id),
    FOREIGN KEY (account_id, device_id) REFERENCES devices(account_id, device_id)
);
CREATE TABLE IF NOT EXISTS kyber_prekeys (
    account_id  TEXT NOT NULL,
    device_id   INTEGER NOT NULL,
    key_id      INTEGER NOT NULL,
    public_key  BYTEA NOT NULL,
    signature   BYTEA NOT NULL,
    created_at  BIGINT NOT NULL,
    PRIMARY KEY (account_id, device_id),
    FOREIGN KEY (account_id, device_id) REFERENCES devices(account_id, device_id)
);
CREATE TABLE IF NOT EXISTS one_time_prekeys (
    account_id  TEXT NOT NULL,
    device_id   INTEGER NOT NULL,
    key_id      INTEGER NOT NULL,
    public_key  BYTEA NOT NULL,
    PRIMARY KEY (account_id, device_id, key_id),
    FOREIGN KEY (account_id, device_id) REFERENCES devices(account_id, device_id)
);
CREATE TABLE IF NOT EXISTS message_queue (
    envelope_id TEXT NOT NULL,
    account_id  TEXT NOT NULL,
    device_id   INTEGER NOT NULL,
    envelope    BYTEA NOT NULL,
    created_at  BIGINT NOT NULL,
    PRIMARY KEY (envelope_id, account_id, device_id)
);
CREATE INDEX IF NOT EXISTS idx_queue_recipient
    ON message_queue (account_id, device_id, created_at);
CREATE TABLE IF NOT EXISTS device_link_tokens (
    token      TEXT PRIMARY KEY,
    account_id TEXT NOT NULL,
    password   TEXT NOT NULL,
    code       TEXT NOT NULL,
    expected_version BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    created_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_device_link_tokens_expires
    ON device_link_tokens (expires_at);
CREATE TABLE IF NOT EXISTS nuke_commands (
    command_id           TEXT PRIMARY KEY,
    account_id           TEXT NOT NULL,
    creation_time_ms     BIGINT NOT NULL,
    initiating_device_id INTEGER NOT NULL,
    signature            BYTEA NOT NULL,
    created_at           BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_nuke_commands_account ON nuke_commands (account_id);
CREATE TABLE IF NOT EXISTS groups (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    description     TEXT NOT NULL DEFAULT '',
    avatar_id       TEXT NOT NULL DEFAULT '',
    distribution_id TEXT NOT NULL,
    revision        BIGINT NOT NULL,
    created_at      BIGINT NOT NULL
);
CREATE TABLE IF NOT EXISTS group_members (
    group_id   TEXT NOT NULL REFERENCES groups(id),
    account_id TEXT NOT NULL,
    PRIMARY KEY (group_id, account_id)
);
CREATE INDEX IF NOT EXISTS idx_group_members_account
    ON group_members (account_id);
CREATE TABLE IF NOT EXISTS group_invites (
    token      TEXT PRIMARY KEY,
    group_id   TEXT NOT NULL REFERENCES groups(id),
    expires_at BIGINT NOT NULL DEFAULT 0
);
`)
	if err != nil {
		return err
	}
	// Additive migrations: safe to run on existing databases.
	for _, stmt := range []string{
		`ALTER TABLE devices ADD COLUMN IF NOT EXISTS mailbox_id TEXT`,
		`ALTER TABLE devices ADD COLUMN IF NOT EXISTS auth_public_key BYTEA`,
		`ALTER TABLE accounts ADD COLUMN IF NOT EXISTS device_list_version BIGINT NOT NULL DEFAULT 0`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_devices_mailbox_id ON devices (mailbox_id) WHERE mailbox_id IS NOT NULL`,
		`ALTER TABLE groups ADD COLUMN IF NOT EXISTS description TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE groups ADD COLUMN IF NOT EXISTS avatar_id   TEXT NOT NULL DEFAULT ''`,
		// Privacy: last_seen is now in-memory only — drop the persisted presence table.
		`DROP TABLE IF EXISTS presence`,
		// Privacy: drop metadata columns from group_invites that reveal who created
		// invite links and when. Only the token→group mapping is needed for routing.
		`ALTER TABLE group_invites DROP COLUMN IF EXISTS creator`,
		`ALTER TABLE group_invites DROP COLUMN IF EXISTS created_at`,
		// Admin roles and announce-only mode.
		`ALTER TABLE groups ADD COLUMN IF NOT EXISTS admins TEXT[] NOT NULL DEFAULT '{}'`,
		`ALTER TABLE groups ADD COLUMN IF NOT EXISTS announce_only BOOLEAN NOT NULL DEFAULT FALSE`,
		// Invite expiry: tokens older than 7 days are no longer valid.
		`ALTER TABLE group_invites ADD COLUMN IF NOT EXISTS expires_at BIGINT NOT NULL DEFAULT 0`,
		`CREATE INDEX IF NOT EXISTS idx_group_invites_expires_at ON group_invites (expires_at)`,
	} {
		if _, err := s.db.Exec(context.Background(), stmt); err != nil {
			return err
		}
	}
	return s.ensureMailboxIDs(ctx)
}

func (s *Store) ensureMailboxIDs(ctx context.Context) error {
	rows, err := s.db.Query(ctx, `SELECT account_id, device_id FROM devices WHERE mailbox_id IS NULL OR mailbox_id = ''`)
	if err != nil {
		return err
	}
	type deviceRef struct {
		accountID string
		deviceID  uint32
	}
	var devices []deviceRef
	for rows.Next() {
		var d deviceRef
		if err := rows.Scan(&d.accountID, &d.deviceID); err != nil {
			rows.Close()
			return err
		}
		devices = append(devices, d)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	for _, d := range devices {
		for {
			mailboxID, err := newMailboxID()
			if err != nil {
				return err
			}
			_, err = s.db.Exec(ctx, `
				UPDATE devices
				SET mailbox_id = $1
				WHERE account_id = $2 AND device_id = $3 AND (mailbox_id IS NULL OR mailbox_id = '')`,
				mailboxID, d.accountID, d.deviceID)
			if err == nil {
				break
			}
			if !isUniqueViolation(err) {
				return err
			}
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Accounts and devices
// ---------------------------------------------------------------------------

type Device struct {
	AccountID      string
	DeviceID       uint32
	MailboxID      string
	RegistrationID uint32
	AuthPublicKey  []byte
}

type DeviceLinkClaim struct {
	AccountID string
	DeviceID  uint32
	Password  string
	Username  string
}

// CreateAccount registers a new account and its primary device (device 1).
func (s *Store) CreateAccount(username, password string) (accountID string, deviceID uint32, err error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return "", 0, err
	}
	accountID = newUUID()
	mailboxID, err := newMailboxID()
	if err != nil {
		return "", 0, err
	}
	now := time.Now().UnixMilli()
	ctx := context.Background()

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return "", 0, err
	}
	defer tx.Rollback(ctx)

	if _, err = tx.Exec(ctx, `INSERT INTO accounts (id, username, created_at) VALUES ($1, $2, $3)`,
		accountID, username, now); err != nil {
		if isUniqueViolation(err) {
			return "", 0, ErrUsernameTaken
		}
		return "", 0, err
	}
	if _, err = tx.Exec(ctx, `INSERT INTO devices (account_id, device_id, mailbox_id, password_hash, created_at) VALUES ($1, 1, $2, $3, $4)`,
		accountID, mailboxID, hash, now); err != nil {
		return "", 0, err
	}
	return accountID, 1, tx.Commit(ctx)
}

// AddDevice registers an additional device for an existing account.
func (s *Store) AddDevice(accountID, password string, expectedVersion int64) (uint32, int64, error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return 0, 0, err
	}
	mailboxID, err := newMailboxID()
	if err != nil {
		return 0, 0, err
	}
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return 0, 0, err
	}
	defer tx.Rollback(ctx)

	var currentVersion int64
	if err := tx.QueryRow(ctx, `SELECT device_list_version FROM accounts WHERE id = $1 FOR UPDATE`, accountID).Scan(&currentVersion); errors.Is(err, pgx.ErrNoRows) {
		return 0, 0, ErrNotFound
	} else if err != nil {
		return 0, 0, err
	}
	if currentVersion != expectedVersion {
		return 0, 0, ErrDeviceListVersionMismatch
	}

	var next uint32
	if err := tx.QueryRow(ctx, `SELECT COALESCE(MAX(device_id), 0) + 1 FROM devices WHERE account_id = $1`, accountID).Scan(&next); err != nil {
		return 0, 0, err
	}
	if next == 1 {
		return 0, 0, ErrNotFound // account doesn't exist
	}
	if _, err := tx.Exec(ctx, `INSERT INTO devices (account_id, device_id, mailbox_id, password_hash, created_at) VALUES ($1, $2, $3, $4, $5)`,
		accountID, next, mailboxID, hash, time.Now().UnixMilli()); err != nil {
		return 0, 0, err
	}
	newVersion := currentVersion + 1
	if _, err := tx.Exec(ctx, `UPDATE accounts SET device_list_version = $1 WHERE id = $2`, newVersion, accountID); err != nil {
		return 0, 0, err
	}
	return next, newVersion, tx.Commit(ctx)
}

func (s *Store) CreateDeviceLinkToken(accountID string, password string, expectedVersion int64) (token string, code string, expiresAt int64, err error) {
	token, err = newSecureToken(32)
	if err != nil {
		return "", "", 0, err
	}
	code, err = newVerificationCode()
	if err != nil {
		return "", "", 0, err
	}
	now := time.Now().UnixMilli()
	expiresAt = now + int64((10*time.Minute)/time.Millisecond)
	ctx := context.Background()

	// Use a transaction with FOR UPDATE so the version check and token insert
	// are atomic. Without this, two concurrent calls could both pass the version
	// check and store tokens with the same expectedVersion, leading to
	// ClaimDeviceLinkToken seeing an unexpected version and rejecting the claim.
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return "", "", 0, err
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx, `DELETE FROM device_link_tokens WHERE expires_at < $1`, now); err != nil {
		return "", "", 0, err
	}
	var currentVersion int64
	if err := tx.QueryRow(ctx, `SELECT device_list_version FROM accounts WHERE id = $1 FOR UPDATE`, accountID).Scan(&currentVersion); errors.Is(err, pgx.ErrNoRows) {
		return "", "", 0, ErrNotFound
	} else if err != nil {
		return "", "", 0, err
	}
	if currentVersion != expectedVersion {
		return "", "", 0, ErrDeviceListVersionMismatch
	}
	if _, err := tx.Exec(ctx, `INSERT INTO device_link_tokens (token, account_id, password, code, expected_version, expires_at, created_at) VALUES ($1, $2, $3, $4, $5, $6, $7)`,
		token, accountID, password, code, expectedVersion, expiresAt, now); err != nil {
		return "", "", 0, err
	}
	return token, code, expiresAt, tx.Commit(ctx)
}

func (s *Store) ClaimDeviceLinkToken(token string, code string) (*DeviceLinkClaim, error) {
	now := time.Now().UnixMilli()
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `DELETE FROM device_link_tokens WHERE expires_at < $1`, now); err != nil {
		return nil, err
	}
	var claim DeviceLinkClaim
	var expiresAt int64
	var expectedVersion int64
	err = tx.QueryRow(ctx, `
		DELETE FROM device_link_tokens
		WHERE token = $1 AND code = $2
		RETURNING account_id, password, expected_version, expires_at`,
		token, code,
	).Scan(&claim.AccountID, &claim.Password, &expectedVersion, &expiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if expiresAt < now {
		return nil, ErrNotFound
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(claim.Password), bcrypt.DefaultCost)
	if err != nil {
		return nil, err
	}
	mailboxID, err := newMailboxID()
	if err != nil {
		return nil, err
	}
	var currentVersion int64
	if err := tx.QueryRow(ctx, `SELECT device_list_version FROM accounts WHERE id = $1 FOR UPDATE`, claim.AccountID).Scan(&currentVersion); err != nil {
		return nil, err
	}
	if currentVersion != expectedVersion {
		return nil, ErrDeviceListVersionMismatch
	}
	if err := tx.QueryRow(ctx, `SELECT COALESCE(MAX(device_id), 0) + 1 FROM devices WHERE account_id = $1`, claim.AccountID).Scan(&claim.DeviceID); err != nil {
		return nil, err
	}
	if claim.DeviceID == 1 {
		return nil, ErrNotFound
	}
	if _, err := tx.Exec(ctx, `INSERT INTO devices (account_id, device_id, mailbox_id, password_hash, created_at) VALUES ($1, $2, $3, $4, $5)`,
		claim.AccountID, claim.DeviceID, mailboxID, hash, now); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `UPDATE accounts SET device_list_version = $1 WHERE id = $2`, currentVersion+1, claim.AccountID); err != nil {
		return nil, err
	}
	if err := tx.QueryRow(ctx, `SELECT username FROM accounts WHERE id = $1`, claim.AccountID).Scan(&claim.Username); err != nil {
		return nil, err
	}
	return &claim, tx.Commit(ctx)
}

// Authenticate verifies device credentials and returns the device row.
func (s *Store) Authenticate(accountID string, deviceID uint32, password string) (*Device, error) {
	ctx := context.Background()
	var hash []byte
	var regID uint32
	var mailboxID string
	var authPublicKey []byte
	err := s.db.QueryRow(ctx, `SELECT password_hash, registration_id, COALESCE(mailbox_id, ''), auth_public_key FROM devices WHERE account_id = $1 AND device_id = $2`,
		accountID, deviceID).Scan(&hash, &regID, &mailboxID, &authPublicKey)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrAuthFailed
	}
	if err != nil {
		return nil, err
	}
	if bcrypt.CompareHashAndPassword(hash, []byte(password)) != nil {
		return nil, ErrAuthFailed
	}
	return &Device{AccountID: accountID, DeviceID: deviceID, MailboxID: mailboxID, RegistrationID: regID, AuthPublicKey: authPublicKey}, nil
}

func (s *Store) DeviceListVersion(accountID string) (int64, error) {
	ctx := context.Background()
	var version int64
	err := s.db.QueryRow(ctx, `SELECT device_list_version FROM accounts WHERE id = $1`, accountID).Scan(&version)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, ErrNotFound
	}
	return version, err
}

// ListDevices returns all devices for the given account.
func (s *Store) ListDevices(accountID string) ([]Device, error) {
	ctx := context.Background()
	rows, err := s.db.Query(ctx, `SELECT device_id, registration_id, COALESCE(mailbox_id, '') FROM devices WHERE account_id = $1 ORDER BY device_id`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var devices []Device
	for rows.Next() {
		var d Device
		d.AccountID = accountID
		if err := rows.Scan(&d.DeviceID, &d.RegistrationID, &d.MailboxID); err != nil {
			return nil, err
		}
		devices = append(devices, d)
	}
	return devices, rows.Err()
}

// RemoveDevice deletes a device from an account. Device 1 (primary) cannot be removed.
func (s *Store) RemoveDevice(accountID string, deviceID uint32, expectedVersion int64) (int64, error) {
	if deviceID == 1 {
		return 0, errors.New("store: cannot remove primary device")
	}
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)

	var currentVersion int64
	if err := tx.QueryRow(ctx, `SELECT device_list_version FROM accounts WHERE id = $1 FOR UPDATE`, accountID).Scan(&currentVersion); errors.Is(err, pgx.ErrNoRows) {
		return 0, ErrNotFound
	} else if err != nil {
		return 0, err
	}
	if currentVersion != expectedVersion {
		return 0, ErrDeviceListVersionMismatch
	}

	tag, err := tx.Exec(ctx, `DELETE FROM devices WHERE account_id = $1 AND device_id = $2`, accountID, deviceID)
	if err != nil {
		return 0, err
	}
	if tag.RowsAffected() == 0 {
		return 0, ErrNotFound
	}
	newVersion := currentVersion + 1
	if _, err := tx.Exec(ctx, `UPDATE accounts SET device_list_version = $1 WHERE id = $2`, newVersion, accountID); err != nil {
		return 0, err
	}
	return newVersion, tx.Commit(ctx)
}

// LookupAccountID resolves a username to an account id.
func (s *Store) LookupAccountID(username string) (string, error) {
	ctx := context.Background()
	var id string
	err := s.db.QueryRow(ctx, `SELECT id FROM accounts WHERE username = $1`, username).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	return id, err
}

// UpdateUsername changes the username of an account. Returns ErrUsernameTaken
// if the new username is already in use by a different account.
func (s *Store) UpdateUsername(accountID, newUsername string) error {
	ctx := context.Background()
	_, err := s.db.Exec(ctx,
		`UPDATE accounts SET username = $1 WHERE id = $2`,
		newUsername, accountID)
	if err != nil && isUniqueViolation(err) {
		return ErrUsernameTaken
	}
	return err
}

// LookupUsername resolves an account id to its username.
func (s *Store) LookupUsername(accountID string) (string, error) {
	ctx := context.Background()
	var username string
	err := s.db.QueryRow(ctx, `SELECT username FROM accounts WHERE id = $1`, accountID).Scan(&username)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	return username, err
}

// Devices returns all devices registered to an account.
func (s *Store) Devices(accountID string) ([]Device, error) {
	ctx := context.Background()
	rows, err := s.db.Query(ctx, `SELECT device_id, registration_id, COALESCE(mailbox_id, '') FROM devices WHERE account_id = $1 ORDER BY device_id`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Device
	for rows.Next() {
		d := Device{AccountID: accountID}
		if err := rows.Scan(&d.DeviceID, &d.RegistrationID, &d.MailboxID); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// DeviceByMailbox resolves an opaque mailbox id to its current routing row.
func (s *Store) DeviceByMailbox(mailboxID string) (*Device, error) {
	ctx := context.Background()
	var d Device
	err := s.db.QueryRow(ctx, `
		SELECT account_id, device_id, registration_id, COALESCE(mailbox_id, '')
		FROM devices
		WHERE mailbox_id = $1`,
		mailboxID,
	).Scan(&d.AccountID, &d.DeviceID, &d.RegistrationID, &d.MailboxID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &d, nil
}

func (s *Store) SetAPNSToken(accountID string, deviceID uint32, token string) error {
	ctx := context.Background()
	_, err := s.db.Exec(ctx, `UPDATE devices SET apns_token = $1 WHERE account_id = $2 AND device_id = $3`,
		token, accountID, deviceID)
	return err
}


// APNSToken returns the device's APNs token, or "" if not registered.
func (s *Store) APNSToken(accountID string, deviceID uint32) (string, error) {
	ctx := context.Background()
	var token *string
	err := s.db.QueryRow(ctx,
		`SELECT apns_token FROM devices WHERE account_id = $1 AND device_id = $2`,
		accountID, deviceID,
	).Scan(&token)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	if token == nil {
		return "", nil
	}
	return *token, nil
}

func (s *Store) SetVoIPToken(accountID string, deviceID uint32, token string) error {
	ctx := context.Background()
	_, err := s.db.Exec(ctx, `UPDATE devices SET voip_token = $1 WHERE account_id = $2 AND device_id = $3`,
		token, accountID, deviceID)
	return err
}

// SetDeviceAuthKey stores the public half of a device's platform-backed
// authorization key. It is used by later stages to authorize device-list
// changes without relying on the server alone.
func (s *Store) SetDeviceAuthKey(accountID string, deviceID uint32, publicKey []byte) error {
	ctx := context.Background()
	tag, err := s.db.Exec(ctx, `UPDATE devices SET auth_public_key = $1 WHERE account_id = $2 AND device_id = $3`,
		publicKey, accountID, deviceID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// DeviceAuthKey returns the auth public key for a device in an account, or
// ErrNotFound if the device doesn't exist or has no key set.
func (s *Store) DeviceAuthKey(accountID string, deviceID uint32) ([]byte, error) {
	ctx := context.Background()
	var key []byte
	err := s.db.QueryRow(ctx,
		`SELECT auth_public_key FROM devices WHERE account_id = $1 AND device_id = $2`,
		accountID, deviceID,
	).Scan(&key)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if len(key) == 0 {
		return nil, ErrNotFound
	}
	return key, nil
}

// VoIPToken returns the device's PushKit VoIP token, or "" if unregistered.
func (s *Store) VoIPToken(accountID string, deviceID uint32) (string, error) {
	ctx := context.Background()
	var token *string
	err := s.db.QueryRow(ctx,
		`SELECT voip_token FROM devices WHERE account_id = $1 AND device_id = $2`,
		accountID, deviceID,
	).Scan(&token)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	if token == nil {
		return "", nil
	}
	return *token, nil
}

// VoIPTokensForAccount returns all VoIP tokens registered for any device of an account.
func (s *Store) VoIPTokensForAccount(accountID string) ([]string, error) {
	ctx := context.Background()
	rows, err := s.db.Query(ctx,
		`SELECT voip_token FROM devices WHERE account_id = $1 AND voip_token IS NOT NULL AND voip_token != ''`,
		accountID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var tokens []string
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err == nil {
			tokens = append(tokens, t)
		}
	}
	return tokens, rows.Err()
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
type PreKeyBundle struct {
	DeviceID       uint32
	MailboxID      string
	RegistrationID uint32
	IdentityKey    []byte
	SignedPreKey   SignedPreKey
	KyberPreKey    SignedPreKey
	OneTime        *OneTimePreKey
}

// SetKeys replaces the device's identity key, registration id, signed prekey
// and last-resort Kyber prekey, and appends one-time prekeys to its pool.
func (s *Store) SetKeys(accountID string, deviceID uint32, registrationID uint32, identityKey []byte, spk SignedPreKey, kyber SignedPreKey, oneTime []OneTimePreKey) error {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	tag, err := tx.Exec(ctx, `UPDATE devices SET registration_id = $1, identity_key = $2 WHERE account_id = $3 AND device_id = $4`,
		registrationID, identityKey, accountID, deviceID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO signed_prekeys (account_id, device_id, key_id, public_key, signature, created_at)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (account_id, device_id) DO UPDATE SET
			key_id = EXCLUDED.key_id, public_key = EXCLUDED.public_key,
			signature = EXCLUDED.signature, created_at = EXCLUDED.created_at`,
		accountID, deviceID, spk.KeyID, spk.PublicKey, spk.Signature, time.Now().UnixMilli()); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO kyber_prekeys (account_id, device_id, key_id, public_key, signature, created_at)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (account_id, device_id) DO UPDATE SET
			key_id = EXCLUDED.key_id, public_key = EXCLUDED.public_key,
			signature = EXCLUDED.signature, created_at = EXCLUDED.created_at`,
		accountID, deviceID, kyber.KeyID, kyber.PublicKey, kyber.Signature, time.Now().UnixMilli()); err != nil {
		return err
	}
	for _, k := range oneTime {
		if _, err := tx.Exec(ctx, `
			INSERT INTO one_time_prekeys (account_id, device_id, key_id, public_key)
			VALUES ($1, $2, $3, $4)
			ON CONFLICT (account_id, device_id, key_id) DO UPDATE SET public_key = EXCLUDED.public_key`,
			accountID, deviceID, k.KeyID, k.PublicKey); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// OneTimePreKeyCount reports how many unconsumed one-time prekeys a device has.
func (s *Store) OneTimePreKeyCount(accountID string, deviceID uint32) (int, error) {
	ctx := context.Background()
	var n int
	err := s.db.QueryRow(ctx, `SELECT COUNT(*) FROM one_time_prekeys WHERE account_id = $1 AND device_id = $2`,
		accountID, deviceID).Scan(&n)
	return n, err
}

// TakePreKeyBundles returns a bundle for each requested device, consuming one
// one-time prekey per bundle when available.
func (s *Store) TakePreKeyBundles(accountID string, deviceIDs []uint32) ([]PreKeyBundle, error) {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	if deviceIDs == nil {
		rows, err := tx.Query(ctx, `SELECT device_id FROM devices WHERE account_id = $1 ORDER BY device_id`, accountID)
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
		err := tx.QueryRow(ctx, `
			SELECT d.registration_id, COALESCE(d.mailbox_id, ''), d.identity_key,
			       s.key_id, s.public_key, s.signature,
			       k.key_id, k.public_key, k.signature
			FROM devices d
			JOIN signed_prekeys s ON s.account_id = d.account_id AND s.device_id = d.device_id
			JOIN kyber_prekeys  k ON k.account_id = d.account_id AND k.device_id = d.device_id
			WHERE d.account_id = $1 AND d.device_id = $2 AND d.identity_key IS NOT NULL`,
			accountID, devID).Scan(
			&b.RegistrationID, &b.MailboxID, &b.IdentityKey,
			&b.SignedPreKey.KeyID, &b.SignedPreKey.PublicKey, &b.SignedPreKey.Signature,
			&b.KyberPreKey.KeyID, &b.KyberPreKey.PublicKey, &b.KyberPreKey.Signature)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		if err != nil {
			return nil, err
		}

		var otk OneTimePreKey
		err = tx.QueryRow(ctx, `
			SELECT key_id, public_key FROM one_time_prekeys
			WHERE account_id = $1 AND device_id = $2
			ORDER BY key_id LIMIT 1`,
			accountID, devID).Scan(&otk.KeyID, &otk.PublicKey)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			// Pool exhausted: degraded but valid.
		case err != nil:
			return nil, err
		default:
			if _, err := tx.Exec(ctx, `DELETE FROM one_time_prekeys WHERE account_id = $1 AND device_id = $2 AND key_id = $3`,
				accountID, devID, otk.KeyID); err != nil {
				return nil, err
			}
			b.OneTime = &otk
		}
		bundles = append(bundles, b)
	}
	return bundles, tx.Commit(ctx)
}

// ---------------------------------------------------------------------------
// Offline message queue
// ---------------------------------------------------------------------------

// Enqueue stores a serialized envelope for a device until it is acked.
func (s *Store) Enqueue(envelopeID, accountID string, deviceID uint32, envelope []byte) error {
	ctx := context.Background()
	if len(envelope) > maxQueuedEnvelopeBytes {
		return ErrEnvelopeTooLarge
	}
	if err := s.deleteExpiredQueuedEnvelopes(ctx); err != nil {
		return err
	}
	var queued int
	if err := s.db.QueryRow(ctx,
		`SELECT COUNT(*) FROM message_queue WHERE account_id = $1 AND device_id = $2`,
		accountID, deviceID).Scan(&queued); err != nil {
		return err
	}
	if queued >= maxQueuedPerDevice {
		return ErrQueueFull
	}
	_, err := s.db.Exec(ctx, `
		INSERT INTO message_queue (envelope_id, account_id, device_id, envelope, created_at)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (envelope_id, account_id, device_id) DO NOTHING`,
		envelopeID, accountID, deviceID, envelope, time.Now().UnixMilli())
	return err
}

// QueuedEnvelopes returns all pending envelopes for a device, oldest first.
func (s *Store) QueuedEnvelopes(accountID string, deviceID uint32) ([][]byte, error) {
	ctx := context.Background()
	if err := s.deleteExpiredQueuedEnvelopes(ctx); err != nil {
		return nil, err
	}
	rows, err := s.db.Query(ctx, `
		SELECT envelope FROM message_queue
		WHERE account_id = $1 AND device_id = $2
		ORDER BY created_at, envelope_id`,
		accountID, deviceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out [][]byte
	for rows.Next() {
		var b []byte
		if err := rows.Scan(&b); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

// Dequeue removes an envelope after the client has acked it.
func (s *Store) Dequeue(envelopeID, accountID string, deviceID uint32) error {
	ctx := context.Background()
	_, err := s.db.Exec(ctx, `DELETE FROM message_queue WHERE envelope_id = $1 AND account_id = $2 AND device_id = $3`,
		envelopeID, accountID, deviceID)
	return err
}

func (s *Store) deleteExpiredQueuedEnvelopes(ctx context.Context) error {
	cutoff := time.Now().UnixMilli() - queueTTLMillis
	if _, err := s.db.Exec(ctx, `DELETE FROM message_queue WHERE created_at < $1`, cutoff); err != nil {
		return err
	}
	// Also prune expired group invite tokens.
	_, err := s.db.Exec(ctx, `DELETE FROM group_invites WHERE expires_at > 0 AND expires_at < $1`, time.Now().UnixMilli())
	return err
}

// ---------------------------------------------------------------------------
// Groups (server-stored roster)
// ---------------------------------------------------------------------------

type Group struct {
	ID             string
	Name           string
	Description    string
	AvatarID       string
	DistributionID string
	Revision       int64
	Members        []string
	Admins         []string
	AnnounceOnly   bool
}

func (s *Store) group(ctx context.Context, tx pgx.Tx, groupID string) (*Group, error) {
	g := &Group{ID: groupID}
	err := tx.QueryRow(ctx, `SELECT name, description, avatar_id, distribution_id, revision, COALESCE(admins, '{}'), COALESCE(announce_only, false) FROM groups WHERE id = $1`, groupID).
		Scan(&g.Name, &g.Description, &g.AvatarID, &g.DistributionID, &g.Revision, &g.Admins, &g.AnnounceOnly)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	rows, err := tx.Query(ctx, `SELECT account_id FROM group_members WHERE group_id = $1 ORDER BY account_id`, groupID)
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

func (g *Group) hasAdmin(accountID string) bool {
	for _, a := range g.Admins {
		if a == accountID {
			return true
		}
	}
	return false
}

// CreateGroup creates a group whose members are the creator plus `members`.
func (s *Store) CreateGroup(creator, name string, members []string) (*Group, error) {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	id, dist, now := newUUID(), newUUID(), time.Now().UnixMilli()
	if _, err := tx.Exec(ctx, `INSERT INTO groups (id, name, distribution_id, revision, admins, created_at) VALUES ($1, $2, $3, 1, $4, $5)`,
		id, name, dist, []string{creator}, now); err != nil {
		return nil, err
	}
	roster := map[string]bool{creator: true}
	for _, m := range members {
		roster[m] = true
	}
	for m := range roster {
		if _, err := tx.Exec(ctx, `INSERT INTO group_members (group_id, account_id) VALUES ($1, $2)`, id, m); err != nil {
			return nil, err
		}
	}
	g, err := s.group(ctx, tx, id)
	if err != nil {
		return nil, err
	}
	return g, tx.Commit(ctx)
}

// GetGroup returns the group if `requester` is a member.
func (s *Store) GetGroup(groupID, requester string) (*Group, error) {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	g, err := s.group(ctx, tx, groupID)
	if err != nil {
		return nil, err
	}
	if !g.hasMember(requester) {
		return nil, ErrNotMember
	}
	return g, tx.Commit(ctx)
}

// AddMember adds `target`; the requester must be an admin.
func (s *Store) AddMember(groupID, requester, target string) (*Group, error) {
	return s.mutateGroupAdminRequired(groupID, requester, false, func(ctx context.Context, tx pgx.Tx) error {
		var count int
		if err := tx.QueryRow(ctx,
			`SELECT COUNT(*) FROM group_members WHERE group_id = $1`, groupID).Scan(&count); err != nil {
			return err
		}
		if count >= maxGroupMembers {
			return ErrGroupFull
		}
		_, err := tx.Exec(ctx,
			`INSERT INTO group_members (group_id, account_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
			groupID, target)
		return err
	})
}

// RemoveMember removes `target` and rotates the sender-key epoch; requester must be an admin.
func (s *Store) RemoveMember(groupID, requester, target string) (*Group, error) {
	return s.mutateGroupAdminRequired(groupID, requester, true, func(ctx context.Context, tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM group_members WHERE group_id = $1 AND account_id = $2`, groupID, target)
		return err
	})
}

// RenameGroup sets a new name; requester must be an admin.
func (s *Store) RenameGroup(groupID, requester, name string) (*Group, error) {
	return s.mutateGroupAdminRequired(groupID, requester, false, func(ctx context.Context, tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE groups SET name = $1 WHERE id = $2`, name, groupID)
		return err
	})
}

// SetGroupDescription sets the group's description text; requester must be an admin.
func (s *Store) SetGroupDescription(groupID, requester, description string) (*Group, error) {
	return s.mutateGroupAdminRequired(groupID, requester, false, func(ctx context.Context, tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE groups SET description = $1 WHERE id = $2`, description, groupID)
		return err
	})
}

// SetGroupAvatar stores the blob id pointing to the group's avatar; requester must be an admin.
func (s *Store) SetGroupAvatar(groupID, requester, avatarID string) (*Group, error) {
	return s.mutateGroupAdminRequired(groupID, requester, false, func(ctx context.Context, tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE groups SET avatar_id = $1 WHERE id = $2`, avatarID, groupID)
		return err
	})
}

const groupInviteTTL = 7 * 24 * time.Hour

// CreateGroupInvite generates a single-use invite token for `groupID`.
// The creator's account ID is intentionally not stored to avoid metadata retention.
// Tokens expire after 7 days.
func (s *Store) CreateGroupInvite(groupID, callerAccountID string) (string, error) {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback(ctx)
	g, err := s.group(ctx, tx, groupID)
	if err != nil {
		return "", err
	}
	if !g.hasMember(callerAccountID) {
		return "", ErrNotMember
	}
	token := newUUID()
	expiresAt := time.Now().Add(groupInviteTTL).UnixMilli()
	if _, err := tx.Exec(ctx,
		`INSERT INTO group_invites (token, group_id, expires_at) VALUES ($1, $2, $3)`,
		token, groupID, expiresAt); err != nil {
		return "", err
	}
	return token, tx.Commit(ctx)
}

// JoinGroupByInvite adds `joiner` to the group identified by `token`,
// consuming the token (single-use).
func (s *Store) JoinGroupByInvite(token, joiner string) (*Group, error) {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	var groupID string
	now := time.Now().UnixMilli()
	// expires_at = 0 means the row predates invite expiry (migration default) and
	// is treated as non-expiring for backward compatibility. Positive values are
	// treated as millisecond Unix timestamps that must be in the future.
	err = tx.QueryRow(ctx,
		`DELETE FROM group_invites WHERE token = $1 AND (expires_at = 0 OR expires_at > $2) RETURNING group_id`,
		token, now).Scan(&groupID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	var memberCount int
	if err := tx.QueryRow(ctx,
		`SELECT COUNT(*) FROM group_members WHERE group_id = $1`, groupID).Scan(&memberCount); err != nil {
		return nil, err
	}
	if memberCount >= maxGroupMembers {
		return nil, ErrGroupFull
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO group_members (group_id, account_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
		groupID, joiner); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `UPDATE groups SET revision = revision + 1 WHERE id = $1`, groupID); err != nil {
		return nil, err
	}
	g, err := s.group(ctx, tx, groupID)
	if err != nil {
		return nil, err
	}
	return g, tx.Commit(ctx)
}

func (s *Store) mutateGroup(groupID, requester string, rotate bool, change func(context.Context, pgx.Tx) error) (*Group, error) {
	return s.mutateGroupAdminOpt(groupID, requester, rotate, false, change)
}

func (s *Store) mutateGroupAdminRequired(groupID, requester string, rotate bool, change func(context.Context, pgx.Tx) error) (*Group, error) {
	return s.mutateGroupAdminOpt(groupID, requester, rotate, true, change)
}

func (s *Store) mutateGroupAdminOpt(groupID, requester string, rotate, requireAdmin bool, change func(context.Context, pgx.Tx) error) (*Group, error) {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	g, err := s.group(ctx, tx, groupID)
	if err != nil {
		return nil, err
	}
	if !g.hasMember(requester) {
		return nil, ErrNotMember
	}
	if requireAdmin && !g.hasAdmin(requester) {
		return nil, ErrNotAdmin
	}
	if err := change(ctx, tx); err != nil {
		return nil, err
	}
	if rotate {
		if _, err := tx.Exec(ctx, `UPDATE groups SET distribution_id = $1 WHERE id = $2`, newUUID(), groupID); err != nil {
			return nil, err
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE groups SET revision = revision + 1 WHERE id = $1`, groupID); err != nil {
		return nil, err
	}
	updated, err := s.group(ctx, tx, groupID)
	if err != nil {
		return nil, err
	}
	return updated, tx.Commit(ctx)
}

// PromoteAdmin adds target to the group's admin list; requester must be an admin.
func (s *Store) PromoteAdmin(groupID, requester, target string) (*Group, error) {
	return s.mutateGroupAdminRequired(groupID, requester, false, func(ctx context.Context, tx pgx.Tx) error {
		_, err := tx.Exec(ctx,
			`UPDATE groups SET admins = array_append(admins, $1) WHERE id = $2 AND NOT ($1 = ANY(admins))`,
			target, groupID)
		return err
	})
}

// DemoteAdmin removes target from the group's admin list; requester must be an admin.
func (s *Store) DemoteAdmin(groupID, requester, target string) (*Group, error) {
	return s.mutateGroupAdminRequired(groupID, requester, false, func(ctx context.Context, tx pgx.Tx) error {
		_, err := tx.Exec(ctx,
			`UPDATE groups SET admins = array_remove(admins, $1) WHERE id = $2`,
			target, groupID)
		return err
	})
}

// SetAnnounceOnly sets the announce-only flag; requester must be an admin.
func (s *Store) SetAnnounceOnly(groupID, requester string, announceOnly bool) (*Group, error) {
	return s.mutateGroupAdminRequired(groupID, requester, false, func(ctx context.Context, tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE groups SET announce_only = $1 WHERE id = $2`, announceOnly, groupID)
		return err
	})
}

// ---------------------------------------------------------------------------

func newUUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(fmt.Sprintf("store: crypto/rand failed: %v", err))
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
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

func newMailboxID() (string, error) {
	return newSecureToken(16)
}

func newSecureToken(bytes int) (string, error) {
	b := make([]byte, bytes)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("store: crypto/rand failed: %w", err)
	}
	return hex.EncodeToString(b), nil
}

func newVerificationCode() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fmt.Errorf("store: crypto/rand failed: %w", err)
	}
	n := int(b[0])<<16 | int(b[1])<<8 | int(b[2])
	return fmt.Sprintf("%06d", n%1000000), nil
}

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

// ---------------------------------------------------------------------------
// Nuke (remote wipe)
// ---------------------------------------------------------------------------

// NukeRecord carries the fields of a signed remote-wipe command without
// importing the relaypb package (which sits above the store layer).
type NukeRecord struct {
	AccountID          string
	CommandID          string
	CreationTimeMs     int64
	InitiatingDeviceID uint32
	Signature          []byte
}

// StoreNuke persists a signed nuke command and atomically deletes all queued
// envelopes for the account. Returns ErrDuplicateNukeCommand if the command_id
// has already been executed (replay protection).
func (s *Store) StoreNuke(rec NukeRecord) error {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx,
		`INSERT INTO nuke_commands
		 (command_id, account_id, creation_time_ms, initiating_device_id, signature, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6)`,
		rec.CommandID, rec.AccountID, rec.CreationTimeMs,
		rec.InitiatingDeviceID, rec.Signature, time.Now().UnixMilli(),
	); err != nil {
		if isUniqueViolation(err) {
			return ErrDuplicateNukeCommand
		}
		return err
	}
	// Delete all queued envelopes for every device of this account so nothing
	// lingers after the wipe.
	if _, err := tx.Exec(ctx,
		`DELETE FROM message_queue WHERE account_id = $1`, rec.AccountID,
	); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// PendingNukeForAccount returns the most recent stored nuke for an account, or
// nil if none exists. Used to deliver the nuke to a device that was offline when
// it was issued.
func (s *Store) PendingNukeForAccount(accountID string) (*NukeRecord, error) {
	ctx := context.Background()
	var rec NukeRecord
	rec.AccountID = accountID
	err := s.db.QueryRow(ctx,
		`SELECT command_id, creation_time_ms, initiating_device_id, signature
		 FROM nuke_commands WHERE account_id = $1
		 ORDER BY created_at DESC LIMIT 1`, accountID,
	).Scan(&rec.CommandID, &rec.CreationTimeMs, &rec.InitiatingDeviceID, &rec.Signature)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &rec, nil
}
