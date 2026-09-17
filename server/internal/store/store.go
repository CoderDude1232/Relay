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
	ErrAccountNotFound           = errors.New("store: account not found")
	ErrNoRecoveryPassword        = errors.New("store: account has no recovery password configured")
	ErrUsernameRequired          = errors.New("store: username required to create account")
	ErrContactInviteInvalid      = errors.New("store: contact invite invalid, expired, or already used")
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
		// Contact discovery: store email on the account row.
		`ALTER TABLE accounts ADD COLUMN IF NOT EXISTS email TEXT`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_email ON accounts (email) WHERE email IS NOT NULL AND email <> ''`,
		// Account recovery: store a user-chosen password hash separate from per-device passwords.
		`ALTER TABLE accounts ADD COLUMN IF NOT EXISTS account_password_hash BYTEA`,
		// Social login: tie an account to its Supabase user id so a returning
		// OAuth user (who has no password) can be signed back in via a verified
		// Supabase token instead of a fresh, colliding registration.
		`ALTER TABLE accounts ADD COLUMN IF NOT EXISTS supabase_user_id TEXT`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_supabase_user_id ON accounts (supabase_user_id) WHERE supabase_user_id IS NOT NULL AND supabase_user_id <> ''`,
		// One-time contact invite links: a token that resolves to the creator's
		// account exactly once, then can't be reused.
		`CREATE TABLE IF NOT EXISTS contact_invites (
    token       TEXT PRIMARY KEY,
    account_id  TEXT NOT NULL,
    expires_at  BIGINT NOT NULL,
    used_at     BIGINT NOT NULL DEFAULT 0
)`,
		`CREATE INDEX IF NOT EXISTS idx_contact_invites_expires ON contact_invites (expires_at)`,
		// Sealed sender: per-account access key. Senders present it on the
		// unauthenticated delivery path; the server verifies it matches the
		// destination account without learning who sent the message.
		`ALTER TABLE accounts ADD COLUMN IF NOT EXISTS access_key BYTEA`,
		// Blinded discovery: OPRF token → account index. `token` is
		// H2(x, H1(x)^k) for a normalized username/email x; the server can build
		// it from its own users but a client can only match (not enumerate) via
		// the oblivious protocol. kind: 0 = username, 1 = email.
		`CREATE TABLE IF NOT EXISTS directory (
    token      BYTEA NOT NULL,
    account_id TEXT NOT NULL,
    kind       SMALLINT NOT NULL,
    PRIMARY KEY (token)
)`,
		`CREATE INDEX IF NOT EXISTS idx_directory_account ON directory (account_id)`,
		// Encrypted group invites: the relay stores an opaque ciphertext blob
		// keyed by a token; the decrypt key travels in the invite URL fragment,
		// so the server never learns the group id, name, or roster. Replaces the
		// plaintext group_invites/groups tables for client-authoritative groups.
		`CREATE TABLE IF NOT EXISTS encrypted_group_invites (
    token      TEXT PRIMARY KEY,
    blob       BYTEA NOT NULL,
    expires_at BIGINT NOT NULL
)`,
		`CREATE INDEX IF NOT EXISTS idx_encrypted_group_invites_expires ON encrypted_group_invites (expires_at)`,
		// Stage 3: groups are now fully client-managed and E2E-encrypted. Drop the
		// server's plaintext group state entirely (roster, name, admins, invites).
		// Order matters: dependents (FK to groups) first.
		`DROP TABLE IF EXISTS group_invites`,
		`DROP TABLE IF EXISTS group_members`,
		`DROP TABLE IF EXISTS groups`,
		// Push privacy: default is a content-free wake (the NSE fetches the
		// encrypted envelope from the relay). A device may opt in to having the
		// ciphertext included directly in the APNs payload (faster, slightly less
		// private — Apple's servers carry the encrypted blob). Off by default.
		`ALTER TABLE devices ADD COLUMN IF NOT EXISTS push_include_content BOOLEAN NOT NULL DEFAULT FALSE`,
		// Cross-platform push: Android wakes via FCM, iOS via APNs. `push_kind`
		// records which transport this device registered ('apns' | 'fcm'); the
		// matching token lives in apns_token or fcm_token. Defaults to 'apns' so
		// existing iOS devices are unaffected.
		`ALTER TABLE devices ADD COLUMN IF NOT EXISTS fcm_token TEXT`,
		`ALTER TABLE devices ADD COLUMN IF NOT EXISTS push_kind TEXT NOT NULL DEFAULT 'apns'`,
		// Email privacy: never store the email in plaintext. We keep only the
		// OPRF-keyed token (the same keyed hash used for blinded discovery), which
		// is a one-way, non-enumerable-without-the-key value. All email lookups
		// (recovery, OAuth adoption, by-email) match on this token instead. The
		// email→account link therefore exists only in keyed form, at rest.
		`ALTER TABLE accounts ADD COLUMN IF NOT EXISTS email_token BYTEA`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_email_token ON accounts (email_token) WHERE email_token IS NOT NULL`,
		// Backfill from the directory (already holds oprf.Token(email) per account)
		// so existing accounts keep working, then drop the plaintext column.
		`UPDATE accounts a SET email_token = d.token FROM directory d WHERE d.account_id = a.id AND d.kind = 1 AND a.email_token IS NULL`,
		`DROP INDEX IF EXISTS idx_accounts_email`,
		`ALTER TABLE accounts DROP COLUMN IF EXISTS email`,
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
// emailToken (the OPRF-keyed hash of the user's email) and accountPassword are
// optional; pass nil/"" to omit. The plaintext email is never stored — only the
// keyed token, used for equality lookups. accountPassword, if set, is stored as
// a bcrypt hash for account recovery.
func (s *Store) CreateAccount(username string, emailToken []byte, devicePassword, accountPassword string) (accountID string, deviceID uint32, err error) {
	deviceHash, err := bcrypt.GenerateFromPassword([]byte(devicePassword), bcrypt.DefaultCost)
	if err != nil {
		return "", 0, err
	}
	var accountHash []byte
	if accountPassword != "" {
		accountHash, err = bcrypt.GenerateFromPassword([]byte(accountPassword), bcrypt.DefaultCost)
		if err != nil {
			return "", 0, err
		}
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

	var emailVal any
	if len(emailToken) > 0 {
		emailVal = emailToken
	}
	if _, err = tx.Exec(ctx,
		`INSERT INTO accounts (id, username, email_token, account_password_hash, created_at) VALUES ($1, $2, $3, $4, $5)`,
		accountID, username, emailVal, accountHash, now); err != nil {
		if isUniqueViolation(err) {
			return "", 0, ErrUsernameTaken
		}
		return "", 0, err
	}
	if _, err = tx.Exec(ctx, `INSERT INTO devices (account_id, device_id, mailbox_id, password_hash, created_at) VALUES ($1, 1, $2, $3, $4)`,
		accountID, mailboxID, deviceHash, now); err != nil {
		return "", 0, err
	}
	return accountID, 1, tx.Commit(ctx)
}

// RecoverAccount verifies an account-level password by email and provisions a
// new device, returning fresh device credentials. Does NOT bump device_list_version
// so existing signed device-list assertions remain valid.
func (s *Store) RecoverAccount(emailToken []byte, accountPassword string) (accountID, username string, deviceID uint32, devicePassword string, err error) {
	ctx := context.Background()

	var accountHash []byte
	err = s.db.QueryRow(ctx,
		`SELECT id, username, account_password_hash FROM accounts WHERE email_token = $1`, emailToken,
	).Scan(&accountID, &username, &accountHash)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", 0, "", ErrAccountNotFound
	}
	if err != nil {
		return "", "", 0, "", err
	}
	if len(accountHash) == 0 {
		return "", "", 0, "", ErrNoRecoveryPassword
	}
	if bcrypt.CompareHashAndPassword(accountHash, []byte(accountPassword)) != nil {
		return "", "", 0, "", ErrAuthFailed
	}

	// Generate a fresh random device password.
	var raw [32]byte
	if _, err = rand.Read(raw[:]); err != nil {
		return "", "", 0, "", err
	}
	devicePassword = hex.EncodeToString(raw[:])

	deviceHash, err := bcrypt.GenerateFromPassword([]byte(devicePassword), bcrypt.DefaultCost)
	if err != nil {
		return "", "", 0, "", err
	}

	mailboxID, err := newMailboxID()
	if err != nil {
		return "", "", 0, "", err
	}

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return "", "", 0, "", err
	}
	defer tx.Rollback(ctx)

	var maxDev int
	tx.QueryRow(ctx, `SELECT COALESCE(MAX(device_id), 0) FROM devices WHERE account_id = $1`, accountID).Scan(&maxDev)
	newDevID := uint32(maxDev + 1)

	now := time.Now().UnixMilli()
	if _, err = tx.Exec(ctx,
		`INSERT INTO devices (account_id, device_id, mailbox_id, password_hash, created_at) VALUES ($1, $2, $3, $4, $5)`,
		accountID, newDevID, mailboxID, deviceHash, now); err != nil {
		return "", "", 0, "", err
	}
	if err = tx.Commit(ctx); err != nil {
		return "", "", 0, "", err
	}
	return accountID, username, newDevID, devicePassword, nil
}

// ProvisionOAuthAccount signs a Supabase-authenticated user into their relay
// account, creating it on first use, and provisions a fresh device. The caller
// MUST have already verified the Supabase access token, so supabaseUserID and
// email are authoritative — this is what lets a passwordless OAuth user recover
// on any device.
//
// Resolution order: match by supabase_user_id, then by email (back-filling the
// supabase_user_id so future logins match directly). If no account exists yet,
// one is created — requestedUsername must be non-empty in that case, otherwise
// ErrUsernameRequired is returned so the client can prompt for a username.
// accountPassword, if non-empty, is stored as a recovery hash on account
// creation only.
//
// A new device is always provisioned with the client-chosen devicePassword and
// its (accountID, deviceID, mailboxID) returned. created reports whether a new
// account was made.
func (s *Store) ProvisionOAuthAccount(supabaseUserID string, emailToken []byte, requestedUsername, devicePassword, accountPassword string) (accountID, username string, deviceID uint32, mailboxID string, created bool, err error) {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return "", "", 0, "", false, err
	}
	defer tx.Rollback(ctx)

	// 1. Find an existing account by Supabase user id, then by email.
	err = tx.QueryRow(ctx,
		`SELECT id, username FROM accounts WHERE supabase_user_id = $1`, supabaseUserID,
	).Scan(&accountID, &username)
	if errors.Is(err, pgx.ErrNoRows) && len(emailToken) > 0 {
		err = tx.QueryRow(ctx,
			`SELECT id, username FROM accounts WHERE email_token = $1`, emailToken,
		).Scan(&accountID, &username)
		if err == nil {
			// Back-fill the Supabase user id so future logins match by id even
			// if the email later changes.
			if _, e := tx.Exec(ctx,
				`UPDATE accounts SET supabase_user_id = $1 WHERE id = $2`,
				supabaseUserID, accountID); e != nil {
				return "", "", 0, "", false, e
			}
		}
	}

	switch {
	case err == nil:
		// Existing account — provision another device below.
	case errors.Is(err, pgx.ErrNoRows):
		// 2. No account yet — create one. A username is required.
		if requestedUsername == "" {
			return "", "", 0, "", false, ErrUsernameRequired
		}
		accountID = newUUID()
		username = requestedUsername
		var emailVal any
		if len(emailToken) > 0 {
			emailVal = emailToken
		}
		var accountHash []byte
		if accountPassword != "" {
			accountHash, err = bcrypt.GenerateFromPassword([]byte(accountPassword), bcrypt.DefaultCost)
			if err != nil {
				return "", "", 0, "", false, err
			}
		}
		now := time.Now().UnixMilli()
		if _, e := tx.Exec(ctx,
			`INSERT INTO accounts (id, username, email_token, supabase_user_id, account_password_hash, created_at) VALUES ($1, $2, $3, $4, $5, $6)`,
			accountID, username, emailVal, supabaseUserID, accountHash, now); e != nil {
			if isUniqueViolation(e) {
				return "", "", 0, "", false, ErrUsernameTaken
			}
			return "", "", 0, "", false, e
		}
		created = true
	default:
		return "", "", 0, "", false, err
	}

	// 3. Provision a fresh device on the account (device 1 for a new account).
	deviceHash, err := bcrypt.GenerateFromPassword([]byte(devicePassword), bcrypt.DefaultCost)
	if err != nil {
		return "", "", 0, "", false, err
	}
	mailboxID, err = newMailboxID()
	if err != nil {
		return "", "", 0, "", false, err
	}
	var maxDev int
	tx.QueryRow(ctx, `SELECT COALESCE(MAX(device_id), 0) FROM devices WHERE account_id = $1`, accountID).Scan(&maxDev)
	deviceID = uint32(maxDev + 1)
	now := time.Now().UnixMilli()
	if _, err = tx.Exec(ctx,
		`INSERT INTO devices (account_id, device_id, mailbox_id, password_hash, created_at) VALUES ($1, $2, $3, $4, $5)`,
		accountID, deviceID, mailboxID, deviceHash, now); err != nil {
		return "", "", 0, "", false, err
	}
	if err = tx.Commit(ctx); err != nil {
		return "", "", 0, "", false, err
	}
	return accountID, username, deviceID, mailboxID, created, nil
}

// CreateContactInvite mints a single-use contact invite token for the account,
// valid for 7 days. The token resolves to the account exactly once via
// ClaimContactInvite.
func (s *Store) CreateContactInvite(accountID string) (token string, expiresAt int64, err error) {
	var raw [16]byte
	if _, err = rand.Read(raw[:]); err != nil {
		return "", 0, err
	}
	token = hex.EncodeToString(raw[:])
	expiresAt = time.Now().Add(7 * 24 * time.Hour).UnixMilli()
	if _, err = s.db.Exec(context.Background(),
		`INSERT INTO contact_invites (token, account_id, expires_at, used_at) VALUES ($1, $2, $3, 0)`,
		token, accountID, expiresAt); err != nil {
		return "", 0, err
	}
	return token, expiresAt, nil
}

// ClaimContactInvite consumes a contact invite token, returning the inviter's
// account id and username. Marks the token used in the same transaction so it
// can never be redeemed twice. Returns ErrContactInviteInvalid if the token is
// unknown, expired, or already used.
func (s *Store) ClaimContactInvite(token string) (accountID, username string, err error) {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return "", "", err
	}
	defer tx.Rollback(ctx)

	var expiresAt, usedAt int64
	err = tx.QueryRow(ctx,
		`SELECT account_id, expires_at, used_at FROM contact_invites WHERE token = $1`, token,
	).Scan(&accountID, &expiresAt, &usedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", ErrContactInviteInvalid
	}
	if err != nil {
		return "", "", err
	}
	now := time.Now().UnixMilli()
	if usedAt != 0 || now > expiresAt {
		return "", "", ErrContactInviteInvalid
	}
	if _, err = tx.Exec(ctx, `UPDATE contact_invites SET used_at = $1 WHERE token = $2`, now, token); err != nil {
		return "", "", err
	}
	if err = tx.QueryRow(ctx, `SELECT username FROM accounts WHERE id = $1`, accountID).Scan(&username); err != nil {
		return "", "", err
	}
	if err = tx.Commit(ctx); err != nil {
		return "", "", err
	}
	return accountID, username, nil
}

// LookupAccountByEmail returns the accountID and username for the account whose
// email hashes to emailToken (the OPRF-keyed token), or ErrAccountNotFound.
func (s *Store) LookupAccountByEmail(emailToken []byte) (accountID, username string, err error) {
	err = s.db.QueryRow(context.Background(),
		`SELECT id, username FROM accounts WHERE email_token = $1`, emailToken,
	).Scan(&accountID, &username)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", ErrAccountNotFound
	}
	return accountID, username, err
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

// DeviceByID returns the device row without checking a password. Used by
// signature-based request auth, which proves possession of the device's auth
// private key instead of presenting a reusable secret.
func (s *Store) DeviceByID(accountID string, deviceID uint32) (*Device, error) {
	ctx := context.Background()
	var regID uint32
	var mailboxID string
	var authPublicKey []byte
	err := s.db.QueryRow(ctx, `SELECT registration_id, COALESCE(mailbox_id, ''), auth_public_key FROM devices WHERE account_id = $1 AND device_id = $2`,
		accountID, deviceID).Scan(&regID, &mailboxID, &authPublicKey)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrAuthFailed
	}
	if err != nil {
		return nil, err
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

// RotateMailbox assigns a fresh opaque mailbox id to the device and returns it.
// Peers pick up the new id on their next prekey-bundle fetch; sealed sends to
// the old id fail (the sender re-fetches the bundle and retries). Rotating
// periodically breaks any long-lived routing identifier the relay could use to
// correlate a mailbox with a device over time. The message queue is keyed by
// (account, device), not mailbox, so queued deliveries are unaffected.
func (s *Store) RotateMailbox(accountID string, deviceID uint32) (string, error) {
	mailboxID, err := newMailboxID()
	if err != nil {
		return "", err
	}
	ct, err := s.db.Exec(context.Background(),
		`UPDATE devices SET mailbox_id = $1 WHERE account_id = $2 AND device_id = $3`,
		mailboxID, accountID, deviceID)
	if err != nil {
		return "", err
	}
	if ct.RowsAffected() == 0 {
		return "", ErrNotFound
	}
	return mailboxID, nil
}

func (s *Store) SetAPNSToken(accountID string, deviceID uint32, token string) error {
	ctx := context.Background()
	_, err := s.db.Exec(ctx, `UPDATE devices SET apns_token = $1, push_kind = 'apns' WHERE account_id = $2 AND device_id = $3`,
		token, accountID, deviceID)
	return err
}

// SetFCMToken registers this device's Firebase Cloud Messaging token and marks
// it as an FCM-push device (Android).
func (s *Store) SetFCMToken(accountID string, deviceID uint32, token string) error {
	ctx := context.Background()
	_, err := s.db.Exec(ctx, `UPDATE devices SET fcm_token = $1, push_kind = 'fcm' WHERE account_id = $2 AND device_id = $3`,
		token, accountID, deviceID)
	return err
}

// PushTarget returns how to wake a device: its push kind ('apns'|'fcm') and the
// matching token. token is "" when the device has registered none.
func (s *Store) PushTarget(accountID string, deviceID uint32) (kind, token string, err error) {
	ctx := context.Background()
	var apnsTok, fcmTok *string
	err = s.db.QueryRow(ctx,
		`SELECT push_kind, apns_token, fcm_token FROM devices WHERE account_id = $1 AND device_id = $2`,
		accountID, deviceID,
	).Scan(&kind, &apnsTok, &fcmTok)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", ErrNotFound
	}
	if err != nil {
		return "", "", err
	}
	switch kind {
	case "fcm":
		if fcmTok != nil {
			token = *fcmTok
		}
	default:
		kind = "apns"
		if apnsTok != nil {
			token = *apnsTok
		}
	}
	return kind, token, nil
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

// SetPushIncludeContent records whether this device wants the encrypted
// envelope carried directly in its APNs payload (true) or a content-free wake
// (false, the private default).
func (s *Store) SetPushIncludeContent(accountID string, deviceID uint32, include bool) error {
	ctx := context.Background()
	_, err := s.db.Exec(ctx, `UPDATE devices SET push_include_content = $1 WHERE account_id = $2 AND device_id = $3`,
		include, accountID, deviceID)
	return err
}

// PushIncludeContent reports whether this device opted in to ciphertext-in-push.
// Defaults to false (content-free wake) for unknown/unset devices.
func (s *Store) PushIncludeContent(accountID string, deviceID uint32) (bool, error) {
	ctx := context.Background()
	var include bool
	err := s.db.QueryRow(ctx,
		`SELECT push_include_content FROM devices WHERE account_id = $1 AND device_id = $2`,
		accountID, deviceID,
	).Scan(&include)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return include, err
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
	// Also prune expired (encrypted) group invite blobs.
	_, err := s.db.Exec(ctx, `DELETE FROM encrypted_group_invites WHERE expires_at < $1`, time.Now().UnixMilli())
	return err
}

const groupInviteTTL = 7 * 24 * time.Hour

// CreateEncryptedGroupInvite stores an opaque encrypted invite blob under a
// fresh token (7-day expiry) and returns both. The relay never learns what the
// blob decrypts to — the group id, name, and roster stay client-side.
func (s *Store) CreateEncryptedGroupInvite(blob []byte) (token string, expiresAt int64, err error) {
	token = newUUID()
	expiresAt = time.Now().Add(groupInviteTTL).UnixMilli()
	_, err = s.db.Exec(context.Background(),
		`INSERT INTO encrypted_group_invites (token, blob, expires_at) VALUES ($1, $2, $3)`,
		token, blob, expiresAt)
	return token, expiresAt, err
}

// ClaimEncryptedGroupInvite returns the invite blob for a (non-expired) token.
// Multi-use until expiry; the relay can't tell who redeemed it or for what.
func (s *Store) ClaimEncryptedGroupInvite(token string) ([]byte, error) {
	var blob []byte
	err := s.db.QueryRow(context.Background(),
		`SELECT blob FROM encrypted_group_invites WHERE token = $1 AND expires_at > $2`,
		token, time.Now().UnixMilli()).Scan(&blob)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	return blob, err
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

// SetAccessKey stores an account's sealed-sender access key (32 bytes). Senders
// present this key on the unauthenticated delivery path; the server checks it
// matches without learning the sender. Rotating it revokes anyone holding the old key.
func (s *Store) SetAccessKey(accountID string, key []byte) error {
	_, err := s.db.Exec(context.Background(),
		`UPDATE accounts SET access_key = $1 WHERE id = $2`, key, accountID)
	return err
}

// AccessKey returns an account's sealed-sender access key, or nil if unset.
func (s *Store) AccessKey(accountID string) ([]byte, error) {
	var key []byte
	err := s.db.QueryRow(context.Background(),
		`SELECT access_key FROM accounts WHERE id = $1`, accountID,
	).Scan(&key)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrAccountNotFound
	}
	return key, err
}

// Directory kinds.
const (
	DirectoryKindUsername int16 = 0
	DirectoryKindEmail    int16 = 1
)

// DirectoryEntry is one OPRF token → account row for the blinded directory index.
type DirectoryEntry struct {
	Token     []byte
	AccountID string
	Kind      int16
}

// DirectoryMatch is a resolved directory hit returned to a querying client.
type DirectoryMatch struct {
	Token     []byte
	AccountID string
	Username  string
}

// AccountDirInfo is the identifier material the API layer needs to (re)build an
// account's directory tokens. The email is stored only as its keyed token, so we
// surface that directly rather than a plaintext address.
type AccountDirInfo struct {
	AccountID  string
	Username   string
	EmailToken []byte
}

// AllAccountsForDirectory returns every account's username + email token so the
// API can (re)build the full directory index at startup.
func (s *Store) AllAccountsForDirectory() ([]AccountDirInfo, error) {
	rows, err := s.db.Query(context.Background(),
		`SELECT id, COALESCE(username, ''), email_token FROM accounts`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AccountDirInfo
	for rows.Next() {
		var a AccountDirInfo
		if err := rows.Scan(&a.AccountID, &a.Username, &a.EmailToken); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// AccountForDirectory returns one account's identifier material for live reindex.
func (s *Store) AccountForDirectory(accountID string) (AccountDirInfo, error) {
	var a AccountDirInfo
	err := s.db.QueryRow(context.Background(),
		`SELECT id, COALESCE(username, ''), email_token FROM accounts WHERE id = $1`,
		accountID,
	).Scan(&a.AccountID, &a.Username, &a.EmailToken)
	if errors.Is(err, pgx.ErrNoRows) {
		return a, ErrAccountNotFound
	}
	return a, err
}

// ReplaceDirectory rebuilds the entire directory index from scratch (startup).
func (s *Store) ReplaceDirectory(entries []DirectoryEntry) error {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `TRUNCATE directory`); err != nil {
		return err
	}
	for _, e := range entries {
		if _, err := tx.Exec(ctx,
			`INSERT INTO directory (token, account_id, kind) VALUES ($1, $2, $3)
             ON CONFLICT (token) DO UPDATE SET account_id = EXCLUDED.account_id, kind = EXCLUDED.kind`,
			e.Token, e.AccountID, e.Kind); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// SetDirectoryForAccount replaces one account's directory rows (live reindex on
// account creation or username change).
func (s *Store) SetDirectoryForAccount(accountID string, entries []DirectoryEntry) error {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `DELETE FROM directory WHERE account_id = $1`, accountID); err != nil {
		return err
	}
	for _, e := range entries {
		if _, err := tx.Exec(ctx,
			`INSERT INTO directory (token, account_id, kind) VALUES ($1, $2, $3)
             ON CONFLICT (token) DO UPDATE SET account_id = EXCLUDED.account_id, kind = EXCLUDED.kind`,
			e.Token, e.AccountID, e.Kind); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// ResolveDirectory returns the account (and current username) for each token
// that matches a directory entry. Unmatched tokens are simply absent.
func (s *Store) ResolveDirectory(tokens [][]byte) ([]DirectoryMatch, error) {
	if len(tokens) == 0 {
		return nil, nil
	}
	rows, err := s.db.Query(context.Background(),
		`SELECT d.token, d.account_id, COALESCE(a.username, '')
         FROM directory d JOIN accounts a ON a.id = d.account_id
         WHERE d.token = ANY($1)`,
		tokens)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DirectoryMatch
	for rows.Next() {
		var m DirectoryMatch
		if err := rows.Scan(&m.Token, &m.AccountID, &m.Username); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// IdentityKey returns a device's stored identity public key (libsignal-serialized,
// 33 bytes), or ErrNotFound if the device/key doesn't exist. Used to mint
// sealed-sender certificates binding the account to its identity key.
func (s *Store) IdentityKey(accountID string, deviceID uint32) ([]byte, error) {
	var key []byte
	err := s.db.QueryRow(context.Background(),
		`SELECT identity_key FROM devices WHERE account_id = $1 AND device_id = $2`,
		accountID, deviceID,
	).Scan(&key)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	return key, err
}

// DeleteNukesForAccount removes all pending nuke commands for an account. Used to
// clear a stale nuke that is older than the delivery window (it would be rejected
// by the client and otherwise re-delivers on every reconnect, wedging the account
// offline).
func (s *Store) DeleteNukesForAccount(accountID string) error {
	_, err := s.db.Exec(context.Background(),
		`DELETE FROM nuke_commands WHERE account_id = $1`, accountID)
	return err
}
