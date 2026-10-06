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
	"log/slog"
	"net"
	"strings"
	"sync"
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
	ErrDeviceLimit               = errors.New("store: linked device limit reached")
	ErrIdentityInUse             = errors.New("store: email or social-login identity already linked to an account")
)

// maxDevicesPerAccount caps how many devices (primary + linked) an account may
// have at once, bounding the blast radius of a linking compromise.
const maxDevicesPerAccount = 5

const maxGroupMembers = 256

// QueueTTL is how long an undelivered envelope is kept before PurgeExpired
// drops it.
const QueueTTL = 14 * 24 * time.Hour

const (
	queueTTLMillis         = int64(QueueTTL / time.Millisecond)
	maxQueuedEnvelopeBytes = 512 * 1024
	maxQueuedPerDevice     = 500
	// maxQueuedBytesPerDevice caps a device's total queued ciphertext, so the
	// count cap can't be turned into 500 × 512 KiB of storage per device.
	maxQueuedBytesPerDevice = 50 << 20
	// Abuse reports are kept for 180 days.
	reportTTLMillis = int64((180 * 24 * time.Hour) / time.Millisecond)
	// Stored nuke commands are only ever delivered inside the client's 5-minute
	// freshness window (and replays are rejected by that timestamp check), so
	// rows older than an hour serve no purpose and are purged.
	nukeRetentionMillis = int64(time.Hour / time.Millisecond)
)

// coarseDayMillis returns the start (UTC) of the current day in unix ms. Row
// creation times that aren't needed for expiry are stored at day granularity
// so the database doesn't record exactly when an account or device appeared.
func coarseDayMillis() int64 {
	const day = int64(24 * time.Hour / time.Millisecond)
	now := time.Now().UnixMilli()
	return now - now%day
}

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
	if !strings.Contains(dsn, "sslmode") && !isLocalDBHost(cfg.ConnConfig.Host) {
		// pgx's default (sslmode=prefer) silently falls back to plaintext, and
		// this connection carries every routing row and queued envelope.
		slog.Warn("store: database host is not local and the DSN sets no sslmode; " +
			"run PostgreSQL on the relay host (or a unix socket), or add sslmode=verify-full")
	}
	cfg.ConnConfig.Config.DialFunc = func(ctx context.Context, network, addr string) (net.Conn, error) {
		if network == "unix" {
			return (&net.Dialer{}).DialContext(ctx, network, addr)
		}
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

// isLocalDBHost reports whether a PostgreSQL host is this machine: loopback or
// a unix-socket directory (an absolute path).
func isLocalDBHost(host string) bool {
	if host == "" || strings.HasPrefix(host, "/") || host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

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
		// A short, non-PII device label (e.g. "iPhone", "iPad") the new device
		// supplies at link time, shown in the owner's Linked Devices list.
		`ALTER TABLE devices ADD COLUMN IF NOT EXISTS device_name TEXT`,
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
		// Reversed device linking: the new (secondary) device creates a session
		// and shows a QR carrying its ephemeral key; the primary scans it,
		// encrypts the provisioning payload (shared identity key + credentials)
		// under an ECDH-derived key, and PUTs the ciphertext here. The relay is a
		// blind mailbox — it stores only the opaque blob keyed by session id and
		// never sees the ephemeral key (which travels in the QR) or the plaintext.
		`CREATE TABLE IF NOT EXISTS provisioning_sessions (
    session_id TEXT PRIMARY KEY,
    blob       BYTEA,
    expires_at BIGINT NOT NULL,
    created_at BIGINT NOT NULL
)`,
		`CREATE INDEX IF NOT EXISTS idx_provisioning_sessions_expires ON provisioning_sessions (expires_at)`,
		// Abuse reports (moderation records). Deliberately NO foreign keys to
		// accounts: a report against an account survives that account's
		// deletion. Reports an account FILED are its own data and are removed
		// by DeleteAccount. `messages` is a JSON array of plaintext messages the
		// reporter explicitly chose to forward (the relay never sees plaintext
		// otherwise).
		`CREATE TABLE IF NOT EXISTS reports (
    id                TEXT PRIMARY KEY,
    reporter_account  TEXT NOT NULL,
    reported_account  TEXT NOT NULL,
    reason            TEXT NOT NULL,
    details           TEXT NOT NULL DEFAULT '',
    messages          TEXT NOT NULL DEFAULT '[]',
    created_at        BIGINT NOT NULL
)`,
		`CREATE INDEX IF NOT EXISTS idx_reports_reporter ON reports (reporter_account, created_at)`,
		`CREATE INDEX IF NOT EXISTS idx_reports_reported ON reports (reported_account, created_at)`,
		// Monotonic per-account device-id counter: a removed device's id is
		// never handed out again (peers may still hold sessions/receipts keyed
		// by it). 0 = not yet initialised; allocation takes the max of this and
		// the live MAX(device_id).
		`ALTER TABLE accounts ADD COLUMN IF NOT EXISTS next_device_id BIGINT NOT NULL DEFAULT 0`,
		// Legacy link tokens no longer hold the new device's password (it is
		// generated at claim time); scrub any that were stored in plaintext.
		`UPDATE device_link_tokens SET password = '' WHERE password <> ''`,
		// Prekey rows no longer carry an upload time (it acted as a
		// last-active signal); account/device creation times are kept only
		// at day granularity.
		`UPDATE signed_prekeys SET created_at = 0 WHERE created_at <> 0`,
		`UPDATE kyber_prekeys SET created_at = 0 WHERE created_at <> 0`,
		`UPDATE accounts SET created_at = created_at - created_at % 86400000 WHERE created_at % 86400000 <> 0`,
		`UPDATE devices SET created_at = created_at - created_at % 86400000 WHERE created_at % 86400000 <> 0`,
	} {
		if _, err := s.db.Exec(context.Background(), stmt); err != nil {
			return err
		}
	}
	s.ensureUsernameCaseIndex(ctx)
	return s.ensureMailboxIDs(ctx)
}

