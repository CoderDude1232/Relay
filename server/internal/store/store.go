// Package store is the relay's persistence layer, backed by PostgreSQL.
//
// The relay stores only what it must to route ciphertext: accounts,
// devices, public prekey material, and queued (still-encrypted) envelopes
// awaiting delivery. No plaintext, no private keys, ever.
package store

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
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
	ErrPreKeyPoolFull            = errors.New("store: one-time prekey pool full")
	ErrStrongerSignInRequired    = errors.New("store: account has a passkey or recovery key")
	// ErrRegistrationLockActive: the account has an account password and was
	// used recently, so an email reset can't take it over yet.
	ErrRegistrationLockActive = errors.New("store: registration lock active")
	ErrAccountPasswordRequired   = errors.New("store: account password required")
	ErrAccountPasswordIncorrect  = errors.New("store: account password incorrect")
	ErrAccountPasswordLocked     = errors.New("store: too many account password attempts")
)

// MaxOneTimePreKeysPerDevice caps the one-time prekeys stored for one device.
// Clients replenish below ~20 in batches of 100, so an honest pool never gets
// near it. An upload that would exceed it is rejected whole (ErrPreKeyPoolFull).
const MaxOneTimePreKeysPerDevice = 2000

// MaxOneTimeKyberPreKeysPerDevice caps a device's one-time Kyber pool (each
// public key is ~1.5 KB).
const MaxOneTimeKyberPreKeysPerDevice = 200

// maxDevicesPerAccount caps the devices an account may have at once, bounding
// the damage from a linking compromise.
const maxDevicesPerAccount = 5

const maxGroupMembers = 256

// QueueTTL is how long an undelivered envelope is kept before PurgeExpired
// drops it.
const QueueTTL = 14 * 24 * time.Hour

const (
	queueTTLMillis         = int64(QueueTTL / time.Millisecond)
	maxQueuedEnvelopeBytes = 512 * 1024
	maxQueuedPerDevice     = 500
	// maxQueuedBytesPerDevice caps a device's total queued ciphertext so the
	// count cap can't be turned into 500 max-size envelopes per device.
	maxQueuedBytesPerDevice = 50 << 20
	// Abuse reports are kept for 180 days.
	reportTTLMillis = int64((180 * 24 * time.Hour) / time.Millisecond)
	// Clients reject nuke commands older than 5 minutes, so stored rows older
	// than an hour are useless and get purged.
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
	// releaseKey keys the released-username hashes (see SetUsernameReleaseKey);
	// nil disables the reuse cooldown. Set once at startup.
	releaseKey []byte
}