// ensureUsernameCaseIndex adds a unique index on lower(username) so "Bob" and
// "bob" can't coexist (they'd also share one blinded-directory token, since
// discovery normalizes case). If legacy case-variant duplicates already exist
// the index can't be built; we log and carry on — registration and rename still
// enforce case-insensitive uniqueness in code, and the directory never
// reassigns a token from its first owner — instead of refusing to start.
func (s *Store) ensureUsernameCaseIndex(ctx context.Context) {
	var dupGroups int
	if err := s.db.QueryRow(ctx, `
		SELECT COUNT(*) FROM (
			SELECT lower(username) FROM accounts GROUP BY lower(username) HAVING COUNT(*) > 1
		) d`).Scan(&dupGroups); err != nil {
		slog.Warn("store: username case-collision check failed", "err", err)
		return
	}
	if dupGroups > 0 {
		slog.Warn("store: case-insensitive username index skipped; existing accounts collide on case — resolve manually",
			"collidingNames", dupGroups)
		return
	}
	if _, err := s.db.Exec(ctx,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_username_lower ON accounts (lower(username))`); err != nil {
		slog.Warn("store: could not create case-insensitive username index", "err", err)
	}
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
	Name           string
	CreatedAt      int64
}

type DeviceLinkClaim struct {
	AccountID string
	DeviceID  uint32
	Password  string
	Username  string
}

// CreateAccount registers a new account and its primary device (device 1).
// emailToken (the OPRF-keyed hash of a VERIFIED email — the API layer only
// passes one after Supabase confirmed the address), supabaseUserID and
// accountPassword are optional; pass nil/"" to omit. The plaintext email is
// never stored. accountPassword, if set, is stored as a bcrypt hash for
// account recovery.
//
// Usernames are unique case-insensitively. Returns ErrUsernameTaken when the
// username is in use, ErrIdentityInUse when the email token or Supabase user id
// already belongs to another account.
func (s *Store) CreateAccount(username string, emailToken []byte, supabaseUserID, devicePassword, accountPassword string) (accountID string, deviceID uint32, err error) {
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
	now := coarseDayMillis()
	ctx := context.Background()

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return "", 0, err
	}
	defer tx.Rollback(ctx)

	if taken, err := usernameTakenTx(ctx, tx, username, ""); err != nil {
		return "", 0, err
	} else if taken {
		return "", 0, ErrUsernameTaken
	}
	if _, err = tx.Exec(ctx,
		`INSERT INTO accounts (id, username, email_token, supabase_user_id, account_password_hash, created_at, next_device_id) VALUES ($1, $2, $3, $4, $5, $6, 1)`,
		accountID, username, nullableBytes(emailToken), nullableString(supabaseUserID), accountHash, now); err != nil {
		return "", 0, accountInsertError(err)
	}
	if _, err = tx.Exec(ctx, `INSERT INTO devices (account_id, device_id, mailbox_id, password_hash, created_at) VALUES ($1, 1, $2, $3, $4)`,
		accountID, mailboxID, deviceHash, now); err != nil {
		return "", 0, err
	}
	return accountID, 1, tx.Commit(ctx)
}

// accountInsertError maps a unique violation on the accounts table to the
// right sentinel: the email-token or Supabase-user index → ErrIdentityInUse
// (callers must not echo which); anything else (the username indexes) →
// ErrUsernameTaken.
func accountInsertError(err error) error {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "23505" {
		return err
	}
	switch pgErr.ConstraintName {
	case "idx_accounts_email_token", "idx_accounts_supabase_user_id":
		return ErrIdentityInUse
	default:
		return ErrUsernameTaken
	}
}

func nullableBytes(b []byte) any {
	if len(b) == 0 {
		return nil
	}
	return b
}

func nullableString(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// rowQuerier is satisfied by both the pool and a transaction.
type rowQuerier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// usernameTakenTx reports whether another account (≠ exceptAccountID) already
// holds username, compared case-insensitively.
func usernameTakenTx(ctx context.Context, q rowQuerier, username, exceptAccountID string) (bool, error) {
	var taken bool
	err := q.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM accounts WHERE lower(username) = lower($1) AND id <> $2)`,
		username, exceptAccountID).Scan(&taken)
	return taken, err
}

// UsernameTaken reports whether any account holds username (case-insensitive).
func (s *Store) UsernameTaken(username string) (bool, error) {
	return usernameTakenTx(context.Background(), s.db, username, "")
}

// dummyRecoveryHash is compared against when an account (or its recovery
// password) doesn't exist, so a recovery attempt costs one bcrypt either way
// and response timing can't reveal whether an email is registered.
var (
	dummyRecoveryHashOnce sync.Once
	dummyRecoveryHash     []byte
)

func burnRecoveryBcrypt(password string) {
	dummyRecoveryHashOnce.Do(func() {
		var raw [32]byte
		rand.Read(raw[:])
		dummyRecoveryHash, _ = bcrypt.GenerateFromPassword([]byte(hex.EncodeToString(raw[:])), bcrypt.DefaultCost)
	})
	_ = bcrypt.CompareHashAndPassword(dummyRecoveryHash, []byte(password))
}

// AddedDevice describes a device provisioned by recovery or social login.
type AddedDevice struct {
	AccountID         string
	Username          string
	DeviceID          uint32
	MailboxID         string
	DeviceListVersion int64
}

// addDeviceTx provisions a new device on accountID inside tx: it locks the
// account row, enforces maxDevicesPerAccount, inserts the device and bumps
// device_list_version (so signed device-list views are invalidated and the API
// can broadcast DeviceListChanged).
func addDeviceTx(ctx context.Context, tx pgx.Tx, accountID string, deviceHash []byte) (deviceID uint32, mailboxID string, version int64, err error) {
	if err = tx.QueryRow(ctx, `SELECT device_list_version FROM accounts WHERE id = $1 FOR UPDATE`, accountID).Scan(&version); errors.Is(err, pgx.ErrNoRows) {
		return 0, "", 0, ErrNotFound
	} else if err != nil {
		return 0, "", 0, err
	}
	if err = checkDeviceCap(ctx, tx, accountID); err != nil {
		return 0, "", 0, err
	}
	if deviceID, err = allocateDeviceID(ctx, tx, accountID); err != nil {
		return 0, "", 0, err
	}
	if mailboxID, err = newMailboxID(); err != nil {
		return 0, "", 0, err
	}
	if _, err = tx.Exec(ctx,
		`INSERT INTO devices (account_id, device_id, mailbox_id, password_hash, created_at) VALUES ($1, $2, $3, $4, $5)`,
		accountID, deviceID, mailboxID, deviceHash, coarseDayMillis()); err != nil {
		return 0, "", 0, err
	}
	version++
	if _, err = tx.Exec(ctx, `UPDATE accounts SET device_list_version = $1 WHERE id = $2`, version, accountID); err != nil {
		return 0, "", 0, err
	}
	return deviceID, mailboxID, version, nil
}

// RecoverAccount verifies an account-level password by (verified) email token
// and provisions a new device with a fresh random password. Every failure —
// unknown email, no recovery password set, wrong password — returns
// ErrAuthFailed after the same single bcrypt comparison, so neither the result
// nor its timing reveals whether the email is registered. Enforces the device
// cap (ErrDeviceLimit, only reachable with the right password) and bumps
// device_list_version.
func (s *Store) RecoverAccount(emailToken []byte, accountPassword string) (dev AddedDevice, devicePassword string, err error) {
	ctx := context.Background()

	var accountHash []byte
	err = s.db.QueryRow(ctx,
		`SELECT id, username, account_password_hash FROM accounts WHERE email_token = $1`, emailToken,
	).Scan(&dev.AccountID, &dev.Username, &accountHash)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && len(accountHash) == 0) {
		burnRecoveryBcrypt(accountPassword)
		return AddedDevice{}, "", ErrAuthFailed
	}
	if err != nil {
		return AddedDevice{}, "", err
	}
	if bcrypt.CompareHashAndPassword(accountHash, []byte(accountPassword)) != nil {
		return AddedDevice{}, "", ErrAuthFailed
	}

	var raw [32]byte
	if _, err = rand.Read(raw[:]); err != nil {
		return AddedDevice{}, "", err
	}
	devicePassword = hex.EncodeToString(raw[:])
	deviceHash, err := bcrypt.GenerateFromPassword([]byte(devicePassword), bcrypt.DefaultCost)
	if err != nil {
		return AddedDevice{}, "", err
	}

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return AddedDevice{}, "", err
	}
	defer tx.Rollback(ctx)
	dev.DeviceID, dev.MailboxID, dev.DeviceListVersion, err = addDeviceTx(ctx, tx, dev.AccountID, deviceHash)
	if err != nil {
		return AddedDevice{}, "", err
	}
	if err = tx.Commit(ctx); err != nil {
		return AddedDevice{}, "", err
	}
	return dev, devicePassword, nil
}