// Open connects to PostgreSQL at dsn, pings it, and runs schema migrations.
// The dsn has the form postgres://user:password@host:5432/dbname?sslmode=require.
func Open(dsn string) (*Store, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	cfg.MaxConns = 20
	cfg.MinConns = 2
	// No request context reaches the store, so bound queries and lock waits
	// server-side: a stuck one can't hold a pool connection forever.
	if cfg.ConnConfig.RuntimeParams == nil {
		cfg.ConnConfig.RuntimeParams = map[string]string{}
	}
	if _, set := cfg.ConnConfig.RuntimeParams["statement_timeout"]; !set {
		cfg.ConnConfig.RuntimeParams["statement_timeout"] = "15000"
	}
	if _, set := cfg.ConnConfig.RuntimeParams["lock_timeout"]; !set {
		cfg.ConnConfig.RuntimeParams["lock_timeout"] = "10000"
	}
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

// isLocalDBHost reports whether a PostgreSQL host is loopback or a unix-socket
// directory (an absolute path).
func isLocalDBHost(host string) bool {
	if host == "" || strings.HasPrefix(host, "/") || host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// migrationExec runs one migration step without the pool's per-statement
// timeouts: an ALTER TABLE waiting behind live traffic, or an index build on a
// big table, would otherwise fail and stop relayd from starting.
func (s *Store) migrationExec(ctx context.Context, sql string) error {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SET LOCAL statement_timeout = 0; SET LOCAL lock_timeout = '120s'`); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, sql); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *Store) migrate() error {
	ctx := context.Background()
	err := s.migrationExec(ctx, `
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
	// Idempotent migrations, safe to rerun on existing databases.
	for _, stmt := range []string{
		`ALTER TABLE devices ADD COLUMN IF NOT EXISTS mailbox_id TEXT`,
		`ALTER TABLE devices ADD COLUMN IF NOT EXISTS auth_public_key BYTEA`,
		`ALTER TABLE accounts ADD COLUMN IF NOT EXISTS device_list_version BIGINT NOT NULL DEFAULT 0`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_devices_mailbox_id ON devices (mailbox_id) WHERE mailbox_id IS NOT NULL`,
		`ALTER TABLE groups ADD COLUMN IF NOT EXISTS description TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE groups ADD COLUMN IF NOT EXISTS avatar_id   TEXT NOT NULL DEFAULT ''`,
		// Presence is kept in memory only.
		`DROP TABLE IF EXISTS presence`,
		// Don't record who created an invite link or when.
		`ALTER TABLE group_invites DROP COLUMN IF EXISTS creator`,
		`ALTER TABLE group_invites DROP COLUMN IF EXISTS created_at`,
		// Admin roles and announce-only mode.
		`ALTER TABLE groups ADD COLUMN IF NOT EXISTS admins TEXT[] NOT NULL DEFAULT '{}'`,
		`ALTER TABLE groups ADD COLUMN IF NOT EXISTS announce_only BOOLEAN NOT NULL DEFAULT FALSE`,
		// Group invite tokens expire after 7 days.
		`ALTER TABLE group_invites ADD COLUMN IF NOT EXISTS expires_at BIGINT NOT NULL DEFAULT 0`,
		`CREATE INDEX IF NOT EXISTS idx_group_invites_expires_at ON group_invites (expires_at)`,
		`ALTER TABLE accounts ADD COLUMN IF NOT EXISTS email TEXT`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_email ON accounts (email) WHERE email IS NOT NULL AND email <> ''`,
		// Account-level recovery password, separate from per-device passwords.
		`ALTER TABLE accounts ADD COLUMN IF NOT EXISTS account_password_hash BYTEA`,
		// Links an account to its Supabase user so a returning OAuth user can
		// sign back in with a verified Supabase token.
		`ALTER TABLE accounts ADD COLUMN IF NOT EXISTS supabase_user_id TEXT`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_supabase_user_id ON accounts (supabase_user_id) WHERE supabase_user_id IS NOT NULL AND supabase_user_id <> ''`,
		// Single-use contact invite tokens.
		`CREATE TABLE IF NOT EXISTS contact_invites (
    token       TEXT PRIMARY KEY,
    account_id  TEXT NOT NULL,
    expires_at  BIGINT NOT NULL,
    used_at     BIGINT NOT NULL DEFAULT 0
)`,
		`CREATE INDEX IF NOT EXISTS idx_contact_invites_expires ON contact_invites (expires_at)`,
		// Sealed-sender access key, checked on the unauthenticated delivery path
		// without learning who sent the message.
		`ALTER TABLE accounts ADD COLUMN IF NOT EXISTS access_key BYTEA`,
		// Blinded discovery index. token is H2(x, H1(x)^k) for a normalized
		// username or email x. The server can compute it for its own users; a
		// client can only match, not enumerate, via the OPRF. kind is 0 for
		// username, 1 for email.
		`CREATE TABLE IF NOT EXISTS directory (
    token      BYTEA NOT NULL,
    account_id TEXT NOT NULL,
    kind       SMALLINT NOT NULL,
    PRIMARY KEY (token)
)`,
		`CREATE INDEX IF NOT EXISTS idx_directory_account ON directory (account_id)`,
		// Bucketed lookups: the client sends only a 16-bit bucket and matches
		// locally. Each row has its bucket, an 8-byte match tag and an AES-GCM
		// box of (accountId, username) under a token-derived key. The index is
		// rebuilt at every startup.
		`ALTER TABLE directory ADD COLUMN IF NOT EXISTS bucket INTEGER`,
		`ALTER TABLE directory ADD COLUMN IF NOT EXISTS tag BYTEA`,
		`ALTER TABLE directory ADD COLUMN IF NOT EXISTS box BYTEA`,
		// The account's sealed-sender access key under the same token-derived
		// key as box, so anyone who can find an account can also send to it
		// anonymously from the first message.
		`ALTER TABLE directory ADD COLUMN IF NOT EXISTS access_box BYTEA`,
		`CREATE INDEX IF NOT EXISTS idx_directory_bucket ON directory (bucket)`,
		// Group invites are opaque blobs keyed by token. The decryption key is in
		// the invite URL fragment, so the server never learns the group id, name
		// or roster.
		`CREATE TABLE IF NOT EXISTS encrypted_group_invites (
    token      TEXT PRIMARY KEY,
    blob       BYTEA NOT NULL,
    expires_at BIGINT NOT NULL
)`,
		`CREATE INDEX IF NOT EXISTS idx_encrypted_group_invites_expires ON encrypted_group_invites (expires_at)`,
		// Groups are client-managed; drop all server-side group state.
		// Tables with foreign keys to groups go first.
		`DROP TABLE IF EXISTS group_invites`,
		`DROP TABLE IF EXISTS group_members`,
		`DROP TABLE IF EXISTS groups`,
		// Opt-in ciphertext in the APNs payload. The default is a content-free
		// wake, so Apple's servers never carry the encrypted envelope.
		`ALTER TABLE devices ADD COLUMN IF NOT EXISTS push_include_content BOOLEAN NOT NULL DEFAULT FALSE`,
		// push_kind is 'apns' or 'fcm' and selects apns_token or fcm_token.
		`ALTER TABLE devices ADD COLUMN IF NOT EXISTS fcm_token TEXT`,
		`ALTER TABLE devices ADD COLUMN IF NOT EXISTS push_kind TEXT NOT NULL DEFAULT 'apns'`,
		`ALTER TABLE devices ADD COLUMN IF NOT EXISTS device_name TEXT`,
		// The day (unix days) a device last made a signed request: coarse on
		// purpose, it only decides whether the registration lock still holds.
		// Existing devices start at today, so the lock applies from the start.
		`ALTER TABLE devices ADD COLUMN IF NOT EXISTS last_active_day BIGINT NOT NULL DEFAULT (floor(extract(epoch from now()) / 86400))::bigint`,
		// Device names travel end-to-end encrypted between the account's own
		// devices; the relay keeps none.
		`UPDATE devices SET device_name = NULL WHERE device_name IS NOT NULL`,
		// Emails are stored only as their OPRF-keyed token (the same one used for
		// blinded discovery), never in plaintext. All email lookups match on it.
		`ALTER TABLE accounts ADD COLUMN IF NOT EXISTS email_token BYTEA`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_email_token ON accounts (email_token) WHERE email_token IS NOT NULL`,
		// Backfill from the directory, which holds oprf.Token(email) per account,
		// then drop the plaintext column.
		`UPDATE accounts a SET email_token = d.token FROM directory d WHERE d.account_id = a.id AND d.kind = 1 AND a.email_token IS NULL`,
		`DROP INDEX IF EXISTS idx_accounts_email`,
		`ALTER TABLE accounts DROP COLUMN IF EXISTS email`,
		// Reversed device linking. The new device shows its ephemeral key in a
		// QR code; the primary encrypts the provisioning payload to it and
		// stores the ciphertext here. The relay never sees the key or plaintext.
		`CREATE TABLE IF NOT EXISTS provisioning_sessions (
    session_id TEXT PRIMARY KEY,
    blob       BYTEA,
    expires_at BIGINT NOT NULL,
    created_at BIGINT NOT NULL
)`,
		`CREATE INDEX IF NOT EXISTS idx_provisioning_sessions_expires ON provisioning_sessions (expires_at)`,
		// Abuse reports. No foreign keys to accounts, so a report survives the
		// reported account's deletion; reports an account filed are removed by
		// DeleteAccount. messages is a JSON array of plaintext messages the
		// reporter chose to forward.
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
		// Monotonic per-account device-id counter, so a removed device's id is
		// never reused (peers may still hold sessions keyed by it). 0 means
		// unset; allocation takes the max of this and MAX(device_id).
		`ALTER TABLE accounts ADD COLUMN IF NOT EXISTS next_device_id BIGINT NOT NULL DEFAULT 0`,
		// Prekey upload times would act as a last-active signal, so they aren't
		// kept; account and device creation times are rounded to the day.
		`UPDATE signed_prekeys SET created_at = 0 WHERE created_at <> 0`,
		`UPDATE kyber_prekeys SET created_at = 0 WHERE created_at <> 0`,
		`UPDATE accounts SET created_at = created_at - created_at % 86400000 WHERE created_at % 86400000 <> 0`,
		`UPDATE devices SET created_at = created_at - created_at % 86400000 WHERE created_at % 86400000 <> 0`,
		// Email discovery is opt-in: a verified email gets a directory entry
		// only once the owner enables it.
		`ALTER TABLE accounts ADD COLUMN IF NOT EXISTS email_discoverable BOOLEAN NOT NULL DEFAULT FALSE`,
		// Optional phone number, for discovery only: stored as its OPRF token
		// (never the number), verified by SMS (store/phone.go).
		`ALTER TABLE accounts ADD COLUMN IF NOT EXISTS phone_token BYTEA`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_phone_token ON accounts (phone_token) WHERE phone_token IS NOT NULL`,
		`ALTER TABLE accounts ADD COLUMN IF NOT EXISTS phone_discoverable BOOLEAN NOT NULL DEFAULT FALSE`,
		// Review/test accounts, isolated from everyone else (store/demo.go).
		`ALTER TABLE accounts ADD COLUMN IF NOT EXISTS is_demo BOOLEAN NOT NULL DEFAULT FALSE`,
		// One-time Kyber prekeys; the last-resort key stays in kyber_prekeys.
		`CREATE TABLE IF NOT EXISTS one_time_kyber_prekeys (
    account_id TEXT NOT NULL,
    device_id  INTEGER NOT NULL,
    key_id     BIGINT NOT NULL,
    public_key BYTEA NOT NULL,
    signature  BYTEA NOT NULL,
    PRIMARY KEY (account_id, device_id, key_id),
    FOREIGN KEY (account_id, device_id) REFERENCES devices(account_id, device_id)
)`,
		// Client-encrypted chat/group list (store/account_storage.go).
		`CREATE TABLE IF NOT EXISTS account_storage (
    account_id TEXT PRIMARY KEY REFERENCES accounts(id),
    blob       BYTEA NOT NULL,
    version    BIGINT NOT NULL,
    updated_at BIGINT NOT NULL
)`,
		// Username reuse cooldown (see UsernameReuseCooldown). Only keyed hashes
		// and the release time are stored, never the name.
		`CREATE TABLE IF NOT EXISTS released_usernames (
    name_hash   BYTEA PRIMARY KEY,
    owner_hash  BYTEA,
    released_at BIGINT NOT NULL
)`,
		`CREATE INDEX IF NOT EXISTS idx_released_usernames_released_at ON released_usernames (released_at)`,
		// Passkeys (store/passkeys.go). The WebAuthn user handle is random per
		// account, never the account id.
		`ALTER TABLE accounts ADD COLUMN IF NOT EXISTS passkey_user_handle BYTEA`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_passkey_user_handle ON accounts (passkey_user_handle) WHERE passkey_user_handle IS NOT NULL`,
		`CREATE TABLE IF NOT EXISTS passkeys (
    credential_id BYTEA PRIMARY KEY,
    account_id    TEXT NOT NULL REFERENCES accounts(id),
    credential    JSONB NOT NULL,
    name          TEXT NOT NULL DEFAULT '',
    created_at    BIGINT NOT NULL
)`,
		`CREATE INDEX IF NOT EXISTS idx_passkeys_account ON passkeys (account_id)`,
		// Recovery key (store/recovery_key.go): only its SHA-256 is stored.
		`ALTER TABLE accounts ADD COLUMN IF NOT EXISTS recovery_key_hash BYTEA`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_recovery_key_hash ON accounts (recovery_key_hash) WHERE recovery_key_hash IS NOT NULL`,
		// The hourly expiry purge filters on created_at alone.
		`CREATE INDEX IF NOT EXISTS idx_queue_created_at ON message_queue (created_at)`,
		// Pending sign-in-method notices for a device (account_notices.go).
		`CREATE TABLE IF NOT EXISTS account_notices (
    account_id TEXT NOT NULL,
    device_id  INTEGER NOT NULL,
    kind       TEXT NOT NULL,
    created_at BIGINT NOT NULL,
    FOREIGN KEY (account_id, device_id) REFERENCES devices(account_id, device_id) ON DELETE CASCADE
)`,
		`CREATE INDEX IF NOT EXISTS idx_account_notices_device ON account_notices (account_id, device_id)`,
		// Chat-list blobs keep only the day they last changed.
		`UPDATE account_storage SET updated_at = updated_at - (updated_at % 86400000) WHERE updated_at % 86400000 <> 0`,
		// The legacy forward-QR link tokens went with their routes; device
		// linking uses provisioning sessions.
		`DROP TABLE IF EXISTS device_link_tokens`,
		// Supabase auth users still to delete after their account was deleted
		// (supabase_deletions.go). Only the Supabase user id is kept.
		`CREATE TABLE IF NOT EXISTS pending_supabase_deletions (
    user_id    TEXT PRIMARY KEY,
    created_at BIGINT NOT NULL
)`,
		// Chat-history backup segments (store/history.go); the blobs live in
		// files named by a keyed hash, at location 'local' or 'remote'.
		`CREATE TABLE IF NOT EXISTS history_segments (
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    seq        BIGINT NOT NULL,
    size       INT NOT NULL,
    location   TEXT NOT NULL,
    created_at BIGINT NOT NULL,
    PRIMARY KEY (account_id, seq)
)`,
	} {
		if err := s.migrationExec(ctx, stmt); err != nil {
			return err
		}
	}
	s.ensureUsernameCaseIndex(ctx)
	return s.ensureMailboxIDs(ctx)
}

// ensureUsernameCaseIndex adds a unique index on lower(username) so "Bob" and
// "bob" can't coexist (they'd also share one blinded-directory token, since
// discovery normalizes case). If case-variant duplicates already exist the
// index can't be built, so it logs and continues rather than refusing to start:
// registration and rename still enforce case-insensitive uniqueness, and the
// directory never reassigns a token from its first owner.
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

// CreateAccount registers a new account and its primary device (device 1).
// emailToken (the OPRF-keyed hash of a verified email), supabaseUserID and
// accountPassword are optional; pass nil or "" to omit. accountPassword is
// stored as a bcrypt hash for account recovery.
//
// Usernames are unique case-insensitively. Returns ErrUsernameTaken when the
// username is in use, ErrIdentityInUse when the email token or Supabase user id
// already belongs to another account.
func (s *Store) CreateAccount(username string, emailToken []byte, supabaseUserID, devicePassword string, accountPassword AccountPassword) (accountID string, deviceID uint32, err error) {
	deviceHash, err := bcrypt.GenerateFromPassword([]byte(devicePassword), bcrypt.DefaultCost)
	if err != nil {
		return "", 0, err
	}
	accountHash, err := accountPassword.hash()
	if err != nil {
		return "", 0, err
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

	if taken, err := s.usernameUnavailableTx(ctx, tx, username, ""); err != nil {
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
	if err = s.clearReleasedUsernameTx(ctx, tx, username); err != nil {
		return "", 0, err
	}
	return accountID, 1, tx.Commit(ctx)
}

// accountInsertError maps a unique violation on the accounts table to a
// sentinel: ErrIdentityInUse for the email-token or Supabase-user index
// (callers must not say which), ErrUsernameTaken otherwise.
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

// usernameUnavailableTx reports whether username can't be taken by
// exceptAccountID ("" for a new account): another account holds it, compared
// case-insensitively, or another account released it less than
// UsernameReuseCooldown ago.
func (s *Store) usernameUnavailableTx(ctx context.Context, q rowQuerier, username, exceptAccountID string) (bool, error) {
	if ReservedUsername(username) {
		return true, nil
	}
	var taken bool
	if err := q.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM accounts WHERE lower(username) = lower($1) AND id <> $2)`,
		username, exceptAccountID).Scan(&taken); err != nil || taken {
		return taken, err
	}
	nameHash := s.releasedNameHash(username)
	if nameHash == nil {
		return false, nil // cooldown disabled (no key configured)
	}
	cutoff := time.Now().Add(-UsernameReuseCooldown).UnixMilli()
	var cooling bool
	err := q.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM released_usernames
		WHERE name_hash = $1 AND released_at > $2 AND (owner_hash IS NULL OR owner_hash <> $3))`,
		nameHash, cutoff, s.releasedOwnerHash(exceptAccountID)).Scan(&cooling)
	return cooling, err
}

// UsernameTaken reports whether username is unavailable to a new account: held
// by any account (case-insensitive) or still in its reuse cooldown.
func (s *Store) UsernameTaken(username string) (bool, error) {
	return s.usernameUnavailableTx(context.Background(), s.db, username, "")
}

// ---------------------------------------------------------------------------
// Username reuse cooldown
// ---------------------------------------------------------------------------

// UsernameReuseCooldown is how long a released username stays unclaimable by
// other accounts. Sealed-sender certificates carry the sender's username for
// up to 7 days, so a name re-registered sooner could appear as the author of
// messages vouched for by its previous holder's certificates. The releasing
// account may reclaim the name during the cooldown; a deleted account's name
// is blocked for everyone.
const UsernameReuseCooldown = 7 * 24 * time.Hour

// SetUsernameReleaseKey sets the secret that keys released-username hashes.
// released_usernames stores only HMAC(key, lower(name)), HMAC(key, owner
// account id) and the release time, so a database dump doesn't list recently
// abandoned names. Without a key the cooldown is disabled. relayd derives the
// key from the OPRF key, so it is stable across restarts.
func (s *Store) SetUsernameReleaseKey(key []byte) {
	s.releaseKey = append([]byte(nil), key...)
}

func (s *Store) releaseHMAC(parts ...string) []byte {
	if len(s.releaseKey) == 0 {
		return nil
	}
	m := hmac.New(sha256.New, s.releaseKey)
	for _, p := range parts {
		m.Write([]byte(p))
		m.Write([]byte{0})
	}
	return m.Sum(nil)
}

// releasedNameHash is the keyed hash of a username, case-folded the way
// uniqueness is enforced. nil when no key is configured.
func (s *Store) releasedNameHash(username string) []byte {
	return s.releaseHMAC("relay-released-username-v1", strings.ToLower(username))
}

// releasedOwnerHash is the keyed hash of the releasing account id. "" (a new
// account) hashes to a value no real account id produces.
func (s *Store) releasedOwnerHash(accountID string) []byte {
	return s.releaseHMAC("relay-released-username-owner-v1", accountID)
}

// releaseUsernameTx starts the reuse cooldown for username inside tx.
// ownerAccountID is the account that may still reclaim it ("" when the account
// is being deleted, so no one can). A no-op when no key is configured.
func (s *Store) releaseUsernameTx(ctx context.Context, tx pgx.Tx, username, ownerAccountID string) error {
	nameHash := s.releasedNameHash(username)
	if nameHash == nil || username == "" {
		return nil
	}
	var owner []byte
	if ownerAccountID != "" {
		owner = s.releasedOwnerHash(ownerAccountID)
	}
	_, err := tx.Exec(ctx, `
		INSERT INTO released_usernames (name_hash, owner_hash, released_at) VALUES ($1, $2, $3)
		ON CONFLICT (name_hash) DO UPDATE SET owner_hash = EXCLUDED.owner_hash, released_at = EXCLUDED.released_at`,
		nameHash, owner, time.Now().UnixMilli())
	return err
}

// clearReleasedUsernameTx drops the cooldown row for a name that has just been
// claimed after usernameUnavailableTx allowed it.
func (s *Store) clearReleasedUsernameTx(ctx context.Context, tx pgx.Tx, username string) error {
	nameHash := s.releasedNameHash(username)
	if nameHash == nil {
		return nil
	}
	_, err := tx.Exec(ctx, `DELETE FROM released_usernames WHERE name_hash = $1`, nameHash)
	return err
}

// dummyRecoveryHash is compared against when an account or its recovery
// password doesn't exist, so every attempt costs one bcrypt and timing can't
// reveal whether an email is registered.
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
	// ReplacedDevices are the account's previous devices, removed because a
	// fresh sign-in or recovery starts a new identity.
	ReplacedDevices []uint32
}

// replaceDevicesTx removes every device of accountID (with its prekeys and
// queued envelopes) inside tx, returning their ids. A sign-in or recovery on a
// fresh install has no copy of the account's identity key, so it replaces the
// existing devices rather than joining them. Devices that should coexist are
// added through device linking, which shares the key.
func replaceDevicesTx(ctx context.Context, tx pgx.Tx, accountID string) ([]uint32, error) {
	// Locking the device rows (see Enqueue) means no envelope can land in a
	// queue after it is cleared below.
	rows, err := tx.Query(ctx, `SELECT device_id FROM devices WHERE account_id = $1 ORDER BY device_id FOR UPDATE`, accountID)
	if err != nil {
		return nil, err
	}
	var ids []uint32
	for rows.Next() {
		var id uint32
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		ids = append(ids, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for _, stmt := range []string{
		`DELETE FROM one_time_prekeys WHERE account_id = $1`,
		`DELETE FROM one_time_kyber_prekeys WHERE account_id = $1`,
		`DELETE FROM signed_prekeys WHERE account_id = $1`,
		`DELETE FROM kyber_prekeys WHERE account_id = $1`,
		`DELETE FROM message_queue WHERE account_id = $1`,
		`DELETE FROM devices WHERE account_id = $1`,
	} {
		if _, err := tx.Exec(ctx, stmt, accountID); err != nil {
			return nil, err
		}
	}
	return ids, nil
}

// addDeviceTx provisions a new device on accountID inside tx: it locks the
// account row, enforces maxDevicesPerAccount, inserts the device and bumps
// device_list_version so signed device lists are invalidated.
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
// and provisions a new device with a fresh random password. Every failure
// (unknown email, no recovery password, wrong password) returns ErrAuthFailed
// after one bcrypt comparison, so neither the result nor its timing reveals
// whether the email is registered. ErrDeviceLimit is only reachable with the
// right password.
func (s *Store) RecoverAccount(emailToken []byte, accountPassword AccountPassword) (dev AddedDevice, devicePassword string, err error) {
	ctx := context.Background()

	var accountHash []byte
	err = s.db.QueryRow(ctx,
		`SELECT id, username, account_password_hash FROM accounts WHERE email_token = $1`, emailToken,
	).Scan(&dev.AccountID, &dev.Username, &accountHash)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && len(accountHash) == 0) {
		accountPassword.burn()
		return AddedDevice{}, "", ErrAuthFailed
	}
	if err != nil {
		return AddedDevice{}, "", err
	}
	ok, upgraded, err := accountPassword.verify(accountHash)
	if err != nil {
		return AddedDevice{}, "", err
	}
	if !ok {
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
	if upgraded != nil {
		if _, err = tx.Exec(ctx, `UPDATE accounts SET account_password_hash = $1 WHERE id = $2`, upgraded, dev.AccountID); err != nil {
			return AddedDevice{}, "", err
		}
	}
	if dev.ReplacedDevices, err = replaceDevicesTx(ctx, tx, dev.AccountID); err != nil {
		return AddedDevice{}, "", err
	}
	dev.DeviceID, dev.MailboxID, dev.DeviceListVersion, err = addDeviceTx(ctx, tx, dev.AccountID, deviceHash)
	if err != nil {
		return AddedDevice{}, "", err
	}
	if err = tx.Commit(ctx); err != nil {
		return AddedDevice{}, "", err
	}
	return dev, devicePassword, nil
}

// SetAccountPassword sets (or replaces) the account password: the bcrypt hash
// that both email recovery and the sign-in registration lock check.
func (s *Store) SetAccountPassword(accountID string, accountPassword AccountPassword) error {
	hash, err := accountPassword.hash()
	if err != nil {
		return err
	}
	tag, err := s.db.Exec(context.Background(),
		`UPDATE accounts SET account_password_hash = $1 WHERE id = $2`, hash, accountID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrAccountNotFound
	}
	return nil
}

// ResetAccountPassword handles a forgotten password. The caller has proven
// control of the account's verified email through a Supabase recovery sign-in.
// It finds the account by Supabase user id, then by email token, sets the new
// password and replaces the account's devices with one new device. Returns
// ErrAccountNotFound if no account matches.
func (s *Store) ResetAccountPassword(supabaseUserID string, emailToken []byte, accountPassword AccountPassword, devicePassword string) (dev AddedDevice, err error) {
	ctx := context.Background()
	accountHash, err := accountPassword.hash()
	if err != nil {
		return AddedDevice{}, err
	}
	deviceHash, err := bcrypt.GenerateFromPassword([]byte(devicePassword), bcrypt.DefaultCost)
	if err != nil {
		return AddedDevice{}, err
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return AddedDevice{}, err
	}
	defer tx.Rollback(ctx)

	// FOR UPDATE: a passkey or recovery key added concurrently must not slip
	// past the check below.
	var demo, stronger bool
	const pick = `SELECT id, username, is_demo,
	        recovery_key_hash IS NOT NULL OR EXISTS (SELECT 1 FROM passkeys p WHERE p.account_id = accounts.id)
	   FROM accounts `
	err = tx.QueryRow(ctx, pick+`WHERE supabase_user_id = $1 FOR UPDATE`, supabaseUserID).Scan(&dev.AccountID, &dev.Username, &demo, &stronger)
	if errors.Is(err, pgx.ErrNoRows) && len(emailToken) > 0 {
		err = tx.QueryRow(ctx, pick+`WHERE email_token = $1 FOR UPDATE`, emailToken).Scan(&dev.AccountID, &dev.Username, &demo, &stronger)
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return AddedDevice{}, ErrAccountNotFound
	}
	if err != nil {
		return AddedDevice{}, err
	}
	if demo {
		return AddedDevice{}, ErrDemoAccount // locked credentials
	}
	if stronger {
		// The email inbox alone must not be able to take over an account that
		// has a passkey or a recovery key; those are how it signs in instead.
		return AddedDevice{}, ErrStrongerSignInRequired
	}
	// Registration lock: with an account password set, the inbox alone can't
	// take over an account that's in use. Once no device has been active for
	// RegistrationLockInactivity, a reset works again, so someone who lost
	// every device and the password still gets back in.
	var locked bool
	if err = tx.QueryRow(ctx, `
		SELECT COALESCE(length(a.account_password_hash), 0) > 0
		   AND EXISTS (SELECT 1 FROM devices d WHERE d.account_id = a.id AND d.last_active_day >= $2)
		  FROM accounts a WHERE a.id = $1`,
		dev.AccountID, unixDay(time.Now().Add(-RegistrationLockInactivity))).Scan(&locked); err != nil {
		return AddedDevice{}, err
	}
	if locked {
		return AddedDevice{}, ErrRegistrationLockActive
	}
	if _, err = tx.Exec(ctx,
		`UPDATE accounts SET account_password_hash = $1,
		        supabase_user_id = CASE WHEN supabase_user_id IS NULL OR supabase_user_id = '' THEN $2 ELSE supabase_user_id END
		 WHERE id = $3`, accountHash, supabaseUserID, dev.AccountID); err != nil {
		return AddedDevice{}, accountInsertError(err)
	}
	if dev.ReplacedDevices, err = replaceDevicesTx(ctx, tx, dev.AccountID); err != nil {
		return AddedDevice{}, err
	}
	if dev.DeviceID, dev.MailboxID, dev.DeviceListVersion, err = addDeviceTx(ctx, tx, dev.AccountID, deviceHash); err != nil {
		return AddedDevice{}, err
	}
	return dev, tx.Commit(ctx)
}

// RegistrationLockInactivity is how long an account with an account password
// must go unused before an email reset can replace its devices.
const RegistrationLockInactivity = 7 * 24 * time.Hour

func unixDay(t time.Time) int64 { return t.Unix() / 86400 }

// TouchDeviceActive records that a device was used today. Callers write at
// most once per device per day.
func (s *Store) TouchDeviceActive(accountID string, deviceID uint32, now time.Time) error {
	day := unixDay(now)
	_, err := s.db.Exec(context.Background(),
		`UPDATE devices SET last_active_day = $3
		  WHERE account_id = $1 AND device_id = $2 AND last_active_day < $3`,
		accountID, int64(deviceID), day)
	return err
}

// SetAccountEmailToken records the keyed token of an account's newly verified
// email. Returns ErrIdentityInUse if another account uses that email, or
// ErrAccountNotFound if the account is gone.
func (s *Store) SetAccountEmailToken(accountID string, emailToken []byte) error {
	tag, err := s.db.Exec(context.Background(),
		`UPDATE accounts SET email_token = $1 WHERE id = $2`, emailToken, accountID)
	if err != nil {
		return accountInsertError(err)
	}
	if tag.RowsAffected() == 0 {
		return ErrAccountNotFound
	}
	return nil
}

// ProvisionOAuthAccount signs a Supabase-authenticated user into their relay
// account, creating it on first use, and provisions a fresh device. The caller
// must have verified the Supabase access token, and must pass a non-nil
// emailToken only when Supabase reports the email as confirmed.
//
// The account is matched by supabase_user_id, then by email token, back-filling
// supabase_user_id. Matching by email is safe because only verified emails are
// stored; an existing link to a different Supabase user is never overwritten.
// If no account exists one is created, which requires requestedUsername
// (ErrUsernameRequired otherwise).
//
// Registration lock: signing in to an existing account replaces all of its
// devices, so if the account has a password, accountPassword must match it:
// ErrAccountPasswordRequired if missing, ErrAccountPasswordIncorrect if wrong.
// lockPermit, if non-nil, is consulted before any comparison and a false
// result gives ErrAccountPasswordLocked. On these errors dev.AccountID is set
// so the caller can key its lockout, and nothing is changed. A supplied
// accountPassword always costs one bcrypt comparison, so timing doesn't reveal
// whether a lock is set.
//
// created reports whether a new account was made.
func (s *Store) ProvisionOAuthAccount(supabaseUserID string, emailToken []byte, requestedUsername, devicePassword string, accountPassword AccountPassword, lockPermit func(accountID string) bool) (dev AddedDevice, created bool, err error) {
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

	// Find an existing account by Supabase user id, then by verified email.
	var lockHash []byte
	var stronger bool // the account has a passkey or a recovery key
	adoptedByEmail := false
	const pick = `SELECT id, username, account_password_hash,
	        recovery_key_hash IS NOT NULL OR EXISTS (SELECT 1 FROM passkeys p WHERE p.account_id = accounts.id)
	   FROM accounts `
	err = tx.QueryRow(ctx, pick+`WHERE supabase_user_id = $1`, supabaseUserID).Scan(&dev.AccountID, &dev.Username, &lockHash, &stronger)
	if errors.Is(err, pgx.ErrNoRows) && len(emailToken) > 0 {
		err = tx.QueryRow(ctx, pick+`WHERE email_token = $1`, emailToken).Scan(&dev.AccountID, &dev.Username, &lockHash, &stronger)
		adoptedByEmail = err == nil
	}

	if err == nil {
		// An account with a passkey or recovery key and no account password
		// can't be taken over with the email inbox alone (an email code, or
		// Apple/Google): it signs in with the passkey or key instead. With an
		// account password, the registration lock below applies.
		if stronger && len(lockHash) == 0 {
			return AddedDevice{AccountID: dev.AccountID}, false, ErrStrongerSignInRequired
		}
		// Registration lock, checked before anything is written.
		if len(lockHash) > 0 {
			locked := AddedDevice{AccountID: dev.AccountID}
			// The client first asks without a password to learn whether one
			// is needed; only real guesses go through the lockout.
			if accountPassword.Empty() {
				return locked, false, ErrAccountPasswordRequired
			}
			if lockPermit != nil && !lockPermit(dev.AccountID) {
				return locked, false, ErrAccountPasswordLocked
			}
			ok, upgraded, e := accountPassword.verify(lockHash)
			if e != nil {
				return locked, false, e
			}
			if !ok {
				return locked, false, ErrAccountPasswordIncorrect
			}
			if upgraded != nil {
				if _, e := tx.Exec(ctx, `UPDATE accounts SET account_password_hash = $1 WHERE id = $2`, upgraded, dev.AccountID); e != nil {
					return AddedDevice{}, false, e
				}
			}
		} else if !accountPassword.Empty() {
			accountPassword.burn()
		}
		if adoptedByEmail {
			// Back-fill only an empty link; never overwrite another Supabase
			// user's link.
			if _, e := tx.Exec(ctx,
				`UPDATE accounts SET supabase_user_id = $1 WHERE id = $2 AND (supabase_user_id IS NULL OR supabase_user_id = '')`,
				supabaseUserID, dev.AccountID); e != nil {
				return AddedDevice{}, false, e
			}
		}
	}

	switch {
	case err == nil:
		// Existing account: replace its devices, then add the new one.
		if dev.ReplacedDevices, err = replaceDevicesTx(ctx, tx, dev.AccountID); err != nil {
			return AddedDevice{}, false, err
		}
		dev.DeviceID, dev.MailboxID, dev.DeviceListVersion, err = addDeviceTx(ctx, tx, dev.AccountID, deviceHash)
		if err != nil {
			return AddedDevice{}, false, err
		}
	case errors.Is(err, pgx.ErrNoRows):
		// No account yet, so create one. A username is required.
		if requestedUsername == "" {
			return AddedDevice{}, false, ErrUsernameRequired
		}
		if taken, e := s.usernameUnavailableTx(ctx, tx, requestedUsername, ""); e != nil {
			return AddedDevice{}, false, e
		} else if taken {
			return AddedDevice{}, false, ErrUsernameTaken
		}
		dev.AccountID = newUUID()
		dev.Username = requestedUsername
		accountHash, err := accountPassword.hash()
		if err != nil {
			return AddedDevice{}, false, err
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
		if err = s.clearReleasedUsernameTx(ctx, tx, dev.Username); err != nil {
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
// account id and username. The row is deleted in the same transaction, so the
// token can't be redeemed twice and no redemption record is kept. Returns
// ErrContactInviteInvalid if the token is unknown, expired, or already used.
func (s *Store) ClaimContactInvite(token string) (accountID, username string, err error) {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return "", "", err
	}
	defer tx.Rollback(ctx)

	var expiresAt, usedAt int64
	err = tx.QueryRow(ctx,
		`DELETE FROM contact_invites WHERE token = $1 RETURNING account_id, expires_at, used_at`, token,
	).Scan(&accountID, &expiresAt, &usedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", ErrContactInviteInvalid
	}
	if err != nil {
		return "", "", err
	}
	if usedAt != 0 || time.Now().UnixMilli() > expiresAt {
		// Expired or already used; the row is deleted either way.
		if err = tx.Commit(ctx); err != nil {
			return "", "", err
		}
		return "", "", ErrContactInviteInvalid
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
// ever handed out, so a removed device's id is never reused. An unset counter
// starts from MAX(device_id). Returns ErrNotFound when the account doesn't
// exist.
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

// CreateProvisioningSession mints a blind mailbox for reversed device linking.
// The new device creates it, shows its id and ephemeral key in a QR code, and
// polls FetchProvisioningBlob; the primary stores the ciphertext via
// StoreProvisioningBlob. It is unauthenticated: the session grants no
// authority until a primary provisions into it.
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
// It is write-once, so a second writer can't substitute the primary's payload
// before the new device fetches it. Returns ErrNotFound if the session is
// unknown, expired, or already provisioned.
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
// stored it, deleting the session. Returns (nil, nil) when no blob is present
// yet, and ErrNotFound when the session is unknown or expired.
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
// against concurrent link/unlink. Returns the assigned device id. It is driven
// by the authenticated primary after scanning the QR code.
func (s *Store) AllocateLinkedDevice(accountID, password string, expectedVersion int64) (deviceID uint32, err error) {
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
		accountID, deviceID, mailboxID, hash, now, nil); err != nil { // device names are never stored
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

// DeviceByID returns the device row without checking a password, for
// signature-based request auth.
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

// RemoveDevice deletes a device from an account.
func (s *Store) RemoveDevice(accountID string, deviceID uint32, expectedVersion int64) (int64, error) {
	// Device 1 has no special protocol role and may be removed too, so a
	// sign-out can always remove itself.
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

	// Lock the device row first so an in-flight Enqueue (which locks it)
	// either commits before the queue is cleared or then finds no device.
	if _, err := tx.Exec(ctx, `SELECT device_id FROM devices WHERE account_id = $1 AND device_id = $2 FOR UPDATE`, accountID, deviceID); err != nil {
		return 0, err
	}
	if err := deleteDeviceTx(ctx, tx, accountID, deviceID); err != nil {
		return 0, err
	}
	newVersion := currentVersion + 1
	if _, err := tx.Exec(ctx, `UPDATE accounts SET device_list_version = $1 WHERE id = $2`, newVersion, accountID); err != nil {
		return 0, err
	}
	return newVersion, tx.Commit(ctx)
}

// deleteDeviceTx deletes a device row with its prekeys and queued envelopes.
// Returns ErrNotFound when the device doesn't exist.
func deleteDeviceTx(ctx context.Context, tx pgx.Tx, accountID string, deviceID uint32) error {
	for _, stmt := range []string{
		`DELETE FROM one_time_prekeys WHERE account_id = $1 AND device_id = $2`,
		`DELETE FROM one_time_kyber_prekeys WHERE account_id = $1 AND device_id = $2`,
		`DELETE FROM signed_prekeys WHERE account_id = $1 AND device_id = $2`,
		`DELETE FROM kyber_prekeys WHERE account_id = $1 AND device_id = $2`,
		`DELETE FROM message_queue WHERE account_id = $1 AND device_id = $2`,
	} {
		if _, err := tx.Exec(ctx, stmt, accountID, deviceID); err != nil {
			return err
		}
	}
	tag, err := tx.Exec(ctx, `DELETE FROM devices WHERE account_id = $1 AND device_id = $2`, accountID, deviceID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// UnfinishedDeviceTTL is how long a linked device may go without publishing an
// identity key before ReapUnfinishedDevices removes it. Device creation times
// are kept only to the day, so the cutoff is a whole day boundary and a
// device is always given at least this long.
const UnfinishedDeviceTTL = 24 * time.Hour

// DeviceRef names one device.
type DeviceRef struct {
	AccountID string
	DeviceID  uint32
}

// ReapUnfinishedDevices removes devices left behind by a link that never
// completed: no identity key at least UnfinishedDeviceTTL after creation,
// on an account that has another device with one. An account whose only
// devices are keyless is left alone, so an interrupted sign-up isn't turned
// into an account with no devices. Each removal bumps device_list_version.
// Returns the removed devices so the caller can notify the account.
func (s *Store) ReapUnfinishedDevices() ([]DeviceRef, error) {
	ctx := context.Background()
	cutoff := coarseDayMillis() - UnfinishedDeviceTTL.Milliseconds()
	rows, err := s.db.Query(ctx, `
		SELECT d.account_id, d.device_id FROM devices d
		WHERE d.identity_key IS NULL AND d.created_at < $1
		  AND EXISTS (SELECT 1 FROM devices o WHERE o.account_id = d.account_id AND o.identity_key IS NOT NULL)`,
		cutoff)
	if err != nil {
		return nil, err
	}
	var candidates []DeviceRef
	for rows.Next() {
		var d DeviceRef
		if err := rows.Scan(&d.AccountID, &d.DeviceID); err != nil {
			rows.Close()
			return nil, err
		}
		candidates = append(candidates, d)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	var reaped []DeviceRef
	for _, d := range candidates {
		ok, err := s.reapUnfinishedDevice(ctx, d)
		if err != nil {
			return reaped, err
		}
		if ok {
			reaped = append(reaped, d)
		}
	}
	return reaped, nil
}

// reapUnfinishedDevice removes one candidate unless it published keys since
// it was selected. Locks the account row, then the device row, as RemoveDevice.
func (s *Store) reapUnfinishedDevice(ctx context.Context, d DeviceRef) (bool, error) {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)
	var version int64
	if err := tx.QueryRow(ctx, `SELECT device_list_version FROM accounts WHERE id = $1 FOR UPDATE`, d.AccountID).Scan(&version); errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	} else if err != nil {
		return false, err
	}
	var one int
	if err := tx.QueryRow(ctx,
		`SELECT 1 FROM devices WHERE account_id = $1 AND device_id = $2 AND identity_key IS NULL FOR UPDATE`,
		d.AccountID, d.DeviceID).Scan(&one); errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	} else if err != nil {
		return false, err
	}
	if err := deleteDeviceTx(ctx, tx, d.AccountID, d.DeviceID); err != nil {
		return false, err
	}
	if _, err := tx.Exec(ctx, `UPDATE accounts SET device_list_version = $1 WHERE id = $2`, version+1, d.AccountID); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}

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

// DeleteAccount removes an account and everything keyed to it in one
// transaction: prekeys, queued envelopes, devices, contact invites, directory
// rows, nuke commands, reports it filed, passkeys, history segment rows, and
// the account row. A linked Supabase user is queued in pending_supabase_deletions.
// The username enters the reuse cooldown for everyone. Reports filed
// against the account are kept. It returns the removed history segments, whose
// blobs the caller deletes. Returns ErrNotFound if the account does not
// exist.
//
// Data with no stored account linkage is left to expire on its own:
// provisioning sessions, group invites, attachment blobs, and envelopes the
// account sent to others.
func (s *Store) DeleteAccount(accountID string) ([]HistorySegment, error) {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	// Lock the account row so concurrent device-list changes and history
	// writes serialize behind the delete.
	var username string
	if err := tx.QueryRow(ctx, `SELECT username FROM accounts WHERE id = $1 FOR UPDATE`, accountID).Scan(&username); errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	} else if err != nil {
		return nil, err
	}
	if err := s.releaseUsernameTx(ctx, tx, username, ""); err != nil {
		return nil, err
	}
	// Queue the linked Supabase user for deletion in the same transaction, so
	// a failed or interrupted admin-API call is retried rather than lost.
	if _, err := tx.Exec(ctx, `
		INSERT INTO pending_supabase_deletions (user_id, created_at)
		SELECT supabase_user_id, $2 FROM accounts WHERE id = $1 AND COALESCE(supabase_user_id, '') <> ''
		ON CONFLICT (user_id) DO NOTHING`, accountID, coarseDayMillis()); err != nil {
		return nil, err
	}
	history, err := deleteHistoryTx(ctx, tx, accountID)
	if err != nil {
		return nil, err
	}
	for _, stmt := range []string{
		// Lock the device rows (see Enqueue) so no envelope lands after the
		// queue is cleared.
		`SELECT device_id FROM devices WHERE account_id = $1 FOR UPDATE`,
		`DELETE FROM one_time_prekeys WHERE account_id = $1`,
		`DELETE FROM one_time_kyber_prekeys WHERE account_id = $1`,
		`DELETE FROM signed_prekeys WHERE account_id = $1`,
		`DELETE FROM kyber_prekeys WHERE account_id = $1`,
		`DELETE FROM message_queue WHERE account_id = $1`,
		`DELETE FROM devices WHERE account_id = $1`,
		`DELETE FROM contact_invites WHERE account_id = $1`,
		`DELETE FROM directory WHERE account_id = $1`,
		`DELETE FROM nuke_commands WHERE account_id = $1`,
		`DELETE FROM reports WHERE reporter_account = $1`,
		`DELETE FROM account_storage WHERE account_id = $1`,
		`DELETE FROM passkeys WHERE account_id = $1`,
		`DELETE FROM accounts WHERE id = $1`,
	} {
		if _, err := tx.Exec(ctx, stmt, accountID); err != nil {
			return nil, err
		}
	}
	return history, tx.Commit(ctx)
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
// if another account holds the name, compared case-insensitively, or it is in
// another account's reuse cooldown. The old name enters the reuse cooldown.
// Returns ErrNotFound for an unknown account.
func (s *Store) UpdateUsername(accountID, newUsername string) error {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var oldUsername string
	if err := tx.QueryRow(ctx, `SELECT username FROM accounts WHERE id = $1 FOR UPDATE`, accountID).Scan(&oldUsername); errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	} else if err != nil {
		return err
	}
	if taken, err := s.usernameUnavailableTx(ctx, tx, newUsername, accountID); err != nil {
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
	if !strings.EqualFold(oldUsername, newUsername) {
		if err := s.releaseUsernameTx(ctx, tx, oldUsername, accountID); err != nil {
			return err
		}
		if err := s.clearReleasedUsernameTx(ctx, tx, newUsername); err != nil {
			return err
		}
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

// KeyedDeviceIDs returns the ids of an account's devices that have published
// an identity key. A device from an unfinished link has none and can't be
// sent to, so senders aren't told it is missing.
func (s *Store) KeyedDeviceIDs(accountID string) ([]uint32, error) {
	rows, err := s.db.Query(context.Background(),
		`SELECT device_id FROM devices WHERE account_id = $1 AND identity_key IS NOT NULL ORDER BY device_id`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []uint32
	for rows.Next() {
		var id uint32
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
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

// SealedTargetByMailbox resolves a mailbox id to its device and the owning
// account's sealed-sender access key in one query, so the unauthenticated path
// does the same database work whether or not the mailbox exists. accessKey is
// nil when the account has none set.
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
// Mailbox ids change only on explicit client request. Peers pick up the new id
// on their next bundle fetch; sealed sends to the old id fail and are retried.
// The queue is keyed by (account, device), so queued deliveries are unaffected.
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
// provider reported it permanently invalid. It only clears the token if it
// still equals token, so a newer registration is never wiped.
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

// PushTarget returns a device's push kind ("apns" or "fcm") and matching
// token. token is "" when the device has registered none.
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
// envelope in its APNs payload instead of a content-free wake.
func (s *Store) SetPushIncludeContent(accountID string, deviceID uint32, include bool) error {
	ctx := context.Background()
	_, err := s.db.Exec(ctx, `UPDATE devices SET push_include_content = $1 WHERE account_id = $2 AND device_id = $3`,
		include, accountID, deviceID)
	return err
}

// PushIncludeContent reports whether this device opted in to ciphertext in
// push. It is false for unknown devices.
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
// authorization key.
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
// Prekey rows carry no upload time (created_at = 0) so the table isn't a
// per-device last-active log.
func (s *Store) SetKeys(accountID string, deviceID uint32, registrationID uint32, identityKey []byte, spk SignedPreKey, kyber SignedPreKey, oneTime []OneTimePreKey, replaceOneTime bool) error {
	return s.SetKeysWithKyberPool(accountID, deviceID, registrationID, identityKey, spk, kyber, oneTime, nil, replaceOneTime)
}

// SetKeysWithKyberPool is SetKeys plus one-time Kyber prekeys, appended to (or,
// with replaceOneTime, replacing) the device's one-time Kyber pool.
func (s *Store) SetKeysWithKyberPool(accountID string, deviceID uint32, registrationID uint32, identityKey []byte, spk SignedPreKey, kyber SignedPreKey, oneTime []OneTimePreKey, oneTimeKyber []SignedPreKey, replaceOneTime bool) error {
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
	// A client with a fresh or desynced key store replaces its whole pool so
	// the relay never hands out a key whose private half is gone.
	if replaceOneTime {
		if _, err := tx.Exec(ctx, `DELETE FROM one_time_prekeys WHERE account_id = $1 AND device_id = $2`,
			accountID, deviceID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM one_time_kyber_prekeys WHERE account_id = $1 AND device_id = $2`,
			accountID, deviceID); err != nil {
			return err
		}
	}
	for _, k := range oneTimeKyber {
		if _, err := tx.Exec(ctx, `
			INSERT INTO one_time_kyber_prekeys (account_id, device_id, key_id, public_key, signature)
			VALUES ($1, $2, $3, $4, $5)
			ON CONFLICT (account_id, device_id, key_id) DO UPDATE SET public_key = EXCLUDED.public_key, signature = EXCLUDED.signature`,
			accountID, deviceID, int64(k.KeyID), k.PublicKey, k.Signature); err != nil {
			return err
		}
	}
	if len(oneTimeKyber) > 0 {
		var n int
		if err := tx.QueryRow(ctx, `SELECT COUNT(*) FROM one_time_kyber_prekeys WHERE account_id = $1 AND device_id = $2`,
			accountID, deviceID).Scan(&n); err != nil {
			return err
		}
		if n > MaxOneTimeKyberPreKeysPerDevice {
			return ErrPreKeyPoolFull
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
	// Counted after the upserts so re-uploaded ids don't count twice. The
	// UPDATE above holds the device row lock, so concurrent uploads serialize.
	if len(oneTime) > 0 {
		var n int
		if err := tx.QueryRow(ctx, `SELECT COUNT(*) FROM one_time_prekeys WHERE account_id = $1 AND device_id = $2`,
			accountID, deviceID).Scan(&n); err != nil {
			return err
		}
		if n > MaxOneTimePreKeysPerDevice {
			return ErrPreKeyPoolFull // rolls back the whole upload
		}
	}
	return tx.Commit(ctx)
}

// OneTimeKyberPreKeyCount reports how many unconsumed one-time Kyber prekeys a device has.
func (s *Store) OneTimeKyberPreKeyCount(accountID string, deviceID uint32) (int, error) {
	var n int
	err := s.db.QueryRow(context.Background(),
		`SELECT COUNT(*) FROM one_time_kyber_prekeys WHERE account_id = $1 AND device_id = $2`,
		accountID, deviceID).Scan(&n)
	return n, err
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
// one-time prekey per bundle when available. allowOneTime, if non-nil, is
// asked only when the device has a one-time prekey to hand out; if it returns
// false the bundle is served without one and the pool is left untouched.
func (s *Store) TakePreKeyBundles(accountID string, deviceIDs []uint32, allowOneTime func(deviceID uint32) bool) ([]PreKeyBundle, error) {
	ctx := context.Background()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	// When fetching every device, skip ones that never published keys (such as
	// an unfinished link) instead of failing the whole account.
	allDevices := deviceIDs == nil
	if allDevices {
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
			if allDevices {
				continue
			}
			return nil, ErrNotFound
		}
		if err != nil {
			return nil, err
		}

		// One budget decision per device covers both one-time pools.
		decided, allowed := false, false
		mayUseOneTime := func() bool {
			if !decided {
				decided = true
				allowed = allowOneTime == nil || allowOneTime(devID)
			}
			return allowed
		}

		// FOR UPDATE SKIP LOCKED: concurrent fetchers must never be handed the
		// same one-time key (the second session would fail to decrypt).
		var otk OneTimePreKey
		err = tx.QueryRow(ctx, `
			SELECT key_id, public_key FROM one_time_prekeys
			WHERE account_id = $1 AND device_id = $2
			ORDER BY key_id LIMIT 1 FOR UPDATE SKIP LOCKED`,
			accountID, devID).Scan(&otk.KeyID, &otk.PublicKey)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			// Pool exhausted; the bundle is still valid.
		case err != nil:
			return nil, err
		case !mayUseOneTime():
			// Hand-out budget spent: serve the bundle without a one-time key.
		default:
			if _, err := tx.Exec(ctx, `DELETE FROM one_time_prekeys WHERE account_id = $1 AND device_id = $2 AND key_id = $3`,
				accountID, devID, otk.KeyID); err != nil {
				return nil, err
			}
			b.OneTime = &otk
		}

		// A one-time Kyber prekey replaces the last-resort one when available.
		var kyberID int64
		var kyberKey SignedPreKey
		err = tx.QueryRow(ctx, `
			SELECT key_id, public_key, signature FROM one_time_kyber_prekeys
			WHERE account_id = $1 AND device_id = $2
			ORDER BY key_id LIMIT 1 FOR UPDATE SKIP LOCKED`,
			accountID, devID).Scan(&kyberID, &kyberKey.PublicKey, &kyberKey.Signature)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
		case err != nil:
			return nil, err
		case !mayUseOneTime():
		default:
			if _, err := tx.Exec(ctx, `DELETE FROM one_time_kyber_prekeys WHERE account_id = $1 AND device_id = $2 AND key_id = $3`,
				accountID, devID, kyberID); err != nil {
				return nil, err
			}
			kyberKey.KeyID = uint32(kyberID)
			b.KyberPreKey = kyberKey
		}
		bundles = append(bundles, b)
	}
	if len(bundles) == 0 {
		return nil, ErrNotFound
	}
	return bundles, tx.Commit(ctx)
}