// ProvisionOAuthAccount signs a Supabase-authenticated user into their relay
// account, creating it on first use, and provisions a fresh device. The caller
// MUST have already verified the Supabase access token, so supabaseUserID is
// authoritative; emailToken must be non-nil ONLY when Supabase reports the
// email as confirmed.
//
// Resolution order: match by supabase_user_id, then by email token
// (back-filling the supabase_user_id so future logins match directly). Email
// adoption is safe because the relay only ever stores tokens of verified
// emails; an existing link to a different Supabase user is never overwritten.
// If no account exists yet, one is created — requestedUsername
// must be non-empty in that case, otherwise ErrUsernameRequired is returned.
// accountPassword, if non-empty, is stored as a recovery hash on creation only.
//
// Adding a device to an existing account enforces the device cap and bumps
// device_list_version. created reports whether a new account was made.
func (s *Store) ProvisionOAuthAccount(supabaseUserID string, emailToken []byte, requestedUsername, devicePassword, accountPassword string) (dev AddedDevice, created bool, err error) {
	ctx := context.Background()
	deviceHash, err := bcrypt.GenerateFromPassword([]byte(devicePassword), bcrypt.DefaultCost)
	if err != nil {
		return AddedDevice{}, false, err
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return AddedDevice{}, false, err
	}
	defer tx.Rollback(ctx)

	// 1. Find an existing account by Supabase user id, then by verified email.
	err = tx.QueryRow(ctx,
		`SELECT id, username FROM accounts WHERE supabase_user_id = $1`, supabaseUserID,
	).Scan(&dev.AccountID, &dev.Username)
	if errors.Is(err, pgx.ErrNoRows) && len(emailToken) > 0 {
		err = tx.QueryRow(ctx,
			`SELECT id, username FROM accounts WHERE email_token = $1`, emailToken,
		).Scan(&dev.AccountID, &dev.Username)
		if err == nil {
			// Back-fill only an empty link; never overwrite another Supabase
			// user's link (a second identity with the same confirmed email can
			// sign in, but the original link is kept).
			if _, e := tx.Exec(ctx,
				`UPDATE accounts SET supabase_user_id = $1 WHERE id = $2 AND (supabase_user_id IS NULL OR supabase_user_id = '')`,
				supabaseUserID, dev.AccountID); e != nil {
				return AddedDevice{}, false, e
			}
		}
	}

	switch {
	case err == nil:
		// Existing account — provision another device (capped, versioned).
		dev.DeviceID, dev.MailboxID, dev.DeviceListVersion, err = addDeviceTx(ctx, tx, dev.AccountID, deviceHash)
		if err != nil {
			return AddedDevice{}, false, err
		}
	case errors.Is(err, pgx.ErrNoRows):
		// 2. No account yet — create one. A username is required.
		if requestedUsername == "" {
			return AddedDevice{}, false, ErrUsernameRequired
		}
		if taken, e := usernameTakenTx(ctx, tx, requestedUsername, ""); e != nil {
			return AddedDevice{}, false, e
		} else if taken {
			return AddedDevice{}, false, ErrUsernameTaken
		}
		dev.AccountID = newUUID()
		dev.Username = requestedUsername
		var accountHash []byte
		if accountPassword != "" {
			accountHash, err = bcrypt.GenerateFromPassword([]byte(accountPassword), bcrypt.DefaultCost)
			if err != nil {
				return AddedDevice{}, false, err
			}
		}
		now := coarseDayMillis()
		if _, e := tx.Exec(ctx,
			`INSERT INTO accounts (id, username, email_token, supabase_user_id, account_password_hash, created_at, next_device_id) VALUES ($1, $2, $3, $4, $5, $6, 1)`,
			dev.AccountID, dev.Username, nullableBytes(emailToken), supabaseUserID, accountHash, now); e != nil {
			return AddedDevice{}, false, accountInsertError(e)
		}
		if dev.MailboxID, err = newMailboxID(); err != nil {
			return AddedDevice{}, false, err
		}
		dev.DeviceID = 1
		if _, err = tx.Exec(ctx,
			`INSERT INTO devices (account_id, device_id, mailbox_id, password_hash, created_at) VALUES ($1, 1, $2, $3, $4)`,
			dev.AccountID, dev.MailboxID, deviceHash, now); err != nil {
			return AddedDevice{}, false, err
		}
		created = true
	default:
		return AddedDevice{}, false, err
	}

	if err = tx.Commit(ctx); err != nil {
		return AddedDevice{}, false, err
	}
	return dev, created, nil
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

// allocateDeviceID reserves the next device id for an account inside tx. Ids
// are monotonic per account: accounts.next_device_id records the highest id
// ever handed out, so a removed device's id is never reused (MAX(device_id)+1
// would recycle it after the highest device is removed). Accounts created
// before the counter existed start from their current MAX(device_id). Returns
// ErrNotFound when the account doesn't exist.
func allocateDeviceID(ctx context.Context, tx pgx.Tx, accountID string) (uint32, error) {
	var next int64
	err := tx.QueryRow(ctx, `
		UPDATE accounts SET next_device_id = GREATEST(next_device_id,
			(SELECT COALESCE(MAX(device_id), 0) FROM devices WHERE account_id = $1)) + 1
		WHERE id = $1
		RETURNING next_device_id`, accountID).Scan(&next)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, ErrNotFound
	}
	if err != nil {
		return 0, err
	}
	return uint32(next), nil
}