// ---------------------------------------------------------------------------
// Offline message queue
// ---------------------------------------------------------------------------

// Enqueue stores a serialized envelope for a device until it is acked. A device
// may hold at most maxQueuedPerDevice envelopes and maxQueuedBytesPerDevice
// bytes of queued ciphertext; beyond either, ErrQueueFull. Expired rows are
// reaped by PurgeExpired.
//
// The device row is locked for the count-then-insert, so concurrent senders
// to one device can't jointly overshoot the cap. A device that no longer
// exists, possibly removed while waiting on the lock, gets ErrNotFound.
func (s *Store) Enqueue(envelopeID, accountID string, deviceID uint32, envelope []byte) error {
	return s.enqueue(envelopeID, accountID, deviceID, envelope, maxQueuedPerDevice)
}

// EnqueueBestEffort queues a silent envelope (a receipt): only while the
// device's queue is under half full, so receipts piling up for an offline
// device can never take the room real messages need. ErrQueueFull otherwise;
// the caller drops it.
func (s *Store) EnqueueBestEffort(envelopeID, accountID string, deviceID uint32, envelope []byte) error {
	return s.enqueue(envelopeID, accountID, deviceID, envelope, maxQueuedPerDevice/2)
}

func (s *Store) enqueue(envelopeID, accountID string, deviceID uint32, envelope []byte, countCap int) error {
	ctx := context.Background()
	if len(envelope) > maxQueuedEnvelopeBytes {
		return ErrEnvelopeTooLarge
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var one int
	if err := tx.QueryRow(ctx,
		`SELECT 1 FROM devices WHERE account_id = $1 AND device_id = $2 FOR UPDATE`,
		accountID, deviceID).Scan(&one); errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	} else if err != nil {
		return err
	}
	var queued int
	var queuedBytes int64
	if err := tx.QueryRow(ctx,
		`SELECT COUNT(*), COALESCE(SUM(octet_length(envelope)), 0) FROM message_queue WHERE account_id = $1 AND device_id = $2`,
		accountID, deviceID).Scan(&queued, &queuedBytes); err != nil {
		return err
	}
	if queued >= countCap || queuedBytes+int64(len(envelope)) > maxQueuedBytesPerDevice {
		return ErrQueueFull
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO message_queue (envelope_id, account_id, device_id, envelope, created_at)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (envelope_id, account_id, device_id) DO NOTHING`,
		envelopeID, accountID, deviceID, envelope, time.Now().UnixMilli()); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// QueuedEnvelope is one row of a device's offline queue.
type QueuedEnvelope struct {
	ID        string
	CreatedAt int64
	Envelope  []byte // serialized relay.v1.Envelope
}

// QueueCursor positions a queue read strictly after a given envelope, in
// (created_at, envelope_id) order. The zero value starts at the oldest.
type QueueCursor struct {
	CreatedAt  int64
	EnvelopeID string
}

// QueuedEnvelopesPage returns up to limit of a device's pending envelopes after
// cursor, oldest first, stopping early once the page holds maxBytes of
// ciphertext; a page always has at least one envelope when any remain. more
// reports whether further envelopes exist; resume with the cursor of the last
// element. Rows are streamed, so memory is bounded by the page size.
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
			return page, true, nil // deferred rows.Close discards the rest
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

// PurgeExpired deletes every row that has outlived its retention window.
// relayd runs it hourly:
//
//   - message_queue: envelopes older than 14 days
//   - encrypted_group_invites, provisioning_sessions: expired
//   - contact_invites: expired or already used (single-use)
//   - reports: older than 180 days
//   - nuke_commands: older than an hour (delivered or stale; see nukeRetentionMillis)
//   - released_usernames: once the 7-day reuse cooldown has ended
func (s *Store) PurgeExpired() error {
	ctx := context.Background()
	now := time.Now().UnixMilli()
	for _, q := range []struct {
		sql string
		arg int64
	}{
		{`DELETE FROM message_queue WHERE created_at < $1`, now - queueTTLMillis},
		{`DELETE FROM account_notices WHERE created_at < $1`, now - accountNoticeRetentionDay*24*60*60*1000},
		{`DELETE FROM encrypted_group_invites WHERE expires_at < $1`, now},
		{`DELETE FROM provisioning_sessions WHERE expires_at < $1`, now},
		{`DELETE FROM contact_invites WHERE expires_at < $1 OR used_at <> 0`, now},
		{`DELETE FROM reports WHERE created_at < $1`, now - reportTTLMillis},
		{`DELETE FROM nuke_commands WHERE created_at < $1`, now - nukeRetentionMillis},
		{`DELETE FROM released_usernames WHERE released_at < $1`, now - UsernameReuseCooldown.Milliseconds()},
	} {
		if _, err := s.db.Exec(ctx, q.sql, q.arg); err != nil {
			return err
		}
	}
	return nil
}

const groupInviteTTL = 7 * 24 * time.Hour

// CreateEncryptedGroupInvite stores an opaque encrypted invite blob under a
// fresh token with a 7-day expiry and returns both. The relay never learns
// what the blob decrypts to.
func (s *Store) CreateEncryptedGroupInvite(blob []byte) (token string, expiresAt int64, err error) {
	token = newUUID()
	expiresAt = time.Now().Add(groupInviteTTL).UnixMilli()
	_, err = s.db.Exec(context.Background(),
		`INSERT INTO encrypted_group_invites (token, blob, expires_at) VALUES ($1, $2, $3)`,
		token, blob, expiresAt)
	return token, expiresAt, err
}

// ClaimEncryptedGroupInvite returns the invite blob for an unexpired token.
// Tokens are reusable until they expire.
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

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

// ---------------------------------------------------------------------------
// Nuke (remote wipe)
// ---------------------------------------------------------------------------

// NukeRecord holds the fields of a signed remote-wipe command, so the store
// doesn't import relaypb.
type NukeRecord struct {
	AccountID          string
	CommandID          string
	CreationTimeMs     int64
	InitiatingDeviceID uint32
	Signature          []byte
}

// StoreNuke persists a signed nuke command and deletes all queued envelopes
// for the account in the same transaction. Returns ErrDuplicateNukeCommand if
// the command id was already used.
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
	if _, err := tx.Exec(ctx,
		`DELETE FROM message_queue WHERE account_id = $1`, rec.AccountID,
	); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// PendingNukeForAccount returns the most recent stored nuke for an account, or
// nil if none exists, for delivery to a device that was offline when it was
// issued.
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
// present it on the unauthenticated delivery path. Rotating it revokes anyone
// holding the old key.
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
	DirectoryKindPhone    int16 = 2
)

// DirectoryEntry is one row of the blinded directory: an OPRF token, its
// account, and the precomputed bucket, match tag and sealed boxes.
type DirectoryEntry struct {
	Token     []byte
	AccountID string
	Kind      int16
	Bucket    uint16
	Tag       []byte
	Box       []byte
	AccessBox []byte // nil when the account has no access key
}

// BucketEntry is one row of a directory bucket as served to clients.
type BucketEntry struct {
	Bucket    uint16
	Tag       []byte
	Box       []byte
	AccessBox []byte
}

// AccountDirInfo is the identifier material needed to build an account's
// directory tokens. The email is available only as its keyed token.
type AccountDirInfo struct {
	AccountID  string
	Username   string
	EmailToken []byte
	// EmailDiscoverable is the owner's opt-in for an email directory entry.
	EmailDiscoverable bool
	AccessKey         []byte
	// PhoneToken is the verified phone number's OPRF token, if any;
	// PhoneDiscoverable whether it gets a directory entry.
	PhoneToken        []byte
	PhoneDiscoverable bool
}

// AllAccountsForDirectory returns every account's directory material for the
// startup rebuild.
func (s *Store) AllAccountsForDirectory() ([]AccountDirInfo, error) {
	rows, err := s.db.Query(context.Background(),
		`SELECT id, COALESCE(username, ''), email_token, email_discoverable, access_key, phone_token, phone_discoverable FROM accounts ORDER BY created_at, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AccountDirInfo
	for rows.Next() {
		var a AccountDirInfo
		if err := rows.Scan(&a.AccountID, &a.Username, &a.EmailToken, &a.EmailDiscoverable, &a.AccessKey, &a.PhoneToken, &a.PhoneDiscoverable); err != nil {
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
		`SELECT id, COALESCE(username, ''), email_token, email_discoverable, access_key, phone_token, phone_discoverable FROM accounts WHERE id = $1`,
		accountID,
	).Scan(&a.AccountID, &a.Username, &a.EmailToken, &a.EmailDiscoverable, &a.AccessKey, &a.PhoneToken, &a.PhoneDiscoverable)
	if errors.Is(err, pgx.ErrNoRows) {
		return a, ErrAccountNotFound
	}
	return a, err
}

// SetEmailDiscoverable records whether the account's verified email may be
// found through blinded discovery. The caller reindexes the account.
func (s *Store) SetEmailDiscoverable(accountID string, discoverable bool) error {
	tag, err := s.db.Exec(context.Background(),
		`UPDATE accounts SET email_discoverable = $1 WHERE id = $2`, discoverable, accountID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrAccountNotFound
	}
	return nil
}

// ReplaceDirectory rebuilds the entire directory index.
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

// upsertDirectoryEntry inserts one directory row. A token owned by a different
// account is never reassigned (the collision is logged); otherwise a colliding
// identifier such as a case variant could hijack another user's entry.
func upsertDirectoryEntry(ctx context.Context, tx pgx.Tx, e DirectoryEntry) error {
	tag, err := tx.Exec(ctx,
		`INSERT INTO directory (token, account_id, kind, bucket, tag, box, access_box) VALUES ($1, $2, $3, $4, $5, $6, $7)
         ON CONFLICT (token) DO UPDATE SET kind = EXCLUDED.kind, bucket = EXCLUDED.bucket, tag = EXCLUDED.tag, box = EXCLUDED.box, access_box = EXCLUDED.access_box
         WHERE directory.account_id = EXCLUDED.account_id`,
		e.Token, e.AccountID, e.Kind, int32(e.Bucket), e.Tag, e.Box, e.AccessBox)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		slog.Warn("store: directory token already owned by another account; not reassigned", "kind", e.Kind)
	}
	return nil
}

// SetDirectoryForAccount replaces one account's directory rows.
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

// DirectoryBuckets returns the tag and sealed boxes of every directory row in
// the requested buckets, never the token or account id.
func (s *Store) DirectoryBuckets(buckets []uint16) ([]BucketEntry, error) {
	if len(buckets) == 0 {
		return nil, nil
	}
	ids := make([]int32, len(buckets))
	for i, b := range buckets {
		ids[i] = int32(b)
	}
	rows, err := s.db.Query(context.Background(),
		`SELECT bucket, tag, box, access_box FROM directory
         WHERE bucket = ANY($1) AND tag IS NOT NULL AND box IS NOT NULL`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []BucketEntry
	for rows.Next() {
		var e BucketEntry
		var b int32
		if err := rows.Scan(&b, &e.Tag, &e.Box, &e.AccessBox); err != nil {
			return nil, err
		}
		e.Bucket = uint16(b)
		out = append(out, e)
	}
	return out, rows.Err()
}

// IdentityKey returns a device's identity public key (libsignal-serialized, 33
// bytes), or ErrNotFound if there is none. Sealed-sender certificates bind the
// account to it.
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

// DeleteNukesForAccount removes all pending nuke commands for an account. A
// nuke past the delivery window would be rejected by the client and otherwise
// redelivered on every reconnect.
func (s *Store) DeleteNukesForAccount(accountID string) error {
	_, err := s.db.Exec(context.Background(),
		`DELETE FROM nuke_commands WHERE account_id = $1`, accountID)
	return err
}