// checkDeviceCap returns ErrDeviceLimit when the account already has
// maxDevicesPerAccount devices. Call with the account row locked.
func checkDeviceCap(ctx context.Context, tx pgx.Tx, accountID string) error {
	var count int
	if err := tx.QueryRow(ctx, `SELECT COUNT(*) FROM devices WHERE account_id = $1`, accountID).Scan(&count); err != nil {
		return err
	}
	if count >= maxDevicesPerAccount {
		return ErrDeviceLimit
	}
	return nil
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

	if err := checkDeviceCap(ctx, tx, accountID); err != nil {
		return 0, 0, err
	}
	next, err := allocateDeviceID(ctx, tx, accountID)
	if err != nil {
		return 0, 0, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO devices (account_id, device_id, mailbox_id, password_hash, created_at) VALUES ($1, $2, $3, $4, $5)`,
		accountID, next, mailboxID, hash, coarseDayMillis()); err != nil {
		return 0, 0, err
	}
	newVersion := currentVersion + 1
	if _, err := tx.Exec(ctx, `UPDATE accounts SET device_list_version = $1 WHERE id = $2`, newVersion, accountID); err != nil {
		return 0, 0, err
	}
	return next, newVersion, tx.Commit(ctx)
}

// CreateDeviceLinkToken mints a legacy (forward-QR) link token. No device
// password is stored with it: ClaimDeviceLinkToken generates the new device's
// password at claim time and returns it once, so a database read never yields
// a working credential.
func (s *Store) CreateDeviceLinkToken(accountID string, expectedVersion int64) (token string, code string, expiresAt int64, err error) {
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
	if _, err := tx.Exec(ctx, `INSERT INTO device_link_tokens (token, account_id, password, code, expected_version, expires_at, created_at) VALUES ($1, $2, '', $3, $4, $5, $6)`,
		token, accountID, code, expectedVersion, expiresAt, now); err != nil {
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
		RETURNING account_id, expected_version, expires_at`,
		token, code,
	).Scan(&claim.AccountID, &expectedVersion, &expiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if expiresAt < now {
		return nil, ErrNotFound
	}
	// The new device's password is generated here and returned exactly once.
	claim.Password, err = newSecureToken(32)
	if err != nil {
		return nil, err
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
	if err := checkDeviceCap(ctx, tx, claim.AccountID); err != nil {
		return nil, err
	}
	if claim.DeviceID, err = allocateDeviceID(ctx, tx, claim.AccountID); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO devices (account_id, device_id, mailbox_id, password_hash, created_at) VALUES ($1, $2, $3, $4, $5)`,
		claim.AccountID, claim.DeviceID, mailboxID, hash, coarseDayMillis()); err != nil {
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

// CreateProvisioningSession mints a blind mailbox for reversed device linking.
// The new (secondary) device creates it, shows its id + ephemeral key in a QR,
// and later polls FetchProvisioningBlob; the primary stores the ciphertext via
// StoreProvisioningBlob. Unauthenticated by design — the session grants no
// authority until a primary chooses to provision into it.
func (s *Store) CreateProvisioningSession() (sessionID string, expiresAt int64, err error) {
	sessionID, err = newSecureToken(32)
	if err != nil {
		return "", 0, err
	}
	now := time.Now().UnixMilli()
	expiresAt = now + int64((10*time.Minute)/time.Millisecond)
	ctx := context.Background()
	if _, err := s.db.Exec(ctx, `DELETE FROM provisioning_sessions WHERE expires_at < $1`, now); err != nil {
		return "", 0, err
	}
	if _, err := s.db.Exec(ctx, `INSERT INTO provisioning_sessions (session_id, blob, expires_at, created_at) VALUES ($1, NULL, $2, $3)`,
		sessionID, expiresAt, now); err != nil {
		return "", 0, err
	}
	return sessionID, expiresAt, nil
}

// StoreProvisioningBlob attaches the primary's encrypted payload to a session.
// Write-once: the `blob IS NULL` guard means a session can only be provisioned
// a single time, so a second writer can't overwrite (substitute) the primary's
// payload before the new device fetches it. Returns ErrNotFound if the session
// is unknown, expired, or already provisioned.
func (s *Store) StoreProvisioningBlob(sessionID string, blob []byte) error {
	now := time.Now().UnixMilli()
	ctx := context.Background()
	tag, err := s.db.Exec(ctx, `UPDATE provisioning_sessions SET blob = $1 WHERE session_id = $2 AND expires_at >= $3 AND blob IS NULL`,
		blob, sessionID, now)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// FetchProvisioningBlob returns the encrypted payload once the primary has
// stored it, deleting the session on success (single-use). Returns (nil, nil)
// when the session exists but no blob is present yet (caller replies 204), and
// ErrNotFound when the session is unknown or expired.
func (s *Store) FetchProvisioningBlob(sessionID string) ([]byte, error) {
	now := time.Now().UnixMilli()
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `DELETE FROM provisioning_sessions WHERE expires_at < $1`, now); err != nil {
		return nil, err
	}
	var blob []byte
	err = tx.QueryRow(ctx, `SELECT blob FROM provisioning_sessions WHERE session_id = $1`, sessionID).Scan(&blob)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if blob == nil {
		return nil, tx.Commit(ctx) // not provisioned yet
	}
	if _, err := tx.Exec(ctx, `DELETE FROM provisioning_sessions WHERE session_id = $1`, sessionID); err != nil {
		return nil, err
	}
	return blob, tx.Commit(ctx)
}

// AllocateLinkedDevice creates a new device row for an existing account using a
// primary-supplied password, guarded by the device-list version to serialize
// against concurrent link/unlink. Returns the assigned device id. This is the
// reversed-flow counterpart to ClaimDeviceLinkToken: the primary (already
// authenticated) drives device creation directly after scanning the QR.
func (s *Store) AllocateLinkedDevice(accountID, password, deviceName string, expectedVersion int64) (deviceID uint32, err error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return 0, err
	}
	mailboxID, err := newMailboxID()
	if err != nil {
		return 0, err
	}
	now := coarseDayMillis()
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
	if err := checkDeviceCap(ctx, tx, accountID); err != nil {
		return 0, err
	}
	if deviceID, err = allocateDeviceID(ctx, tx, accountID); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO devices (account_id, device_id, mailbox_id, password_hash, created_at, device_name) VALUES ($1, $2, $3, $4, $5, $6)`,
		accountID, deviceID, mailboxID, hash, now, deviceName); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, `UPDATE accounts SET device_list_version = $1 WHERE id = $2`, currentVersion+1, accountID); err != nil {
		return 0, err
	}
	return deviceID, tx.Commit(ctx)
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
	rows, err := s.db.Query(ctx, `SELECT device_id, registration_id, COALESCE(mailbox_id, ''), COALESCE(device_name, ''), created_at FROM devices WHERE account_id = $1 ORDER BY device_id`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var devices []Device
	for rows.Next() {
		var d Device
		d.AccountID = accountID
		if err := rows.Scan(&d.DeviceID, &d.RegistrationID, &d.MailboxID, &d.Name, &d.CreatedAt); err != nil {
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

	// FK dependents and per-device data first, in the same transaction: its
	// prekeys (signed/Kyber/one-time) and its queued envelopes. Its push
	// tokens, auth key and mailbox id live on the device row itself.
	for _, stmt := range []string{
		`DELETE FROM one_time_prekeys WHERE account_id = $1 AND device_id = $2`,
		`DELETE FROM signed_prekeys WHERE account_id = $1 AND device_id = $2`,
		`DELETE FROM kyber_prekeys WHERE account_id = $1 AND device_id = $2`,
		`DELETE FROM message_queue WHERE account_id = $1 AND device_id = $2`,
	} {
		if _, err := tx.Exec(ctx, stmt, accountID, deviceID); err != nil {
			return 0, err
		}
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

// DeleteAccount permanently removes an account and everything keyed to it, in
// one transaction: prekeys (signed, Kyber, one-time), queued envelopes for its
// devices, its devices (incl. mailbox ids, auth keys, APNs/FCM/VoIP tokens),
// pending device-link tokens, contact invites it minted, its blinded-directory
// rows, stored nuke commands, reports it filed, and finally the account row
// itself (username, email token, Supabase user id, access key, recovery hash).
// The username becomes available again on commit. Reports filed AGAINST the
// account are kept (moderation records). Returns ErrNotFound if the account
// does not exist.
//
// Not cleaned (no account linkage is stored): provisioning_sessions and
// encrypted_group_invites (anonymous, TTL-reaped), attachment blobs (ownership
// is not tracked; reaped by blob GC), and envelopes the account sent that sit
// in other accounts' queues (those belong to the recipients).
// SupabaseUserID returns the Supabase auth user linked to an account, or ""
// when none is (or the account doesn't exist).
func (s *Store) SupabaseUserID(accountID string) (string, error) {
	var id string
	err := s.db.QueryRow(context.Background(),
		`SELECT COALESCE(supabase_user_id, '') FROM accounts WHERE id = $1`, accountID).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return id, err
}

func (s *Store) DeleteAccount(accountID string) error {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	// Lock the account row so concurrent device-list mutations (which also
	// take FOR UPDATE on it) serialize behind the delete.
	var id string
	if err := tx.QueryRow(ctx, `SELECT id FROM accounts WHERE id = $1 FOR UPDATE`, accountID).Scan(&id); errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	} else if err != nil {
		return err
	}
	for _, stmt := range []string{
		// FK dependents of devices first.
		`DELETE FROM one_time_prekeys WHERE account_id = $1`,
		`DELETE FROM signed_prekeys WHERE account_id = $1`,
		`DELETE FROM kyber_prekeys WHERE account_id = $1`,
		`DELETE FROM message_queue WHERE account_id = $1`,
		`DELETE FROM devices WHERE account_id = $1`,
		`DELETE FROM device_link_tokens WHERE account_id = $1`,
		`DELETE FROM contact_invites WHERE account_id = $1`,
		`DELETE FROM directory WHERE account_id = $1`,
		`DELETE FROM nuke_commands WHERE account_id = $1`,
		`DELETE FROM reports WHERE reporter_account = $1`,
		`DELETE FROM accounts WHERE id = $1`,
	} {
		if _, err := tx.Exec(ctx, stmt, accountID); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// AccountExists reports whether an account id is registered.
func (s *Store) AccountExists(accountID string) (bool, error) {
	var exists bool
	err := s.db.QueryRow(context.Background(),
		`SELECT EXISTS (SELECT 1 FROM accounts WHERE id = $1)`, accountID).Scan(&exists)
	return exists, err
}

// Report is one abuse report. Messages is the JSON-encoded array of plaintext
// messages the reporter chose to forward.
type Report struct {
	ID              string
	ReporterAccount string
	ReportedAccount string
	Reason          string
	Details         string
	Messages        string
	CreatedAt       int64
}

// CreateReport stores an abuse report and returns its id.
func (s *Store) CreateReport(reporter, reported, reason, details, messagesJSON string) (string, error) {
	id := newUUID()
	if messagesJSON == "" {
		messagesJSON = "[]"
	}
	_, err := s.db.Exec(context.Background(),
		`INSERT INTO reports (id, reporter_account, reported_account, reason, details, messages, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7)`,
		id, reporter, reported, reason, details, messagesJSON, time.Now().UnixMilli())
	return id, err
}

// ReportsAgainst returns every report filed against an account, oldest first.
// Used by moderation tooling and tests.
func (s *Store) ReportsAgainst(accountID string) ([]Report, error) {
	rows, err := s.db.Query(context.Background(),
		`SELECT id, reporter_account, reported_account, reason, details, messages, created_at
		 FROM reports WHERE reported_account = $1 ORDER BY created_at, id`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Report
	for rows.Next() {
		var r Report
		if err := rows.Scan(&r.ID, &r.ReporterAccount, &r.ReportedAccount, &r.Reason, &r.Details, &r.Messages, &r.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
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
// Comparison is case-insensitive: "Bob" can't be taken while "bob" exists
// (a holder may still change the case of their own name).
func (s *Store) UpdateUsername(accountID, newUsername string) error {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if taken, err := usernameTakenTx(ctx, tx, newUsername, accountID); err != nil {
		return err
	} else if taken {
		return ErrUsernameTaken
	}
	if _, err := tx.Exec(ctx,
		`UPDATE accounts SET username = $1 WHERE id = $2`,
		newUsername, accountID); err != nil {
		if isUniqueViolation(err) {
			return ErrUsernameTaken
		}
		return err
	}
	return tx.Commit(ctx)
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

// SealedTargetByMailbox resolves a mailbox id to its device AND the owning
// account's sealed-sender access key in one query, so the unauthenticated
// sealed path does the same database work whether or not the mailbox exists
// (two dependent queries would make a known mailbox measurably slower).
// accessKey is nil when the account has none set.
func (s *Store) SealedTargetByMailbox(mailboxID string) (*Device, []byte, error) {
	var d Device
	var accessKey []byte
	err := s.db.QueryRow(context.Background(), `
		SELECT d.account_id, d.device_id, d.registration_id, COALESCE(d.mailbox_id, ''), a.access_key
		FROM devices d JOIN accounts a ON a.id = d.account_id
		WHERE d.mailbox_id = $1`,
		mailboxID,
	).Scan(&d.AccountID, &d.DeviceID, &d.RegistrationID, &d.MailboxID, &accessKey)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil, ErrNotFound
	}
	if err != nil {
		return nil, nil, err
	}
	return &d, accessKey, nil
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

// Push token kinds for ClearPushToken.
const (
	PushTokenAPNs = "apns"
	PushTokenFCM  = "fcm"
	PushTokenVoIP = "voip"
)

// ClearPushToken forgets a device's push token of the given kind after the
// provider reported it permanently invalid (APNs 410 Unregistered /
// BadDeviceToken in both environments, FCM UNREGISTERED). It only clears the
// token if it still equals `token`, so a fresh token the device registered in
// the meantime is never wiped.
func (s *Store) ClearPushToken(accountID string, deviceID uint32, kind, token string) error {
	var column string
	switch kind {
	case PushTokenAPNs:
		column = "apns_token"
	case PushTokenFCM:
		column = "fcm_token"
	case PushTokenVoIP:
		column = "voip_token"
	default:
		return fmt.Errorf("store: unknown push token kind %q", kind)
	}
	_, err := s.db.Exec(context.Background(),
		`UPDATE devices SET `+column+` = NULL WHERE account_id = $1 AND device_id = $2 AND `+column+` = $3`,
		accountID, deviceID, token)
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
// Prekey rows carry no upload time (created_at = 0): rewriting it on every
// upload made the table a per-device "last active" log.
func (s *Store) SetKeys(accountID string, deviceID uint32, registrationID uint32, identityKey []byte, spk SignedPreKey, kyber SignedPreKey, oneTime []OneTimePreKey, replaceOneTime bool) error {
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
		VALUES ($1, $2, $3, $4, $5, 0)
		ON CONFLICT (account_id, device_id) DO UPDATE SET
			key_id = EXCLUDED.key_id, public_key = EXCLUDED.public_key,
			signature = EXCLUDED.signature`,
		accountID, deviceID, spk.KeyID, spk.PublicKey, spk.Signature); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO kyber_prekeys (account_id, device_id, key_id, public_key, signature, created_at)
		VALUES ($1, $2, $3, $4, $5, 0)
		ON CONFLICT (account_id, device_id) DO UPDATE SET
			key_id = EXCLUDED.key_id, public_key = EXCLUDED.public_key,
			signature = EXCLUDED.signature`,
		accountID, deviceID, kyber.KeyID, kyber.PublicKey, kyber.Signature); err != nil {
		return err
	}
	// A client that knows its local key store is fresh (first launch after
	// install/restore) or has detected a desync replaces the whole pool, so the
	// relay never advertises a stale high-id key the device no longer holds the
	// private for (which decrypts to recordNotFound and is silently dropped).
	// Scoped to this device only; sibling devices' pools are untouched.
	if replaceOneTime {
		if _, err := tx.Exec(ctx, `DELETE FROM one_time_prekeys WHERE account_id = $1 AND device_id = $2`,
			accountID, deviceID); err != nil {
			return err
		}
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
// one-time prekey per bundle when available. allowOneTime (nil = always) is
// asked only when the device actually has a one-time prekey to hand out; if it
// returns false the bundle is served without one (signed + last-resort Kyber
// prekey only) and the pool is left untouched.
func (s *Store) TakePreKeyBundles(accountID string, deviceIDs []uint32, allowOneTime func(deviceID uint32) bool) ([]PreKeyBundle, error) {
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
		case allowOneTime != nil && !allowOneTime(devID):
			// Hand-out budget spent: serve the bundle without a one-time key.
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

// Enqueue stores a serialized envelope for a device until it is acked. A device
// may hold at most maxQueuedPerDevice envelopes and maxQueuedBytesPerDevice
// bytes of queued ciphertext; beyond either, ErrQueueFull. Expired rows are
// reaped by PurgeExpired (hourly), not on this hot path.
func (s *Store) Enqueue(envelopeID, accountID string, deviceID uint32, envelope []byte) error {
	ctx := context.Background()
	if len(envelope) > maxQueuedEnvelopeBytes {
		return ErrEnvelopeTooLarge
	}
	var queued int
	var queuedBytes int64
	if err := s.db.QueryRow(ctx,
		`SELECT COUNT(*), COALESCE(SUM(octet_length(envelope)), 0) FROM message_queue WHERE account_id = $1 AND device_id = $2`,
		accountID, deviceID).Scan(&queued, &queuedBytes); err != nil {
		return err
	}
	if queued >= maxQueuedPerDevice || queuedBytes+int64(len(envelope)) > maxQueuedBytesPerDevice {
		return ErrQueueFull
	}
	_, err := s.db.Exec(ctx, `
		INSERT INTO message_queue (envelope_id, account_id, device_id, envelope, created_at)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (envelope_id, account_id, device_id) DO NOTHING`,
		envelopeID, accountID, deviceID, envelope, time.Now().UnixMilli())
	return err
}

// QueuedEnvelope is one row of a device's offline queue.
type QueuedEnvelope struct {
	ID        string
	CreatedAt int64
	Envelope  []byte // serialized relay.v1.Envelope
}

// QueueCursor positions a queue read strictly after a given envelope (the
// queue is ordered by (created_at, envelope_id)). The zero value starts at the
// oldest envelope.
type QueueCursor struct {
	CreatedAt  int64
	EnvelopeID string
}

// QueuedEnvelopesPage returns up to limit of a device's pending envelopes after
// cursor, oldest first, stopping early once the page holds maxBytes of
// ciphertext (a page always carries at least one envelope when any remain).
// more reports whether further envelopes exist past the returned page; resume
// with the cursor of its last element. Unexpired rows only. Rows are streamed
// from the database, so memory is bounded by the page, not the queue.
func (s *Store) QueuedEnvelopesPage(accountID string, deviceID uint32, after QueueCursor, limit, maxBytes int) (page []QueuedEnvelope, more bool, err error) {
	if limit <= 0 {
		limit = 1
	}
	ctx := context.Background()
	cutoff := time.Now().UnixMilli() - queueTTLMillis
	rows, err := s.db.Query(ctx, `
		SELECT envelope_id, created_at, envelope FROM message_queue
		WHERE account_id = $1 AND device_id = $2 AND created_at >= $3
		  AND (created_at, envelope_id) > ($4, $5)
		ORDER BY created_at, envelope_id
		LIMIT $6`,
		accountID, deviceID, cutoff, after.CreatedAt, after.EnvelopeID, limit+1)
	if err != nil {
		return nil, false, err
	}
	defer rows.Close()
	total := 0
	for rows.Next() {
		var q QueuedEnvelope
		if err := rows.Scan(&q.ID, &q.CreatedAt, &q.Envelope); err != nil {
			return nil, false, err
		}
		if len(page) == limit || (len(page) > 0 && total+len(q.Envelope) > maxBytes) {
			return page, true, nil // rows.Close (deferred) discards the rest
		}
		page = append(page, q)
		total += len(q.Envelope)
	}
	return page, false, rows.Err()
}

// Dequeue removes an envelope after the client has acked it.
func (s *Store) Dequeue(envelopeID, accountID string, deviceID uint32) error {
	ctx := context.Background()
	_, err := s.db.Exec(ctx, `DELETE FROM message_queue WHERE envelope_id = $1 AND account_id = $2 AND device_id = $3`,
		envelopeID, accountID, deviceID)
	return err
}

// PurgeExpired deletes every row that has outlived its retention window. Run
// hourly by relayd so expired data doesn't linger until some request happens
// to touch the table:
//
//   - message_queue: envelopes older than 14 days
//   - encrypted_group_invites, provisioning_sessions, device_link_tokens: expired
//   - contact_invites: expired or already used (single-use)
//   - reports: older than 180 days
//   - nuke_commands: older than an hour (delivered or stale; see nukeRetentionMillis)
func (s *Store) PurgeExpired() error {
	ctx := context.Background()
	now := time.Now().UnixMilli()
	for _, q := range []struct {
		sql string
		arg int64
	}{
		{`DELETE FROM message_queue WHERE created_at < $1`, now - queueTTLMillis},
		{`DELETE FROM encrypted_group_invites WHERE expires_at < $1`, now},
		{`DELETE FROM provisioning_sessions WHERE expires_at < $1`, now},
		{`DELETE FROM device_link_tokens WHERE expires_at < $1`, now},
		{`DELETE FROM contact_invites WHERE expires_at < $1 OR used_at <> 0`, now},
		{`DELETE FROM reports WHERE created_at < $1`, now - reportTTLMillis},
		{`DELETE FROM nuke_commands WHERE created_at < $1`, now - nukeRetentionMillis},
	} {
		if _, err := s.db.Exec(ctx, q.sql, q.arg); err != nil {
			return err
		}
	}
	return nil
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
		`SELECT id, COALESCE(username, ''), email_token FROM accounts ORDER BY created_at, id`)
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
		if err := upsertDirectoryEntry(ctx, tx, e); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// upsertDirectoryEntry inserts one directory row. A token already owned by a
// DIFFERENT account is never reassigned (first owner keeps it; the collision is
// logged) — otherwise registering a case-variant or otherwise colliding
// identifier could hijack another user's discovery entry.
func upsertDirectoryEntry(ctx context.Context, tx pgx.Tx, e DirectoryEntry) error {
	tag, err := tx.Exec(ctx,
		`INSERT INTO directory (token, account_id, kind) VALUES ($1, $2, $3)
         ON CONFLICT (token) DO UPDATE SET kind = EXCLUDED.kind
         WHERE directory.account_id = EXCLUDED.account_id`,
		e.Token, e.AccountID, e.Kind)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		slog.Warn("store: directory token already owned by another account; not reassigned", "kind", e.Kind)
	}
	return nil
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
		if err := upsertDirectoryEntry(ctx, tx, e); err != nil {
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
