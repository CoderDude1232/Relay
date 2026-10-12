// Package api exposes the relay over HTTP: a JSON REST control plane
// (accounts, devices, prekeys) and a protobuf-framed WebSocket for
// real-time envelope delivery.
package api

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/relayapp/relay-server/gen/relaypb"
	"github.com/relayapp/relay-server/internal/blob"
	"github.com/relayapp/relay-server/internal/hub"
	"github.com/relayapp/relay-server/internal/limitkey"
	"github.com/relayapp/relay-server/internal/oprf"
	"github.com/relayapp/relay-server/internal/privlog"
	"github.com/relayapp/relay-server/internal/sealedsender"
	"github.com/relayapp/relay-server/internal/store"
)

type Server struct {
	store        *store.Store
	hub          *hub.Hub
	blobs        *blob.Store
	turnURLs     []string // empty = TURN not configured
	turnSecret   string
	demoCodeHash []byte          // sha256 of the review code; nil = demo sign-in off
	turnHealth   *TURNHealth     // nil = no failover
	cfTURN       *CloudflareTURN // nil = no failover

	// Supabase social login. When supabaseURL is set, access tokens are
	// verified server-to-server via GET /auth/v1/user and the returned
	// id/email are trusted. verifySupabaseToken is a field so tests can stub it.
	supabaseURL     string
	supabaseAnonKey string
	// supabaseServiceKey is the optional service-role key used to delete the
	// user's Supabase auth record (which holds their email) on account deletion.
	supabaseServiceKey  string
	verifySupabaseToken func(ctx context.Context, accessToken string) (supabaseUser, error)

	// sealed, when set, enables GET /v1/certificate/delivery.
	sealed *sealedIssuer

	// oprf, when set, enables blinded discovery; the directory index is built
	// under this key.
	oprf *oprf.Key

	// Per-account attachment budgets: count/day at allocation, bytes/day at
	// upload.
	attachQuota *attachmentQuota

	// attachDiskCap is the global attachment disk watermark: once the blob
	// directory holds this many bytes, allocations and uploads get 507 until
	// GC frees space. 0 means unlimited.
	attachDiskCap int64
	// attachInFlight is the bytes reserved by uploads still in progress.
	attachInFlight attachmentInFlight

	// appleRevoker, if non-nil, revokes the user's Sign in with Apple grant on
	// account deletion.
	appleRevoker AppleRevoker

	// Passkeys (passkeys.go). webauthn is nil until SetPasskeyRP succeeds.
	webauthn           *webauthn.WebAuthn
	passkeyReg         *passkeySessions // keyed by account id
	passkeyLogin       *passkeySessions // keyed by random session id
	passkeySignup      *passkeySessions // keyed by random session id
	passkeyEmailRemove *passkeySessions // keyed by account id
}

// AppleRevoker exchanges a Sign in with Apple authorization code for the
// user's tokens and revokes them (implemented by siwa.Revoker).
type AppleRevoker interface {
	RevokeAuthorizationCode(ctx context.Context, code string) error
}

// SetAppleRevoker enables Sign in with Apple token revocation on account
// deletion.
func (s *Server) SetAppleRevoker(r AppleRevoker) { s.appleRevoker = r }

// appleRevokeTimeout bounds the code exchange and revoke on account deletion.
const appleRevokeTimeout = 10 * time.Second

// DefaultAttachmentDiskCap is the default global attachment disk watermark.
const DefaultAttachmentDiskCap = 20 << 30 // 20 GiB

// SetAttachmentDiskCap sets the global attachment disk watermark in bytes
// (0 disables it).
func (s *Server) SetAttachmentDiskCap(bytes int64) { s.attachDiskCap = bytes }

// attachmentDiskFull reports whether the blob directory is at its watermark.
func (s *Server) attachmentDiskFull() bool {
	return s.attachDiskCap > 0 && s.blobs.Usage()+s.attachInFlight.load() >= s.attachDiskCap
}

// sealedIssuer holds the server certificate (signed by the trust root) and its
// private key, used to mint per-device sender certificates.
type sealedIssuer struct {
	serverCert    []byte
	serverCertKey []byte
}

func New(st *store.Store, h *hub.Hub, blobs *blob.Store, turnURLs, turnSecret string) *Server {
	var urls []string
	for _, u := range strings.Split(turnURLs, ",") {
		if u = strings.TrimSpace(u); u != "" {
			urls = append(urls, u)
		}
	}
	s := &Server{store: st, hub: h, blobs: blobs, turnURLs: urls, turnSecret: turnSecret,
		attachQuota:   newAttachmentQuota(defaultAttachmentDailyBytes, defaultAttachmentDailyCount),
		attachDiskCap: DefaultAttachmentDiskCap,
		passkeyReg:    newPasskeySessions(), passkeyLogin: newPasskeySessions(),
		passkeySignup: newPasskeySessions(), passkeyEmailRemove: newPasskeySessions()}
	s.verifySupabaseToken = s.verifySupabaseTokenHTTP
	if err := s.SetPasskeyRP(DefaultPasskeyRPID, []string{DefaultPasskeyOrigin}); err != nil {
		panic("api: default passkey config: " + err.Error())
	}
	return s
}

// SetAttachmentQuota sets the per-account daily attachment upload budgets:
// total ciphertext bytes and number of allocations per rolling day.
func (s *Server) SetAttachmentQuota(dailyBytes int64, dailyCount int) {
	s.attachQuota = newAttachmentQuota(dailyBytes, dailyCount)
}

// SetSupabaseServiceKey enables deleting the Supabase auth user when its
// relay account is deleted. Requires SetSupabaseAuth for the project URL.
func (s *Server) SetSupabaseServiceKey(key string) {
	s.supabaseServiceKey = strings.TrimSpace(key)
}

// deleteSupabaseUser removes a Supabase auth user via the admin API. Account
// deletion treats it as best effort (the relay account is already gone, so a
// failure is only logged); email removal fails the request instead. Without a
// service key configured (development) it does nothing and returns nil.
func (s *Server) deleteSupabaseUser(ctx context.Context, userID string) error {
	if s.supabaseURL == "" || s.supabaseServiceKey == "" || userID == "" {
		return nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete,
		s.supabaseURL+"/auth/v1/admin/users/"+url.PathEscape(userID), nil)
	if err != nil {
		slog.Error("supabase user delete: request", "err", privlog.Error(err))
		return err
	}
	req.Header.Set("apikey", s.supabaseServiceKey)
	req.Header.Set("Authorization", "Bearer "+s.supabaseServiceKey)
	resp, err := supabaseHTTPClient.Do(req)
	if err != nil {
		slog.Error("supabase user delete failed", "err", privlog.Error(err))
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusNotFound {
		slog.Error("supabase user delete failed", "status", resp.StatusCode)
		return fmt.Errorf("supabase user delete: HTTP %d", resp.StatusCode)
	}
	return nil
}

// SetSupabaseAuth enables social login against a Supabase project. projectURL
// is the base URL (e.g. https://xxxx.supabase.co); anonKey is sent as the
// apikey header on GoTrue calls.
func (s *Server) SetSupabaseAuth(projectURL, anonKey string) {
	s.supabaseURL = strings.TrimRight(projectURL, "/")
	s.supabaseAnonKey = anonKey
}

// SetSealedSender enables sealed-sender certificate issuance. It generates a
// server certificate signed by the given trust root; clients embed the trust
// root's public key to validate the certs issued by GET /v1/certificate/delivery.
func (s *Server) SetSealedSender(trustRoot sealedsender.KeyPair) error {
	serverKey, err := sealedsender.GenerateKeyPair()
	if err != nil {
		return err
	}
	serverCert, err := sealedsender.MintServerCertificate(trustRoot.Private, 1, serverKey.Public)
	if err != nil {
		return err
	}
	s.sealed = &sealedIssuer{serverCert: serverCert, serverCertKey: serverKey.Private}
	return nil
}

// SetOPRF enables blinded discovery under key and rebuilds the directory index
// from the current accounts, correcting any drift on restart. It also enables
// the username reuse cooldown (see store.UsernameReuseCooldown).
func (s *Server) SetOPRF(key *oprf.Key) error {
	s.oprf = key
	// The username reuse cooldown keys its hashes from the OPRF key, so they
	// stay matchable across restarts without another secret to manage.
	s.store.SetUsernameReleaseKey(key.DeriveKey("released-username"))
	accounts, err := s.store.AllAccountsForDirectory()
	if err != nil {
		return err
	}
	entries := make([]store.DirectoryEntry, 0, len(accounts))
	for _, a := range accounts {
		entries = append(entries, s.directoryEntries(a)...)
	}
	return s.store.ReplaceDirectory(entries)
}

// directoryEntries computes the OPRF token rows for an account's username and
// email. Each row carries its bucket, match tag and a box sealing (accountId,
// username) under a key derived from the token, so a bucket fetch is a plain
// read and only a client that already holds the token can open its entry.
func (s *Server) directoryEntries(a store.AccountDirInfo) []store.DirectoryEntry {
	var entries []store.DirectoryEntry
	add := func(token []byte, kind int16) {
		box, err := oprf.SealDirectoryEntry(token, a.AccountID, a.Username)
		if err != nil {
			slog.Error("directory: seal entry failed", "err", privlog.Error(err))
			return
		}
		var accessBox []byte
		if len(a.AccessKey) == 32 {
			if accessBox, err = oprf.SealDirectoryAccessKey(token, a.AccessKey); err != nil {
				slog.Error("directory: seal access key failed", "err", privlog.Error(err))
				accessBox = nil
			}
		}
		entries = append(entries, store.DirectoryEntry{
			Token: token, AccountID: a.AccountID, Kind: kind,
			Bucket: oprf.DirectoryBucket(token), Tag: oprf.DirectoryTag(token), Box: box,
			AccessBox: accessBox,
		})
	}
	if a.Username != "" {
		add(s.oprf.Token(a.Username), store.DirectoryKindUsername)
	}
	// Email discovery is opt-in (PUT /v1/accounts/me/discoverability).
	if len(a.EmailToken) > 0 && a.EmailDiscoverable {
		add(a.EmailToken, store.DirectoryKindEmail)
	}
	return entries
}

// emailToken derives the OPRF-keyed token stored in place of a plaintext
// email. It returns nil when there is no email or OPRF isn't configured, so
// email features degrade rather than store anything sensitive.
func (s *Server) emailToken(email string) []byte {
	if email == "" || s.oprf == nil {
		return nil
	}
	return s.oprf.Token(email)
}

// reindexAccount refreshes one account's directory rows after its username/email
// changes. Best-effort: discovery lag is preferable to failing the mutation.
func (s *Server) reindexAccount(accountID string) {
	if s.oprf == nil {
		return
	}
	info, err := s.store.AccountForDirectory(accountID)
	if err != nil {
		slog.Error("directory reindex: lookup failed", "err", privlog.Error(err))
		return
	}
	if err := s.store.SetDirectoryForAccount(accountID, s.directoryEntries(info)); err != nil {
		slog.Error("directory reindex: write failed", "err", privlog.Error(err))
	}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/accounts", s.handleCreateAccount)
	mux.HandleFunc("POST /v1/accounts/oauth", s.handleOAuthAccount)
	mux.HandleFunc("POST /v1/accounts/recover", s.handleRecoverAccount)
	mux.HandleFunc("POST /v1/accounts/demo-signin", s.handleDemoSignIn) // unauthenticated; review code
	mux.HandleFunc("GET /v1/accounts/me/demo", s.auth(s.handleDemoStatus))
	mux.HandleFunc("GET /v1/accounts/me/storage", s.auth(s.handleGetAccountStorage))
	mux.HandleFunc("PUT /v1/accounts/me/storage", s.auth(s.handlePutAccountStorage))
	mux.HandleFunc("GET /v1/certificate/delivery", s.auth(s.handleDeliveryCertificate))
	mux.HandleFunc("PUT /v1/accounts/me/access-key", s.auth(s.handleSetAccessKey))
	mux.HandleFunc("POST /v1/devices/me/mailbox/rotate", s.auth(s.handleRotateMailbox))
	mux.HandleFunc("POST /v1/directory/oprf", s.auth(s.handleDirectoryOPRF))
	mux.HandleFunc("POST /v1/directory/buckets", s.auth(s.handleDirectoryBuckets))
	mux.HandleFunc("POST /v1/messages/sealed", s.handleSealedSend) // unauthenticated by design
	mux.HandleFunc("GET /v1/queue", s.auth(s.handleFetchQueue))
	mux.HandleFunc("POST /v1/messages/ack", s.auth(s.handleAckMessage))
	mux.HandleFunc("POST /v1/contact-invites", s.auth(s.handleCreateContactInvite))
	mux.HandleFunc("POST /v1/contact-invites/claim", s.handleClaimContactInvite) // unauthenticated: token is the capability
	mux.HandleFunc("POST /v1/devices", s.auth(s.handleAddDevice))
	mux.HandleFunc("POST /v1/devices/link-invitations", s.auth(s.handleCreateDeviceLinkInvitation))
	mux.HandleFunc("POST /v1/devices/link-claims", s.handleClaimDeviceLink)
	// Reversed device linking: the new device creates a provisioning session and
	// shows a QR; the primary scans it, creates the device, and stores an
	// encrypted payload the new device polls for. The path is not under
	// /v1/devices/ because ServeMux rejects the {id} wildcard there as ambiguous
	// with GET /v1/devices/{id}/auth-key.
	mux.HandleFunc("POST /v1/provisioning-sessions", s.handleCreateProvisioningSession)     // unauthenticated (new device)
	mux.HandleFunc("GET /v1/provisioning-sessions/{id}", s.handleFetchProvisioning)         // unauthenticated (new device polls)
	mux.HandleFunc("PUT /v1/provisioning-sessions/{id}", s.auth(s.handleStoreProvisioning)) // primary stores ciphertext
	mux.HandleFunc("POST /v1/devices/link", s.auth(s.handleLinkDevice))                     // primary creates the device
	mux.HandleFunc("GET /v1/devices", s.auth(s.handleListDevices))
	mux.HandleFunc("DELETE /v1/devices/{id}", s.auth(s.handleRemoveDevice))
	mux.HandleFunc("PUT /v1/devices/auth-key", s.bootstrapAuth(s.handleSetDeviceAuthKey)) // the only route accepting HTTP Basic
	mux.HandleFunc("PUT /v1/devices/apns", s.auth(s.handleSetAPNSToken))
	mux.HandleFunc("PUT /v1/devices/fcm", s.auth(s.handleSetFCMToken))
	mux.HandleFunc("PUT /v1/devices/voip", s.auth(s.handleSetVoIPToken))
	mux.HandleFunc("PUT /v1/devices/me/push-content", s.auth(s.handleSetPushContent))
	mux.HandleFunc("POST /v1/calls/ring", s.handleCallRing) // unauthenticated by design (access-key capability)
	mux.HandleFunc("PUT /v1/keys", s.auth(s.handleSetKeys))
	mux.HandleFunc("GET /v1/keys/count", s.auth(s.handleKeyCount))
	mux.HandleFunc("GET /v1/keys/{account}", s.auth(s.handleGetKeys))
	mux.HandleFunc("GET /v1/keys/{account}/sealed", s.handleGetKeysSealed)          // unauthenticated by design (access-key capability)
	mux.HandleFunc("GET /v1/usernames/{name}/available", s.handleUsernameAvailable) // unauthenticated, per-IP limited
	mux.HandleFunc("PUT /v1/accounts/me/username", s.auth(s.handleUpdateUsername))
	mux.HandleFunc("POST /v1/accounts/password-reset", s.handlePasswordReset) // unauthenticated; proof = fresh Supabase recovery session
	mux.HandleFunc("PUT /v1/accounts/me/email", s.auth(s.handleUpdateEmail))
	mux.HandleFunc("PUT /v1/accounts/me/discoverability", s.auth(s.handleSetDiscoverability))
	mux.HandleFunc("PUT /v1/accounts/me/account-password", s.auth(s.handleSetAccountPassword))
	mux.HandleFunc("POST /v1/accounts/me/nuke", s.auth(s.handleNuke))
	mux.HandleFunc("DELETE /v1/accounts/me", s.auth(s.handleDeleteAccount))
	mux.HandleFunc("POST /v1/reports", s.auth(s.handleCreateReport))
	mux.HandleFunc("GET /v1/devices/{id}/auth-key", s.auth(s.handleGetDeviceAuthKey))
	mux.HandleFunc("POST /v1/passkeys/register/options", s.auth(s.handlePasskeyRegisterOptions))
	mux.HandleFunc("POST /v1/passkeys/register", s.auth(s.handlePasskeyRegister))
	mux.HandleFunc("GET /v1/passkeys", s.auth(s.handleListPasskeys))
	mux.HandleFunc("DELETE /v1/passkeys/{id}", s.auth(s.handleDeletePasskey))
	mux.HandleFunc("POST /v1/passkeys/login/options", s.handlePasskeyLoginOptions)   // unauthenticated, per-IP limited
	mux.HandleFunc("POST /v1/passkeys/login", s.handlePasskeyLogin)                  // unauthenticated, per-IP limited
	mux.HandleFunc("POST /v1/passkeys/signup/options", s.handlePasskeySignupOptions) // unauthenticated, per-IP limited
	mux.HandleFunc("POST /v1/passkeys/signup", s.handlePasskeySignup)                // unauthenticated, per-IP limited
	mux.HandleFunc("GET /v1/accounts/me/sign-in-methods", s.auth(s.handleSignInMethods))
	mux.HandleFunc("POST /v1/accounts/me/email/remove/options", s.auth(s.handleRemoveEmailOptions))
	mux.HandleFunc("POST /v1/accounts/me/email/remove", s.auth(s.handleRemoveEmail))
	mux.HandleFunc("PUT /v1/accounts/me/recovery-key", s.auth(s.handleSetRecoveryKey))
	mux.HandleFunc("DELETE /v1/accounts/me/recovery-key", s.auth(s.handleDeleteRecoveryKey))
	mux.HandleFunc("POST /v1/accounts/recovery-key/signin", s.handleRecoveryKeySignIn) // unauthenticated, per-IP limited
	mux.HandleFunc("GET /v1/turn-credentials", s.auth(s.handleTurnCredentials))
	mux.HandleFunc("POST /v1/attachments", s.auth(s.handleCreateAttachment))
	mux.HandleFunc("PUT /v1/attachments/{id}", s.handleUploadAttachment)   // unauthenticated: id is the capability
	mux.HandleFunc("GET /v1/attachments/{id}", s.handleDownloadAttachment) // unauthenticated: id is the capability
	mux.HandleFunc("POST /v1/group-invites", s.auth(s.handleCreateEncryptedGroupInvite))
	mux.HandleFunc("POST /v1/group-invites/claim", s.handleClaimEncryptedGroupInvite) // unauthenticated: token is the capability
	mux.HandleFunc("GET /v1/ws", s.auth(s.handleWebSocket))
	return stripVisitorIPHeaders(requestDeadlines(limitRequestBody(mux)))
}

// ---------------------------------------------------------------------------
// Auth: Relay-Sig (see sigauth.go) on every authenticated route. HTTP Basic
// "<accountID>.<deviceID>" is accepted only on PUT /v1/devices/auth-key
// (bootstrapAuth), and only for a device with no registered auth key.
// ---------------------------------------------------------------------------

type authedHandler func(w http.ResponseWriter, r *http.Request, dev *store.Device)

// auth requires a Relay-Sig signature.
func (s *Server) auth(next authedHandler) http.HandlerFunc { return s.authenticate(false, next) }

// bootstrapAuth also accepts HTTP Basic, for the one-time upload of a new
// device's auth key.
func (s *Server) bootstrapAuth(next authedHandler) http.HandlerFunc {
	return s.authenticate(true, next)
}

// basicAuthSuccessLimiter bounds successful HTTP Basic authentications per
// target device: 10 per hour. Each one costs a bcrypt, and a device needs
// exactly one (its first auth-key upload), so this only bites a leaked or
// misbehaving credential being used to burn CPU.
var basicAuthSuccessLimiter = newTokenBucketLimiter(10, time.Hour)

func (s *Server) authenticate(allowBasic bool, next authedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ip := clientIP(r)
		if strings.HasPrefix(r.Header.Get("Authorization"), sigAuthScheme+" ") {
			// Many people can share one address (a proxy, carrier NAT, an office),
			// so other people's failures never block a valid signature: checking
			// one is cheap. Only a flood of bad signatures cuts the address off
			// up front.
			if sigFailFloodLimiter.exhausted(ip) {
				httpError(w, http.StatusTooManyRequests, "too many failed authentication attempts; try again later")
				return
			}
			dev, err := s.authenticateSignature(r)
			if errors.Is(err, errNonceBudget) {
				// A valid signature from a device over its replay-cache budget.
				httpError(w, http.StatusTooManyRequests, errNonceBudget.Error())
				return
			}
			if err != nil {
				sigFailFloodLimiter.allow(ip)
				httpError(w, http.StatusUnauthorized, "signature authentication failed")
				return
			}
			next(w, r, dev)
			return
		}
		// HTTP Basic costs a bcrypt, so a source that keeps failing is cut off
		// before any password work.
		if authFailIPLimiter.exhausted(ip) {
			httpError(w, http.StatusTooManyRequests, "too many failed authentication attempts; try again later")
			return
		}
		user, pass, ok := r.BasicAuth()
		if !ok {
			httpError(w, http.StatusUnauthorized, "missing credentials")
			return
		}
		if !allowBasic {
			// Refused before any password work; counted like any other failure.
			authFailIPLimiter.allow(ip)
			httpError(w, http.StatusUnauthorized, "this endpoint requires Relay-Sig authentication")
			return
		}
		accountID, devID, err := parseCredential(user)
		if err != nil {
			authFailIPLimiter.allow(ip)
			httpError(w, http.StatusUnauthorized, "authentication failed")
			return
		}
		deviceKey := accountID + "." + strconv.FormatUint(uint64(devID), 10)
		if authFailDeviceLimiter.exhausted(deviceKey) {
			httpError(w, http.StatusTooManyRequests, "too many failed authentication attempts; try again later")
			return
		}
		if basicAuthSuccessLimiter.exhausted(deviceKey) {
			httpError(w, http.StatusTooManyRequests, "too many password authentications for this device; try again later")
			return
		}
		dev, err := s.store.Authenticate(accountID, devID, pass)
		if err != nil {
			authFailIPLimiter.allow(ip)
			authFailDeviceLimiter.allow(deviceKey)
			httpError(w, http.StatusUnauthorized, "authentication failed")
			return
		}
		basicAuthSuccessLimiter.allow(deviceKey)
		// Basic is a bootstrap credential only. Once a device has an auth key it
		// must sign every request, so a leaked device password can neither act
		// as the device nor swap its key; rotation needs a request signed by the
		// old key.
		if len(dev.AuthPublicKey) > 0 {
			httpError(w, http.StatusUnauthorized, "this device must use Relay-Sig authentication")
			return
		}
		next(w, r, dev)
	}
}

// ---------------------------------------------------------------------------
// Accounts and devices
// ---------------------------------------------------------------------------

func (s *Server) handleCreateAccount(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !accountCreationLimiter.allow(ip) {
		httpError(w, http.StatusTooManyRequests, "registration rate limit exceeded; try again later")
		return
	}
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
		// Optional. Links the account to the Supabase user; the email is kept
		// (as its OPRF token) only if Supabase reports it confirmed. A raw
		// client-supplied email is never accepted, since it would let anyone
		// pre-claim someone else's address for later recovery or OAuth adoption.
		SupabaseAccessToken string `json:"supabaseAccessToken"`
		AccountPassword     string `json:"accountPassword"`    // raw (older clients)
		AccountPasswordKey  string `json:"accountPasswordKey"` // derived on the device
		Email               string `json:"email"`              // rejected; see above
	}
	if err := decodeJSON(r, &req); err != nil ||
		!validUsername.MatchString(req.Username) ||
		len(req.Password) < 8 || len(req.Password) > maxPasswordBytes {
		httpError(w, http.StatusBadRequest, "username (1–64 alphanumeric/._- chars) and password (8–1024 chars) required")
		return
	}
	if req.Email != "" {
		httpError(w, http.StatusBadRequest, "email is not accepted; pass supabaseAccessToken to link a verified email")
		return
	}
	accountPassword, ok := accountPasswordFrom(req.AccountPasswordKey, req.AccountPassword, true)
	if !ok {
		httpError(w, http.StatusBadRequest, "accountPassword must be 8–1024 chars")
		return
	}
	var emailToken []byte
	var supabaseUserID string
	if req.SupabaseAccessToken != "" {
		if s.supabaseURL == "" {
			httpError(w, http.StatusServiceUnavailable, "social login not configured")
			return
		}
		user, err := s.verifySupabaseToken(r.Context(), req.SupabaseAccessToken)
		if err != nil {
			httpError(w, http.StatusUnauthorized, "invalid or expired sign-in token")
			return
		}
		supabaseUserID = user.ID
		if user.EmailConfirmed {
			emailToken = s.emailToken(user.Email)
		}
	}
	accountID, deviceID, err := s.store.CreateAccount(req.Username, emailToken, supabaseUserID, req.Password, accountPassword)
	if errors.Is(err, store.ErrUsernameTaken) {
		httpError(w, http.StatusConflict, "username already taken")
		return
	}
	if errors.Is(err, store.ErrIdentityInUse) {
		// Only reachable by someone holding a valid, confirmed token for this
		// identity. Deliberately generic: point them at sign-in.
		httpError(w, http.StatusConflict, errSignInInstead)
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	devices, err := s.store.ListDevices(accountID)
	if err != nil {
		internalError(w, err)
		return
	}
	mailboxID := ""
	if len(devices) > 0 {
		mailboxID = devices[0].MailboxID
	}
	s.reindexAccount(accountID)
	writeJSON(w, http.StatusCreated, map[string]any{"accountId": accountID, "deviceId": deviceID, "mailboxId": mailboxID})
}

// errSignInInstead is returned whenever a sign-in identity can't create a new
// account. It never says whether, or which, account exists.
const errSignInInstead = "could not create an account with this sign-in; sign in instead"

// handleOAuthAccount signs a Supabase-authenticated user into their relay
// account, creating it on first use, and provisions a fresh device. The access
// token is verified directly with Supabase. An existing account is adopted by
// email only when Supabase reports the email confirmed.
func (s *Server) handleOAuthAccount(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !accountCreationLimiter.allow("oauth:" + ip) {
		httpError(w, http.StatusTooManyRequests, "registration rate limit exceeded; try again later")
		return
	}
	if s.supabaseURL == "" {
		httpError(w, http.StatusServiceUnavailable, "social login not configured")
		return
	}
	var req struct {
		AccessToken        string `json:"accessToken"`
		Username           string `json:"username"`
		Password           string `json:"password"`
		AccountPassword    string `json:"accountPassword"`
		AccountPasswordKey string `json:"accountPasswordKey"`
	}
	if err := decodeJSON(r, &req); err != nil || req.AccessToken == "" ||
		len(req.Password) < 8 || len(req.Password) > maxPasswordBytes {
		httpError(w, http.StatusBadRequest, "accessToken and password (8–1024 chars) required")
		return
	}
	if req.Username != "" && !validUsername.MatchString(req.Username) {
		httpError(w, http.StatusBadRequest, "username must be 1–64 alphanumeric/._- characters")
		return
	}
	accountPassword, ok := accountPasswordFrom(req.AccountPasswordKey, req.AccountPassword, false)
	if !ok {
		httpError(w, http.StatusBadRequest, "accountPassword must be 8–1024 chars")
		return
	}

	user, err := s.verifySupabaseToken(r.Context(), req.AccessToken)
	if err != nil {
		httpError(w, http.StatusUnauthorized, "invalid or expired social login token")
		return
	}
	var emailToken []byte
	if user.EmailConfirmed {
		emailToken = s.emailToken(user.Email)
	}

	// Registration lock: a sign-in that resolves to an existing account with
	// an account password must present it (it replaces every device). Wrong
	// guesses back off exponentially per account (recoveryLockout).
	dev, created, err := s.store.ProvisionOAuthAccount(
		user.ID, emailToken, req.Username, req.Password, accountPassword,
		func(accountID string) bool { return recoveryLockout.attempt(registrationLockKey(accountID)) })
	switch {
	case errors.Is(err, store.ErrAccountPasswordLocked):
		httpError(w, http.StatusTooManyRequests, "too many account password attempts; try again later")
		return
	case errors.Is(err, store.ErrAccountPasswordRequired):
		httpError(w, http.StatusLocked, "account password required")
		return
	case errors.Is(err, store.ErrStrongerSignInRequired):
		httpError(w, http.StatusForbidden, "This account has a passkey or recovery key. Sign in with one of those instead.")
		return
	case errors.Is(err, store.ErrAccountPasswordIncorrect):
		// Already charged by attempt.
		httpError(w, http.StatusLocked, "account password incorrect")
		return
	case errors.Is(err, store.ErrUsernameRequired):
		// New user without a username: the client prompts for one and retries.
		httpError(w, http.StatusNotFound, "username required")
		return
	case errors.Is(err, store.ErrUsernameTaken):
		httpError(w, http.StatusConflict, "username already taken")
		return
	case errors.Is(err, store.ErrIdentityInUse):
		httpError(w, http.StatusConflict, errSignInInstead)
		return
	case errors.Is(err, store.ErrDeviceLimit):
		httpError(w, http.StatusConflict, "device limit reached; unlink a device first")
		return
	case err != nil:
		internalError(w, err)
		return
	}

	if !created && !accountPassword.Empty() {
		recoveryLockout.succeed(registrationLockKey(dev.AccountID))
	}
	status := http.StatusOK
	if created {
		status = http.StatusCreated
		s.reindexAccount(dev.AccountID)
	}
	writeJSON(w, status, map[string]any{
		"accountId": dev.AccountID,
		"deviceId":  dev.DeviceID,
		"username":  dev.Username,
		"mailboxId": dev.MailboxID,
		"created":   created,
	})
	s.retireReplacedDevices(dev)
}

// retireReplacedDevices tells each device replaced by a sign-in or recovery
// that it was removed, so a running app signs itself out, then drops its
// socket. Its rows are already gone, so its credentials no longer work.
func (s *Server) retireReplacedDevices(dev store.AddedDevice) {
	for _, old := range dev.ReplacedDevices {
		s.hub.BroadcastDeviceListChanged(dev.AccountID, dev.DeviceID, relaypb.DeviceListChanged_DEVICE_REMOVED, old)
		s.hub.DisconnectDevice(dev.AccountID, old, "replaced by a new sign-in")
	}
}

// supabaseUser is what the relay trusts from Supabase's /auth/v1/user.
type supabaseUser struct {
	ID             string
	Email          string
	EmailConfirmed bool
	// RecoveredAt is when this session was created by a password-recovery
	// code (the token's amr "recovery" entry); zero if it wasn't.
	RecoveredAt time.Time
}

// recoveryAuthTime reads when a Supabase access token was minted by a
// password-recovery sign-in, from its "amr" claim. Only call it on a token
// Supabase has just vouched for (GET /auth/v1/user succeeded): the payload is
// decoded, not re-verified.
func recoveryAuthTime(accessToken string) time.Time {
	parts := strings.Split(accessToken, ".")
	if len(parts) != 3 {
		return time.Time{}
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return time.Time{}
	}
	var claims struct {
		AMR []struct {
			Method    string `json:"method"`
			Timestamp int64  `json:"timestamp"`
		} `json:"amr"`
	}
	if json.Unmarshal(payload, &claims) != nil {
		return time.Time{}
	}
	var latest time.Time
	for _, m := range claims.AMR {
		if m.Method == "recovery" {
			if t := time.Unix(m.Timestamp, 0); t.After(latest) {
				latest = t
			}
		}
	}
	return latest
}

// supabaseHTTPClient bounds every server-to-server Supabase call.
var supabaseHTTPClient = &http.Client{Timeout: 10 * time.Second}

// verifySupabaseTokenHTTP asks Supabase who an access token belongs to via
// GET /auth/v1/user. Email is confirmed if email_confirmed_at (or confirmed_at
// for an email-only user) is set.
func (s *Server) verifySupabaseTokenHTTP(ctx context.Context, accessToken string) (supabaseUser, error) {
	if s.supabaseURL == "" {
		return supabaseUser{}, errors.New("supabase auth not configured")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.supabaseURL+"/auth/v1/user", nil)
	if err != nil {
		return supabaseUser{}, err
	}
	req.Header.Set("apikey", s.supabaseAnonKey)
	req.Header.Set("Authorization", "Bearer "+accessToken)
	resp, err := supabaseHTTPClient.Do(req)
	if err != nil {
		return supabaseUser{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return supabaseUser{}, fmt.Errorf("supabase user lookup failed: HTTP %d", resp.StatusCode)
	}
	var body struct {
		ID               string  `json:"id"`
		Email            string  `json:"email"`
		Phone            string  `json:"phone"`
		EmailConfirmedAt *string `json:"email_confirmed_at"`
		ConfirmedAt      *string `json:"confirmed_at"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&body); err != nil {
		return supabaseUser{}, err
	}
	if body.ID == "" {
		return supabaseUser{}, errors.New("supabase returned no user id")
	}
	set := func(p *string) bool { return p != nil && *p != "" }
	confirmed := body.Email != "" &&
		(set(body.EmailConfirmedAt) || (set(body.ConfirmedAt) && body.Phone == ""))
	return supabaseUser{ID: body.ID, Email: body.Email, EmailConfirmed: confirmed,
		RecoveredAt: recoveryAuthTime(accessToken)}, nil
}

// sealedDummyAccessKey is compared against when a sealed send names an unknown
// mailbox or an account with no access key, so the comparison work is the same
// either way. It is random per process, and a match is rejected regardless.
var sealedDummyAccessKey = func() (k [32]byte) {
	if _, err := rand.Read(k[:]); err != nil {
		panic("api: crypto/rand failed: " + err.Error())
	}
	return k
}()

// handleSealedSend delivers a sealed-sender message. It is unauthenticated by
// design so the relay never learns the sender. The sender presents the
// recipient's access key (obtained with the prekey bundle), checked in constant
// time. The envelope carries no sender fields; the recipient recovers the
// sender by decrypting the sealed blob.
func (s *Server) handleSealedSend(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !sealedSendIPLimiter.allow(ip) {
		httpError(w, http.StatusTooManyRequests, "rate limit exceeded; try again later")
		return
	}
	// No client timestamp is accepted: a sender clock offset is a fingerprint
	// that could link anonymous sends to one device. Timestamps that matter live
	// inside the encrypted content; the envelope carries the relay's receive time.
	var req struct {
		MailboxID string `json:"mailboxId"`
		Type      int32  `json:"type"`
		Content   string `json:"content"`   // base64 sealed blob
		AccessKey string `json:"accessKey"` // base64, recipient's access key
		Ephemeral bool   `json:"ephemeral"`
		Silent    bool   `json:"silent"` // queue without a push (receipts)
	}
	if err := decodeJSON(r, &req); err != nil || req.MailboxID == "" {
		httpError(w, http.StatusBadRequest, "mailboxId and content required")
		return
	}
	content, err := base64.StdEncoding.DecodeString(req.Content)
	if err != nil || len(content) == 0 {
		httpError(w, http.StatusBadRequest, "invalid content")
		return
	}
	token, err := base64.StdEncoding.DecodeString(req.AccessKey)
	if err != nil {
		httpError(w, http.StatusBadRequest, "invalid access key")
		return
	}
	dest, ok := s.checkMailboxAccess(req.MailboxID, token)
	if !ok {
		httpError(w, http.StatusForbidden, "delivery rejected")
		return
	}
	// Charged only after the access check: otherwise anyone who knew a mailbox
	// id could spend its budget with bad keys and block its delivery.
	if !sealedSendMailboxLimiter.allow(req.MailboxID) {
		httpError(w, http.StatusTooManyRequests, "rate limit exceeded; try again later")
		return
	}

	now := time.Now().UnixMilli()
	env := &relaypb.Envelope{
		Id: newEnvelopeID(),
		// Sender fields are left empty: the relay doesn't know the sender.
		Type:            relaypb.CiphertextType(req.Type),
		Content:         content,
		ClientTimestamp: now, // never the sender's clock
		ServerTimestamp: now,
		Ephemeral:       req.Ephemeral,
	}
	// Queue fairness for an anonymous sender is keyed by its source-IP bucket.
	if err := s.hub.DeliverFrom("ip:"+ip, dest.AccountID, dest.DeviceID, env, !req.Silent); err != nil {
		if errors.Is(err, hub.ErrSenderQuota) || errors.Is(err, store.ErrQueueFull) {
			httpError(w, http.StatusTooManyRequests, "rate limit exceeded; try again later")
			return
		}
		if errors.Is(err, store.ErrNotFound) {
			// Device removed after the access check: answer as for an unknown
			// mailbox.
			httpError(w, http.StatusForbidden, "delivery rejected")
			return
		}
		slog.Error("sealed send: deliver failed", "err", privlog.Error(err))
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"serverTimestamp": env.ServerTimestamp})
}

// checkMailboxAccess is the capability check for sealed sends and call rings:
// the presented key must equal the access key of the account owning the
// mailbox. Every failure takes the same path (one query, and a constant-time
// comparison against a dummy key when the mailbox or key is unknown), so a
// caller can't tell an unknown mailbox from a wrong key.
func (s *Server) checkMailboxAccess(mailboxID string, presented []byte) (*store.Device, bool) {
	dest, stored, lookupErr := s.store.SealedTargetByMailbox(mailboxID)
	known := lookupErr == nil && len(stored) == len(sealedDummyAccessKey)
	if !known {
		stored = sealedDummyAccessKey[:]
	}
	match := subtle.ConstantTimeCompare(stored, presented) == 1
	if !known || !match {
		return nil, false
	}
	return dest, true
}

// handleFetchQueue returns this device's queued envelopes over REST, which can
// run on HTTP/3 when the WebSocket can't connect. It does not dequeue: the
// client acks each envelope via POST /v1/messages/ack (at-least-once).
//
// ?limit=N (1-100, default 100) caps the envelope count, and a page also stops
// at 4 MiB of ciphertext. When "more" is true the response carries an opaque
// "cursor" to pass back as ?cursor= for the next page.
func (s *Server) handleFetchQueue(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	limit := queuePageMaxEnvelopes
	if q := r.URL.Query().Get("limit"); q != "" {
		n, err := strconv.Atoi(q)
		if err != nil || n < 1 {
			httpError(w, http.StatusBadRequest, "limit must be a positive integer")
			return
		}
		limit = min(n, queuePageMaxEnvelopes)
	}
	var after store.QueueCursor
	if c := r.URL.Query().Get("cursor"); c != "" {
		var ok bool
		if after, ok = parseQueueCursor(c); !ok {
			httpError(w, http.StatusBadRequest, "invalid cursor")
			return
		}
	}
	page, more, err := s.store.QueuedEnvelopesPage(dev.AccountID, dev.DeviceID, after, limit, queuePageMaxBytes)
	if err != nil {
		internalError(w, err)
		return
	}
	out := make([]string, 0, len(page))
	for _, e := range page {
		out = append(out, base64.StdEncoding.EncodeToString(e.Envelope))
	}
	resp := map[string]any{"envelopes": out, "more": more}
	if more && len(page) > 0 {
		last := page[len(page)-1]
		resp["cursor"] = formatQueueCursor(store.QueueCursor{CreatedAt: last.CreatedAt, EnvelopeID: last.ID})
	}
	writeJSON(w, http.StatusOK, resp)
}

// Queue cursors are opaque to clients: "<createdAtMs>.<envelopeId>".
func formatQueueCursor(c store.QueueCursor) string {
	return strconv.FormatInt(c.CreatedAt, 10) + "." + c.EnvelopeID
}

func parseQueueCursor(v string) (store.QueueCursor, bool) {
	ts, id, ok := strings.Cut(v, ".")
	if !ok || len(id) == 0 || len(id) > 64 {
		return store.QueueCursor{}, false
	}
	n, err := strconv.ParseInt(ts, 10, 64)
	if err != nil || n < 0 {
		return store.QueueCursor{}, false
	}
	return store.QueueCursor{CreatedAt: n, EnvelopeID: id}, true
}

// handleAckMessage removes a delivered envelope from this device's queue; the
// REST equivalent of the WebSocket AckRequest.
func (s *Server) handleAckMessage(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		EnvelopeID string `json:"envelopeId"`
	}
	if err := decodeJSON(r, &req); err != nil || req.EnvelopeID == "" {
		httpError(w, http.StatusBadRequest, "envelopeId required")
		return
	}
	if err := s.hub.Ack(dev.AccountID, dev.DeviceID, req.EnvelopeID); err != nil {
		internalError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleSetAccessKey stores this account's 32-byte sealed-sender access key,
// which senders present on the unauthenticated delivery path.
func (s *Server) handleSetAccessKey(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		AccessKey string `json:"accessKey"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "invalid body")
		return
	}
	key, err := base64.StdEncoding.DecodeString(req.AccessKey)
	if err != nil || len(key) != 32 {
		httpError(w, http.StatusBadRequest, "accessKey must be 32 bytes (base64)")
		return
	}
	if err := s.store.SetAccessKey(dev.AccountID, key); err != nil {
		internalError(w, err)
		return
	}
	// The directory carries the access key (sealed) for anonymous first contact.
	s.reindexAccount(dev.AccountID)
	w.WriteHeader(http.StatusNoContent)
}

// handleRotateMailbox assigns the device a fresh mailbox id and returns it.
// The relay never rotates mailboxes on its own. Peers pick up the new id on
// their next bundle fetch; sealed sends to the old id fail and retry.
func (s *Server) handleRotateMailbox(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	mailboxID, err := s.store.RotateMailbox(dev.AccountID, dev.DeviceID)
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"mailboxId": mailboxID})
}

// handleDirectoryOPRF evaluates the OPRF (E = k·B) over a batch of blinded
// elements, so the server learns nothing about the identifiers queried. Each
// element spends one unit of a per-account and a per-IP daily budget, so the
// oracle can't be used to enumerate identifiers.
func (s *Server) handleDirectoryOPRF(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if s.oprf == nil {
		httpError(w, http.StatusServiceUnavailable, "discovery not configured")
		return
	}
	if !directoryLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "discovery rate limit exceeded; try again later")
		return
	}
	var req struct {
		Blinded []string `json:"blinded"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if len(req.Blinded) == 0 || len(req.Blinded) > maxDirectoryBatch {
		httpError(w, http.StatusBadRequest, "blinded must contain 1..1024 elements")
		return
	}
	elements := make([][]byte, 0, len(req.Blinded))
	for _, b := range req.Blinded {
		raw, err := base64.StdEncoding.DecodeString(b)
		if err != nil {
			httpError(w, http.StatusBadRequest, "invalid blinded element")
			return
		}
		elements = append(elements, raw)
	}
	ip := clientIP(r)
	if !oprfBudget.take(len(elements), "acct:"+dev.AccountID, "ip:"+ip) {
		httpError(w, http.StatusTooManyRequests, "discovery budget exhausted; try again later")
		return
	}
	out := make([]string, 0, len(elements))
	for _, raw := range elements {
		eval, err := s.oprf.Evaluate(raw)
		if err != nil {
			httpError(w, http.StatusBadRequest, "invalid blinded element")
			return
		}
		out = append(out, base64.StdEncoding.EncodeToString(eval))
	}
	writeJSON(w, http.StatusOK, map[string]any{"evaluated": out})
}

// handleDirectoryBuckets returns the directory entries for the requested
// 16-bit buckets. Clients derive buckets from OPRF tokens locally and tokens
// never leave the device. Each entry is a match tag plus a box only a token
// holder can open, so the relay learns which buckets were requested but not
// which identifiers, or which matched.
func (s *Server) handleDirectoryBuckets(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if s.oprf == nil {
		httpError(w, http.StatusServiceUnavailable, "discovery not configured")
		return
	}
	ip := clientIP(r)
	if !directoryLimiter.allow(dev.AccountID) || !directoryIPLimiter.allow(ip) {
		httpError(w, http.StatusTooManyRequests, "discovery rate limit exceeded; try again later")
		return
	}
	var req struct {
		Buckets []int `json:"buckets"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if len(req.Buckets) == 0 || len(req.Buckets) > maxDirectoryBatch {
		httpError(w, http.StatusBadRequest, "buckets must contain 1..1024 entries")
		return
	}
	seen := make(map[uint16]bool, len(req.Buckets))
	buckets := make([]uint16, 0, len(req.Buckets))
	for _, b := range req.Buckets {
		if b < 0 || b > 0xffff {
			httpError(w, http.StatusBadRequest, "bucket out of range")
			return
		}
		if !seen[uint16(b)] {
			seen[uint16(b)] = true
			buckets = append(buckets, uint16(b))
		}
	}
	// Demo accounts only see demo accounts; everyone else never sees them.
	rows, err := s.store.DirectoryBucketsFor(buckets, s.isDemo(dev.AccountID))
	if err != nil {
		internalError(w, err)
		return
	}
	type entry struct {
		Tag       b64 `json:"tag"`
		Box       b64 `json:"box"`
		AccessBox b64 `json:"accessBox,omitempty"`
	}
	type bucket struct {
		Bucket  uint16  `json:"bucket"`
		Entries []entry `json:"entries"`
	}
	byBucket := make(map[uint16][]entry, len(buckets))
	for _, e := range rows {
		byBucket[e.Bucket] = append(byBucket[e.Bucket], entry{Tag: e.Tag, Box: e.Box, AccessBox: e.AccessBox})
	}
	out := make([]bucket, 0, len(buckets))
	for _, b := range buckets {
		entries := byBucket[b]
		if entries == nil {
			entries = []entry{}
		}
		out = append(out, bucket{Bucket: b, Entries: entries})
	}
	writeJSON(w, http.StatusOK, map[string]any{"buckets": out})
}

// handleDeliveryCertificate mints a sealed-sender certificate for the
// authenticated device, binding its account id, device id, username and stored
// identity key with a 7-day expiry.
func (s *Server) handleDeliveryCertificate(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if s.sealed == nil {
		httpError(w, http.StatusServiceUnavailable, "sealed sender not configured")
		return
	}
	identityKey, err := s.store.IdentityKey(dev.AccountID, dev.DeviceID)
	if err != nil || len(identityKey) == 0 {
		httpError(w, http.StatusConflict, "device has not published an identity key")
		return
	}
	// The username travels in the certificate so recipients learn who wrote
	// without asking the relay about the sender.
	username, err := s.store.LookupUsername(dev.AccountID)
	if err != nil {
		internalError(w, err)
		return
	}
	expiresAt := time.Now().Add(7 * 24 * time.Hour).UnixMilli()
	cert, err := sealedsender.MintSenderCertificate(
		s.sealed.serverCert, s.sealed.serverCertKey,
		dev.AccountID, username, dev.DeviceID, identityKey, uint64(expiresAt),
	)
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"certificate": base64.StdEncoding.EncodeToString(cert),
		"expiresAt":   expiresAt,
	})
}

// handleCreateContactInvite mints a single-use contact invite token for the
// authenticated account.
func (s *Server) handleCreateContactInvite(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if !contactInviteLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "too many invites today; try again later")
		return
	}
	token, expiresAt, err := s.store.CreateContactInvite(dev.AccountID)
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"token": token, "expiresAt": expiresAt})
}

// handleClaimContactInvite consumes a contact invite token, returning the
// inviter's account id and username. A second claim returns 404. It is
// unauthenticated (the token is the capability) so the relay can't record who
// redeemed whose invite.
func (s *Server) handleClaimContactInvite(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !inviteClaimIPLimiter.allow(ip) {
		httpError(w, http.StatusTooManyRequests, "too many invite claims; try again later")
		return
	}
	var req struct {
		Token string `json:"token"`
	}
	if err := decodeJSON(r, &req); err != nil || req.Token == "" {
		httpError(w, http.StatusBadRequest, "token required")
		return
	}
	accountID, username, err := s.store.ClaimContactInvite(req.Token)
	if errors.Is(err, store.ErrContactInviteInvalid) {
		httpError(w, http.StatusNotFound, "invite is invalid, expired, or already used")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"accountId": accountID, "username": username})
}

// passwordResetWindow bounds how old the Supabase recovery sign-in may be.
const passwordResetWindow = 15 * time.Minute

// handlePasswordReset is "forgot password". The client proves control of the
// account's verified email with a Supabase session minted by a recovery code
// (amr "recovery", within passwordResetWindow). An ordinary session is not
// enough, so a stolen session can't bypass the account-password lock. The
// account gets the new password and its devices are replaced by this one.
func (s *Server) handlePasswordReset(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !accountCreationLimiter.allow("reset:" + ip) {
		httpError(w, http.StatusTooManyRequests, "password reset rate limit exceeded; try again later")
		return
	}
	var req struct {
		AccessToken        string `json:"accessToken"`
		AccountPassword    string `json:"accountPassword"`
		AccountPasswordKey string `json:"accountPasswordKey"`
		Password           string `json:"password"`
	}
	newPassword, ok := store.AccountPassword{}, false
	if err := decodeJSON(r, &req); err == nil {
		newPassword, ok = accountPasswordFrom(req.AccountPasswordKey, req.AccountPassword, true)
	}
	if !ok || newPassword.Empty() || req.AccessToken == "" ||
		len(req.Password) < 8 || len(req.Password) > maxPasswordBytes {
		httpError(w, http.StatusBadRequest, "accessToken, accountPassword (8–1024) and password (8–1024) required")
		return
	}
	if s.supabaseURL == "" {
		httpError(w, http.StatusServiceUnavailable, "password reset not configured")
		return
	}
	user, err := s.verifySupabaseToken(r.Context(), req.AccessToken)
	if err != nil || !user.EmailConfirmed {
		httpError(w, http.StatusUnauthorized, "invalid or expired reset session")
		return
	}
	if user.RecoveredAt.IsZero() || time.Since(user.RecoveredAt) > passwordResetWindow {
		httpError(w, http.StatusForbidden, "a fresh password-recovery code is required")
		return
	}
	dev, err := s.store.ResetAccountPassword(user.ID, s.emailToken(user.Email), newPassword, req.Password)
	switch {
	case errors.Is(err, store.ErrAccountNotFound):
		httpError(w, http.StatusNotFound, "no Relay account for this email")
		return
	case errors.Is(err, store.ErrIdentityInUse):
		httpError(w, http.StatusConflict, errSignInInstead)
		return
	case errors.Is(err, store.ErrDemoAccount):
		httpError(w, http.StatusForbidden, demoForbiddenMessage)
		return
	case errors.Is(err, store.ErrStrongerSignInRequired):
		httpError(w, http.StatusForbidden, "This account has a passkey or recovery key. Sign in with one of those instead.")
		return
	case err != nil:
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"accountId": dev.AccountID,
		"username":  dev.Username,
		"deviceId":  dev.DeviceID,
		"mailboxId": dev.MailboxID,
	})
	s.retireReplacedDevices(dev)
}

// handleUpdateEmail runs after the user confirmed a new email with Supabase.
// It checks the session belongs to this account's linked Supabase user and the
// email is confirmed, then re-keys the account's email token.
func (s *Server) handleUpdateEmail(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if s.refuseIfDemo(w, dev.AccountID) {
		return
	}
	var req struct {
		AccessToken string `json:"accessToken"`
	}
	if err := decodeJSON(r, &req); err != nil || req.AccessToken == "" {
		httpError(w, http.StatusBadRequest, "accessToken required")
		return
	}
	if s.supabaseURL == "" {
		httpError(w, http.StatusServiceUnavailable, "email change not configured")
		return
	}
	user, err := s.verifySupabaseToken(r.Context(), req.AccessToken)
	if err != nil || !user.EmailConfirmed {
		httpError(w, http.StatusUnauthorized, "invalid session or unconfirmed email")
		return
	}
	linked, err := s.store.SupabaseUserID(dev.AccountID)
	if err != nil {
		internalError(w, err)
		return
	}
	if linked == "" || linked != user.ID {
		httpError(w, http.StatusForbidden, "this sign-in doesn't belong to your account")
		return
	}
	token := s.emailToken(user.Email)
	if token == nil {
		httpError(w, http.StatusServiceUnavailable, "email features unavailable")
		return
	}
	switch err := s.store.SetAccountEmailToken(dev.AccountID, token); {
	case errors.Is(err, store.ErrIdentityInUse):
		httpError(w, http.StatusConflict, "that email is already used by another account")
		return
	case err != nil:
		internalError(w, err)
		return
	}
	s.reindexAccount(dev.AccountID)
	s.noticeAccountChange(dev, store.NoticeEmailChanged)
	w.WriteHeader(http.StatusNoContent)
}

// handleRecoverAccount provisions a new device for the account whose verified
// email matches, given its account password. Every failure gets the same 401
// after the same bcrypt work, and lockout backoff applies whether or not the
// email is registered, so none of status, timing or lockout reveals whether an
// account exists.
func (s *Server) handleRecoverAccount(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !accountCreationLimiter.allow("recover:" + ip) {
		httpError(w, http.StatusTooManyRequests, "recovery rate limit exceeded; try again later")
		return
	}
	var req struct {
		Email              string `json:"email"`
		AccountPassword    string `json:"accountPassword"`
		AccountPasswordKey string `json:"accountPasswordKey"`
	}
	presented, ok := store.AccountPassword{}, false
	if err := decodeJSON(r, &req); err == nil {
		presented, ok = accountPasswordFrom(req.AccountPasswordKey, req.AccountPassword, false)
	}
	if !ok || req.Email == "" || presented.Empty() {
		httpError(w, http.StatusBadRequest, "email and accountPassword required")
		return
	}
	token := s.emailToken(req.Email)
	if token == nil {
		httpError(w, http.StatusServiceUnavailable, "email recovery unavailable")
		return
	}
	lockKey := hex.EncodeToString(token)
	if !recoveryLockout.attempt(lockKey) {
		httpError(w, http.StatusTooManyRequests, "too many recovery attempts; try again later")
		return
	}
	dev, devicePassword, err := s.store.RecoverAccount(token, presented)
	switch {
	case errors.Is(err, store.ErrAccountPasswordUpgradeRequired):
		httpError(w, http.StatusPreconditionRequired, errAccountPasswordUpgrade)
		return
	case errors.Is(err, store.ErrAuthFailed):
		// Already charged by attempt.
		httpError(w, http.StatusUnauthorized, "recovery failed")
		return
	case errors.Is(err, store.ErrDeviceLimit):
		// Only reachable with the correct recovery password.
		httpError(w, http.StatusConflict, "device limit reached; unlink a device first")
		return
	case err != nil:
		internalError(w, err)
		return
	}
	recoveryLockout.succeed(lockKey)
	writeJSON(w, http.StatusCreated, map[string]any{
		"accountId":      dev.AccountID,
		"username":       dev.Username,
		"deviceId":       dev.DeviceID,
		"devicePassword": devicePassword,
		"mailboxId":      dev.MailboxID,
	})
	s.retireReplacedDevices(dev)
}

func (s *Server) handleUpdateUsername(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if s.refuseIfDemo(w, dev.AccountID) {
		return
	}
	var req struct {
		Username string `json:"username"`
	}
	if err := decodeJSON(r, &req); err != nil || !validUsername.MatchString(req.Username) {
		httpError(w, http.StatusBadRequest, "username must be 1–64 alphanumeric/._- characters")
		return
	}
	if usernameChangeLimiter.exhausted(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "too many username changes today; try again later")
		return
	}
	if err := s.store.UpdateUsername(dev.AccountID, req.Username); errors.Is(err, store.ErrUsernameTaken) {
		httpError(w, http.StatusConflict, "username already taken")
		return
	} else if err != nil {
		internalError(w, err)
		return
	}
	usernameChangeLimiter.allow(dev.AccountID) // only completed changes spend budget
	s.reindexAccount(dev.AccountID)
	w.WriteHeader(http.StatusNoContent)
}

// handleSetDiscoverability sets whether the account's verified email gets a
// blinded-directory entry (off by default). Username entries are unaffected.
// Body: {"email": bool}, required.
func (s *Server) handleSetDiscoverability(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if s.refuseIfDemo(w, dev.AccountID) {
		return
	}
	var req struct {
		Email *bool `json:"email"`
	}
	if err := decodeJSON(r, &req); err != nil || req.Email == nil {
		httpError(w, http.StatusBadRequest, "email (bool) required")
		return
	}
	if err := s.store.SetEmailDiscoverable(dev.AccountID, *req.Email); err != nil {
		internalError(w, err)
		return
	}
	s.reindexAccount(dev.AccountID)
	w.WriteHeader(http.StatusNoContent)
}

// accountPasswordLimiter bounds account-password changes per account: 10 per
// hour (each is a bcrypt).
var accountPasswordLimiter = newTokenBucketLimiter(10, time.Hour)

const errAccountPasswordUpgrade = "account password upgrade required"

// accountPasswordFrom reads the account password a client sent: the key it
// derived on the device, and/or the raw password (older clients; or, next to
// the key, the one-time upgrade of an account stored before keys). A new
// password (setting=true) must be 8+ characters when raw. ok is false for
// malformed input; both empty is ok (no password).
func accountPasswordFrom(key, legacy string, setting bool) (store.AccountPassword, bool) {
	if len(key) > 128 || len(legacy) > maxPasswordBytes {
		return store.AccountPassword{}, false
	}
	if key != "" && len(key) < 32 {
		return store.AccountPassword{}, false
	}
	if setting && key == "" && legacy != "" && len(legacy) < 8 {
		return store.AccountPassword{}, false
	}
	return store.AccountPassword{Key: key, Legacy: legacy}, true
}

// handleSetAccountPassword sets or changes the account password, which guards
// email recovery and the sign-in registration lock. Any signed device of the
// account may set it.
func (s *Server) handleSetAccountPassword(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if s.refuseIfDemo(w, dev.AccountID) {
		return
	}
	var req struct {
		AccountPassword    string `json:"accountPassword"`
		AccountPasswordKey string `json:"accountPasswordKey"`
	}
	newPassword, ok := store.AccountPassword{}, false
	if err := decodeJSON(r, &req); err == nil {
		newPassword, ok = accountPasswordFrom(req.AccountPasswordKey, req.AccountPassword, true)
	}
	if !ok || newPassword.Empty() {
		httpError(w, http.StatusBadRequest, "accountPassword (8–1024 chars) required")
		return
	}
	if !accountPasswordLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "too many account password changes; try again later")
		return
	}
	if err := s.store.SetAccountPassword(dev.AccountID, newPassword); err != nil {
		internalError(w, err)
		return
	}
	s.noticeAccountChange(dev, store.NoticeAccountPasswordSet)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAddDevice(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Password string             `json:"password"`
		Auth     deviceMutationAuth `json:"auth"`
	}
	if err := decodeJSON(r, &req); err != nil || len(req.Password) < 8 || len(req.Password) > maxPasswordBytes {
		httpError(w, http.StatusBadRequest, "password (8–1024 chars) required")
		return
	}
	if err := verifyDeviceMutation(dev, req.Auth, "add", 0, req.Password); err != nil {
		httpError(w, http.StatusForbidden, err.Error())
		return
	}
	deviceID, version, err := s.store.AddDevice(dev.AccountID, req.Password, req.Auth.ExpectedVersion)
	if err != nil {
		if errors.Is(err, store.ErrDeviceListVersionMismatch) {
			httpError(w, http.StatusConflict, "device list changed; refresh and try again")
			return
		}
		if errors.Is(err, store.ErrDeviceLimit) {
			httpError(w, http.StatusConflict, "linked device limit reached; unlink a device first")
			return
		}
		internalError(w, err)
		return
	}
	devices, err := s.store.ListDevices(dev.AccountID)
	if err != nil {
		internalError(w, err)
		return
	}
	mailboxID := ""
	for _, d := range devices {
		if d.DeviceID == deviceID {
			mailboxID = d.MailboxID
			break
		}
	}
	writeJSON(w, http.StatusCreated, map[string]any{"accountId": dev.AccountID, "deviceId": deviceID, "mailboxId": mailboxID, "deviceListVersion": version})
	s.hub.BroadcastDeviceListChanged(dev.AccountID, dev.DeviceID, relaypb.DeviceListChanged_DEVICE_ADDED, deviceID)
}

func (s *Server) handleCreateDeviceLinkInvitation(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Auth deviceMutationAuth `json:"auth"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "device mutation signature required")
		return
	}
	if err := verifyDeviceMutation(dev, req.Auth, "link", 0, ""); err != nil {
		httpError(w, http.StatusForbidden, err.Error())
		return
	}
	token, code, expiresAt, err := s.store.CreateDeviceLinkToken(dev.AccountID, req.Auth.ExpectedVersion)
	if err != nil {
		if errors.Is(err, store.ErrDeviceListVersionMismatch) {
			httpError(w, http.StatusConflict, "device list changed; refresh and try again")
			return
		}
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"linkToken":        token,
		"verificationCode": code,
		"expiresAt":        expiresAt,
	})
}

func (s *Server) handleClaimDeviceLink(w http.ResponseWriter, r *http.Request) {
	if !linkClaimIPLimiter.allow(clientIP(r)) {
		httpError(w, http.StatusTooManyRequests, "too many link attempts; try again later")
		return
	}
	var req struct {
		LinkToken        string `json:"linkToken"`
		VerificationCode string `json:"verificationCode"`
	}
	if err := decodeJSON(r, &req); err != nil || req.LinkToken == "" || req.VerificationCode == "" {
		httpError(w, http.StatusBadRequest, "linkToken and verificationCode required")
		return
	}
	claim, err := s.store.ClaimDeviceLinkToken(req.LinkToken, req.VerificationCode)
	if errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusNotFound, "link code expired or already used")
		return
	}
	if errors.Is(err, store.ErrDeviceListVersionMismatch) {
		httpError(w, http.StatusConflict, "device list changed; create a new link code")
		return
	}
	if errors.Is(err, store.ErrDeviceLimit) {
		httpError(w, http.StatusConflict, "linked device limit reached; unlink a device first")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"accountId": claim.AccountID,
		"deviceId":  claim.DeviceID,
		"password":  claim.Password,
		"username":  claim.Username,
	})
}

// handleCreateProvisioningSession creates a provisioning session for reversed
// linking. It is unauthenticated because the new device has no account yet.
func (s *Server) handleCreateProvisioningSession(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !provisioningLimiter.allow(ip) {
		httpError(w, http.StatusTooManyRequests, "too many device-linking attempts; try again later")
		return
	}
	sessionID, expiresAt, err := s.store.CreateProvisioningSession()
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"sessionId": sessionID,
		"expiresAt": expiresAt,
	})
}

// handleFetchProvisioning lets the new device poll for the primary's encrypted
// payload: 204 until it arrives, 404 once expired or consumed.
func (s *Server) handleFetchProvisioning(w http.ResponseWriter, r *http.Request) {
	if !provisioningPollIPLimiter.allow(clientIP(r)) {
		httpError(w, http.StatusTooManyRequests, "polling too fast; try again later")
		return
	}
	blob, err := s.store.FetchProvisioningBlob(r.PathValue("id"))
	if errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusNotFound, "provisioning session expired or unknown")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	if blob == nil {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"blob": blob})
}

// handleStoreProvisioning stores the primary's payload for a session. The
// payload is end-to-end encrypted to the new device's ephemeral key.
func (s *Server) handleStoreProvisioning(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	r.Body = http.MaxBytesReader(w, r.Body, maxProvisioningBlobBytes)
	var req struct {
		Blob b64 `json:"blob"`
	}
	if err := decodeJSON(r, &req); err != nil || len(req.Blob) == 0 {
		httpError(w, http.StatusBadRequest, "blob required")
		return
	}
	if len(req.Blob) > maxProvisioningBlobBytes {
		httpError(w, http.StatusRequestEntityTooLarge, "provisioning blob too large")
		return
	}
	err := s.store.StoreProvisioningBlob(r.PathValue("id"), req.Blob)
	if errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusNotFound, "provisioning session expired, unknown, or already used")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleLinkDevice creates a device for the primary's account with a
// primary-supplied password, bound into the device-mutation signature. In the
// reversed flow the QR scan is the trust anchor, so there is no verification
// code.
func (s *Server) handleLinkDevice(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Password   string             `json:"password"`
		DeviceName string             `json:"deviceName"`
		Auth       deviceMutationAuth `json:"auth"`
	}
	if err := decodeJSON(r, &req); err != nil || req.Password == "" {
		httpError(w, http.StatusBadRequest, "password and device mutation signature required")
		return
	}
	if err := verifyDeviceMutation(dev, req.Auth, "link", 0, req.Password); err != nil {
		httpError(w, http.StatusForbidden, err.Error())
		return
	}
	// req.DeviceName is ignored: device names travel only between the
	// account's own devices, end-to-end encrypted.
	deviceID, err := s.store.AllocateLinkedDevice(dev.AccountID, req.Password, req.Auth.ExpectedVersion)
	if errors.Is(err, store.ErrDeviceListVersionMismatch) {
		httpError(w, http.StatusConflict, "device list changed; refresh and try again")
		return
	}
	if errors.Is(err, store.ErrDeviceLimit) {
		httpError(w, http.StatusConflict, "linked device limit reached; unlink a device first")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"deviceId": deviceID})
	s.hub.BroadcastDeviceListChanged(dev.AccountID, dev.DeviceID, relaypb.DeviceListChanged_DEVICE_ADDED, deviceID)
}

func (s *Server) handleListDevices(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	devices, err := s.store.ListDevices(dev.AccountID)
	if err != nil {
		internalError(w, err)
		return
	}
	type jsonDevice struct {
		DeviceID  uint32 `json:"deviceId"`
		MailboxID string `json:"mailboxId,omitempty"`
		Name      string `json:"name,omitempty"`
		CreatedAt int64  `json:"createdAt,omitempty"`
	}
	out := make([]jsonDevice, len(devices))
	for i, d := range devices {
		out[i] = jsonDevice{DeviceID: d.DeviceID, MailboxID: d.MailboxID, Name: d.Name, CreatedAt: d.CreatedAt}
	}
	version, err := s.store.DeviceListVersion(dev.AccountID)
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": out, "deviceListVersion": version})
}

func (s *Server) handleRemoveDevice(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	id, err := strconv.ParseUint(r.PathValue("id"), 10, 32)
	if err != nil {
		httpError(w, http.StatusBadRequest, "bad device id")
		return
	}
	var req struct {
		Auth deviceMutationAuth `json:"auth"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "device mutation signature required")
		return
	}
	if err := verifyDeviceMutation(dev, req.Auth, "remove", uint32(id), ""); err != nil {
		httpError(w, http.StatusForbidden, err.Error())
		return
	}
	if _, err := s.store.RemoveDevice(dev.AccountID, uint32(id), req.Auth.ExpectedVersion); errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusNotFound, "no such device")
		return
	} else if errors.Is(err, store.ErrDeviceListVersionMismatch) {
		httpError(w, http.StatusConflict, "device list changed; refresh and try again")
		return
	} else if err != nil {
		internalError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
	s.hub.DisconnectDevice(dev.AccountID, uint32(id), "device removed")
	s.hub.BroadcastDeviceListChanged(dev.AccountID, dev.DeviceID, relaypb.DeviceListChanged_DEVICE_REMOVED, uint32(id))
}

type deviceMutationAuth struct {
	ExpectedVersion int64  `json:"expectedVersion"`
	SignerDeviceID  uint32 `json:"signerDeviceId"`
	Signature       b64    `json:"signature"`
}

func verifyDeviceMutation(dev *store.Device, auth deviceMutationAuth, action string, targetDeviceID uint32, password string) error {
	if auth.SignerDeviceID != dev.DeviceID {
		return errors.New("device mutation signer must match authenticated device")
	}
	if len(auth.Signature) == 0 {
		return errors.New("device mutation signature required")
	}
	if len(dev.AuthPublicKey) == 0 {
		return errors.New("device authorization key required")
	}
	x, y := elliptic.Unmarshal(elliptic.P256(), dev.AuthPublicKey)
	if x == nil || y == nil {
		return errors.New("invalid device authorization key")
	}
	publicKey := ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}
	digest := sha256.Sum256([]byte(deviceMutationPayload(dev.AccountID, auth.ExpectedVersion, action, targetDeviceID, password)))
	if !ecdsa.VerifyASN1(&publicKey, digest[:], auth.Signature) {
		return errors.New("invalid device mutation signature")
	}
	return nil
}

func deviceMutationPayload(accountID string, expectedVersion int64, action string, targetDeviceID uint32, password string) string {
	return strings.Join([]string{
		"relay-device-list-v1",
		accountID,
		strconv.FormatInt(expectedVersion, 10),
		action,
		strconv.FormatUint(uint64(targetDeviceID), 10),
		password,
	}, "\n")
}

func (s *Server) handleSetDeviceAuthKey(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		PublicKey b64 `json:"publicKey"`
	}
	if err := decodeJSON(r, &req); err != nil || len(req.PublicKey) == 0 {
		httpError(w, http.StatusBadRequest, "publicKey required")
		return
	}
	if len(req.PublicKey) > 512 {
		httpError(w, http.StatusBadRequest, "publicKey too large")
		return
	}
	x, y := elliptic.Unmarshal(elliptic.P256(), req.PublicKey)
	if x == nil || y == nil {
		httpError(w, http.StatusBadRequest, "publicKey is not a valid P-256 uncompressed point")
		return
	}
	if err := s.store.SetDeviceAuthKey(dev.AccountID, dev.DeviceID, req.PublicKey); err != nil {
		internalError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleGetDeviceAuthKey returns the auth public key of a device in the same
// account, so clients can verify nuke command signatures themselves.
func (s *Server) handleGetDeviceAuthKey(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	id, err := strconv.ParseUint(r.PathValue("id"), 10, 32)
	if err != nil {
		httpError(w, http.StatusBadRequest, "bad device id")
		return
	}
	key, err := s.store.DeviceAuthKey(dev.AccountID, uint32(id))
	if errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusNotFound, "no auth key for device")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"authPublicKey": base64.StdEncoding.EncodeToString(key)})
}

// validAPNsToken matches an APNs or PushKit device token: 64-200 hex chars,
// since Apple documents tokens as variable length. The token is spliced into
// the APNs request path.
var validAPNsToken = regexp.MustCompile(`^[0-9a-fA-F]{64,200}$`)

func (s *Server) handleSetAPNSToken(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Token string `json:"token"`
	}
	if err := decodeJSON(r, &req); err != nil || !validAPNsToken.MatchString(req.Token) {
		httpError(w, http.StatusBadRequest, "token must be 64–200 hex characters")
		return
	}
	if err := s.store.SetAPNSToken(dev.AccountID, dev.DeviceID, req.Token); err != nil {
		internalError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleSetFCMToken(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Token string `json:"token"`
	}
	if err := decodeJSON(r, &req); err != nil || req.Token == "" {
		httpError(w, http.StatusBadRequest, "token required")
		return
	}
	if err := s.store.SetFCMToken(dev.AccountID, dev.DeviceID, req.Token); err != nil {
		internalError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleSetVoIPToken(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Token string `json:"token"`
	}
	if err := decodeJSON(r, &req); err != nil || !validAPNsToken.MatchString(req.Token) {
		httpError(w, http.StatusBadRequest, "token must be 64–200 hex characters")
		return
	}
	if err := s.store.SetVoIPToken(dev.AccountID, dev.DeviceID, req.Token); err != nil {
		internalError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleSetPushContent records this device's push-content preference. By
// default pushes are content-free and the NSE fetches the envelope; when set,
// the encrypted envelope is embedded in the APNs payload.
func (s *Server) handleSetPushContent(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		IncludeContent bool `json:"includeContent"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if err := s.store.SetPushIncludeContent(dev.AccountID, dev.DeviceID, req.IncludeContent); err != nil {
		internalError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// validCallID bounds the opaque call id echoed into the push payload.
var validCallID = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)

// handleCallRing wakes the callee's devices for an incoming call. Like sealed
// sends it is unauthenticated: the caller presents the callee's access key for
// one of their mailboxes, so the relay never learns who is calling whom. The
// push carries only the call id; the caller's identity arrives in the
// encrypted offer, sent as a sealed message.
func (s *Server) handleCallRing(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !callRingIPLimiter.allow(ip) {
		httpError(w, http.StatusTooManyRequests, "rate limit exceeded; try again later")
		return
	}
	var req struct {
		DestinationMailbox string `json:"destinationMailbox"`
		AccessKey          string `json:"accessKey"`
		CallID             string `json:"callId"`
	}
	if err := decodeJSON(r, &req); err != nil || req.DestinationMailbox == "" ||
		!validCallID.MatchString(req.CallID) {
		httpError(w, http.StatusBadRequest, "destinationMailbox, accessKey and callId required")
		return
	}
	key, err := base64.StdEncoding.DecodeString(req.AccessKey)
	if err != nil {
		httpError(w, http.StatusBadRequest, "invalid access key")
		return
	}
	dest, ok := s.checkMailboxAccess(req.DestinationMailbox, key)
	if !ok {
		httpError(w, http.StatusForbidden, "ring rejected")
		return
	}
	// After the access check (see handleSealedSend). A ring is one push that
	// shows a call screen, so the budget is small: a few a minute, and a cap
	// per day so nobody can keep a phone ringing.
	if !callRingMailboxLimiter.allow(req.DestinationMailbox) || !callRingMailboxDailyLimiter.allow(req.DestinationMailbox) {
		httpError(w, http.StatusTooManyRequests, "rate limit exceeded; try again later")
		return
	}
	s.hub.PushCallToAccount(dest.AccountID, req.CallID)
	w.WriteHeader(http.StatusNoContent)
}

// handleUsernameAvailable reports whether a username is free, for sign-up and
// rename. It is unauthenticated and rate-limited per IP, and returns only a
// boolean so it can't map usernames to accounts. Comparison is
// case-insensitive, matching how uniqueness is enforced.
func (s *Server) handleUsernameAvailable(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !usernameLookupLimiter.allow(ip) {
		httpError(w, http.StatusTooManyRequests, "lookup rate limit exceeded; try again later")
		return
	}
	name := r.PathValue("name")
	if !validUsername.MatchString(name) {
		httpError(w, http.StatusBadRequest, "username must be 1–64 alphanumeric/._- characters")
		return
	}
	taken, err := s.store.UsernameTaken(name)
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"available": !taken})
}

// ---------------------------------------------------------------------------
// Attachments (opaque encrypted blobs)
// ---------------------------------------------------------------------------

// handleCreateAttachment allocates an attachment id, charged to the account's
// daily quota, and reserves it so the unauthenticated PUT can only write ids
// the relay handed out, once.
func (s *Server) handleCreateAttachment(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if s.attachmentDiskFull() {
		httpError(w, http.StatusInsufficientStorage, "attachment storage is full; try again later")
		return
	}
	id, err := s.blobs.NewID()
	if err != nil {
		internalError(w, err)
		return
	}
	if !s.attachQuota.allocate(dev.AccountID, id) {
		httpError(w, http.StatusTooManyRequests, "daily attachment quota exceeded; try again later")
		return
	}
	if err := s.blobs.Reserve(id); err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"id": id})
}

// countingReader counts bytes read through it.
type countingReader struct {
	r io.Reader
	n int64
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n += int64(n)
	return n, err
}

// handleUploadAttachment stores the ciphertext for a reserved id. It is
// unauthenticated (the 128-bit id is the capability) so the upload can't be
// tied to an account. An id that was never allocated, has expired, or was
// already written gets 404. Before anything is written the upload reserves its
// maximum size from the allocating account's byte budget (via the in-memory
// allocation record; ids allocated before a restart share one "unknown owner"
// budget) and from the disk watermark, so parallel uploads can't overrun
// either; the unused part is refunded afterwards.
func (s *Server) handleUploadAttachment(w http.ResponseWriter, r *http.Request) {
	if !attachmentIPLimiter.allow(clientIP(r)) {
		httpError(w, http.StatusTooManyRequests, "rate limit exceeded; try again later")
		return
	}
	// Checked before the reservation is claimed, so the client can retry the
	// same id once GC has freed space.
	if s.attachmentDiskFull() {
		httpError(w, http.StatusInsufficientStorage, "attachment storage is full; try again later")
		return
	}
	id := r.PathValue("id")
	owner, known := s.attachQuota.ownerKey(id, "")
	if !known {
		owner = unknownAttachmentOwner
	}
	reserved := attachmentUploadReservation(r)
	if !s.attachInFlight.reserve(reserved, s.blobs.Usage(), s.attachDiskCap) {
		httpError(w, http.StatusInsufficientStorage, "attachment storage is full; try again later")
		return
	}
	defer s.attachInFlight.release(reserved)
	if !s.attachQuota.reserveUpload(owner, reserved) {
		httpError(w, http.StatusTooManyRequests, "daily attachment quota exceeded; try again later")
		return
	}
	var stored int64
	defer func() { s.attachQuota.settleUpload(id, owner, reserved, stored) }()
	if err := s.blobs.Claim(id); err != nil {
		if errors.Is(err, blob.ErrNotFound) {
			httpError(w, http.StatusNotFound, "unknown or already-used attachment id")
			return
		}
		internalError(w, err)
		return
	}
	body := &countingReader{r: r.Body}
	err := s.blobs.Put(id, body)
	if err == nil {
		stored = body.n
	}
	switch {
	case errors.Is(err, blob.ErrTooLarge):
		httpError(w, http.StatusRequestEntityTooLarge, "attachment too large")
	case errors.Is(err, blob.ErrNotFound):
		httpError(w, http.StatusBadRequest, "bad attachment id")
	case err != nil:
		internalError(w, err)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

// handleDownloadAttachment streams the blob from disk with http.ServeContent,
// which handles Range requests so large downloads can resume. No Last-Modified
// is sent, to avoid disclosing the upload time. It is unauthenticated (the id,
// shared only inside encrypted content, is the capability) so downloads can't
// be linked to an account.
func (s *Server) handleDownloadAttachment(w http.ResponseWriter, r *http.Request) {
	if !attachmentIPLimiter.allow(clientIP(r)) {
		httpError(w, http.StatusTooManyRequests, "rate limit exceeded; try again later")
		return
	}
	f, err := s.blobs.Open(r.PathValue("id"))
	switch {
	case errors.Is(err, blob.ErrNotFound):
		httpError(w, http.StatusNotFound, "no such attachment")
	case err != nil:
		internalError(w, err)
	default:
		defer f.Close()
		w.Header().Set("Content-Type", "application/octet-stream")
		http.ServeContent(w, r, "", time.Time{}, f)
	}
}

// ---------------------------------------------------------------------------
// Group invites. The relay stores only opaque encrypted blobs and keeps no
// group state.
// ---------------------------------------------------------------------------

// handleCreateEncryptedGroupInvite stores an opaque encrypted invite blob and
// returns a token. The blob is decryptable only with the key in the invite URL
// fragment.
func (s *Server) handleCreateEncryptedGroupInvite(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if !groupCreateLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "too many invites; try again later")
		return
	}
	var req struct {
		Blob string `json:"blob"` // base64 ciphertext
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "invalid body")
		return
	}
	blob, err := base64.StdEncoding.DecodeString(req.Blob)
	if err != nil || len(blob) == 0 || len(blob) > 64*1024 {
		httpError(w, http.StatusBadRequest, "blob must be 1..65536 bytes (base64)")
		return
	}
	token, expiresAt, err := s.store.CreateEncryptedGroupInvite(blob)
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"token": token, "expiresAt": expiresAt})
}

// handleClaimEncryptedGroupInvite returns the opaque blob for a token so the
// redeemer can decrypt it with the fragment key. Tokens are multi-use until
// expiry. It is unauthenticated (the token is the capability) and rate-limited
// per IP, so the relay can't tell which account joined via which link.
func (s *Server) handleClaimEncryptedGroupInvite(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !inviteClaimIPLimiter.allow(ip) {
		httpError(w, http.StatusTooManyRequests, "too many join attempts; try again later")
		return
	}
	var req struct {
		Token string `json:"token"`
	}
	if err := decodeJSON(r, &req); err != nil || req.Token == "" {
		httpError(w, http.StatusBadRequest, "token required")
		return
	}
	blob, err := s.store.ClaimEncryptedGroupInvite(req.Token)
	if errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusNotFound, "invite not found or expired")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"blob": base64.StdEncoding.EncodeToString(blob)})
}

// ---------------------------------------------------------------------------
// Prekeys
// ---------------------------------------------------------------------------

type jsonSignedPreKey struct {
	KeyID     uint32 `json:"keyId"`
	PublicKey b64    `json:"publicKey"`
	Signature b64    `json:"signature"`
}

type jsonOneTimePreKey struct {
	KeyID     uint32 `json:"keyId"`
	PublicKey b64    `json:"publicKey"`
}

func (s *Server) handleSetKeys(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if !keyUploadLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "key upload rate limit exceeded; try again later")
		return
	}
	var req struct {
		RegistrationID uint32              `json:"registrationId"`
		IdentityKey    b64                 `json:"identityKey"`
		SignedPreKey   jsonSignedPreKey    `json:"signedPreKey"`
		KyberPreKey    jsonSignedPreKey    `json:"kyberPreKey"`
		OneTimePreKeys []jsonOneTimePreKey `json:"oneTimePreKeys"`
		// One-time Kyber prekeys, handed out instead of the last-resort key
		// while the pool lasts.
		OneTimeKyberPreKeys []jsonSignedPreKey `json:"oneTimeKyberPreKeys"`
		// Deletes the device's one-time pool before storing this batch (fresh
		// install, restore, or desync). Ordinary top-ups append.
		ReplaceOneTimePreKeys bool `json:"replaceOneTimePreKeys"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "malformed body: "+err.Error())
		return
	}
	if len(req.IdentityKey) == 0 || len(req.SignedPreKey.PublicKey) == 0 || len(req.SignedPreKey.Signature) == 0 ||
		len(req.KyberPreKey.PublicKey) == 0 || len(req.KyberPreKey.Signature) == 0 {
		httpError(w, http.StatusBadRequest, "identityKey, signedPreKey and kyberPreKey are required")
		return
	}
	if len(req.OneTimePreKeys) > maxOneTimePreKeysPerUpload {
		httpError(w, http.StatusBadRequest, "too many one-time prekeys in a single upload")
		return
	}
	if len(req.OneTimeKyberPreKeys) > maxOneTimeKyberPreKeysPerUpload {
		httpError(w, http.StatusBadRequest, "too many one-time Kyber prekeys in a single upload")
		return
	}
	kyberPool := make([]store.SignedPreKey, 0, len(req.OneTimeKyberPreKeys))
	for _, k := range req.OneTimeKyberPreKeys {
		if len(k.PublicKey) == 0 || len(k.Signature) == 0 {
			httpError(w, http.StatusBadRequest, "one-time Kyber prekeys need publicKey and signature")
			return
		}
		kyberPool = append(kyberPool, store.SignedPreKey{KeyID: k.KeyID, PublicKey: k.PublicKey, Signature: k.Signature})
	}
	spk := store.SignedPreKey{
		KeyID:     req.SignedPreKey.KeyID,
		PublicKey: req.SignedPreKey.PublicKey,
		Signature: req.SignedPreKey.Signature,
	}
	kyber := store.SignedPreKey{
		KeyID:     req.KyberPreKey.KeyID,
		PublicKey: req.KyberPreKey.PublicKey,
		Signature: req.KyberPreKey.Signature,
	}
	otks := make([]store.OneTimePreKey, 0, len(req.OneTimePreKeys))
	for _, k := range req.OneTimePreKeys {
		otks = append(otks, store.OneTimePreKey{KeyID: k.KeyID, PublicKey: k.PublicKey})
	}
	if err := s.store.SetKeysWithKyberPool(dev.AccountID, dev.DeviceID, req.RegistrationID, req.IdentityKey, spk, kyber, otks, kyberPool, req.ReplaceOneTimePreKeys); errors.Is(err, store.ErrPreKeyPoolFull) {
		httpError(w, http.StatusConflict, fmt.Sprintf("one-time prekey pool full (max %d, Kyber %d per device); upload fewer or set replaceOneTimePreKeys", store.MaxOneTimePreKeysPerDevice, store.MaxOneTimeKyberPreKeysPerDevice))
		return
	} else if err != nil {
		internalError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleKeyCount(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	n, err := s.store.OneTimePreKeyCount(dev.AccountID, dev.DeviceID)
	if err != nil {
		internalError(w, err)
		return
	}
	kn, err := s.store.OneTimeKyberPreKeyCount(dev.AccountID, dev.DeviceID)
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"count": n, "kyberCount": kn})
}

// handleGetKeys serves GET /v1/keys/{account}?device=N; without ?device it
// returns bundles for all of the account's devices. Each fetch consumes a
// one-time prekey if available; oneTimePreKey is null when the pool is empty.
func (s *Server) handleGetKeys(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	account := r.PathValue("account")
	if s.crossesDemoLine(dev.AccountID, account) {
		httpError(w, http.StatusNotFound, "unknown account/device or keys not yet uploaded")
		return
	}
	// Only cross-account fetches are limited, to stop prekey pool depletion.
	if dev.AccountID != account {
		if !preKeyFetchLimiter.allow(dev.AccountID + ":" + account) {
			httpError(w, http.StatusTooManyRequests, "prekey fetch rate limit exceeded; try again later")
			return
		}
	}
	var deviceIDs []uint32
	if q := r.URL.Query().Get("device"); q != "" {
		id, err := strconv.ParseUint(q, 10, 32)
		if err != nil {
			httpError(w, http.StatusBadRequest, "bad device id")
			return
		}
		deviceIDs = []uint32{uint32(id)}
	}
	// Cross-account only: once the target device's or the requester's hourly
	// one-time prekey budget is spent, bundles are served without one.
	var allowOneTime func(uint32) bool
	if dev.AccountID != account {
		allowOneTime = func(deviceID uint32) bool {
			return allowOneTimePreKey(dev.AccountID, account, deviceID)
		}
	}
	bundles, err := s.store.TakePreKeyBundles(account, deviceIDs, allowOneTime)
	if errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusNotFound, "unknown account/device or keys not yet uploaded")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}

	// Include the access key so the fetcher can send sealed to this account.
	accessKey, _ := s.store.AccessKey(account)
	writeKeyBundles(w, bundles, accessKey)
}

// handleGetKeysSealed serves prekey bundles to an anonymous caller holding the
// account's sealed-sender access key, so the relay can't record who fetches
// whose keys. Clients use it once they know the peer's access key; first
// contact uses the signed GET /v1/keys/{account}. Unknown account and wrong
// key get the same 403. Abuse is bounded per IP and by the target's one-time
// prekey budget.
func (s *Server) handleGetKeysSealed(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !sealedKeyFetchIPLimiter.allow(ip) {
		httpError(w, http.StatusTooManyRequests, "rate limit exceeded; try again later")
		return
	}
	account := r.PathValue("account")
	token, err := base64.StdEncoding.DecodeString(r.Header.Get("Relay-Access-Key"))
	if err != nil || len(token) != 32 {
		httpError(w, http.StatusForbidden, "not allowed")
		return
	}
	stored, err := s.store.AccessKey(account)
	if err != nil || len(stored) != 32 || subtle.ConstantTimeCompare(stored, token) != 1 {
		httpError(w, http.StatusForbidden, "not allowed")
		return
	}
	if !preKeyFetchLimiter.allow("sealed:" + ip + ":" + account) {
		httpError(w, http.StatusTooManyRequests, "prekey fetch rate limit exceeded; try again later")
		return
	}
	var deviceIDs []uint32
	if q := r.URL.Query().Get("device"); q != "" {
		id, err := strconv.ParseUint(q, 10, 32)
		if err != nil {
			httpError(w, http.StatusBadRequest, "bad device id")
			return
		}
		deviceIDs = []uint32{uint32(id)}
	}
	// Same one-time prekey budgets as the signed path, keyed by source IP.
	requester := "ip:" + ip
	allowOneTime := func(deviceID uint32) bool {
		return allowOneTimePreKey(requester, account, deviceID)
	}
	bundles, err := s.store.TakePreKeyBundles(account, deviceIDs, allowOneTime)
	if errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusNotFound, "unknown device or keys not yet uploaded")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	// The caller already holds the access key; don't echo it.
	writeKeyBundles(w, bundles, nil)
}

// allowOneTimePreKey decides whether a bundle for this target device may carry
// one-time prekeys. Each requester gets only a few per target per hour (a real
// sender needs one per new session), so one requester can't spend the
// target's whole hourly budget and leave real contacts with none.
func allowOneTimePreKey(requester, account string, deviceID uint32) bool {
	target := account + "/" + strconv.FormatUint(uint64(deviceID), 10)
	pair := requester + "|" + target
	if preKeyRequesterOTKLimiter.exhausted(requester) || preKeyPairOTKLimiter.exhausted(pair) {
		return false
	}
	if !preKeyTargetOTKLimiter.allow(target) {
		return false
	}
	preKeyPairOTKLimiter.allow(pair)
	return preKeyRequesterOTKLimiter.allow(requester)
}

// writeKeyBundles writes the GET /v1/keys response body.
func writeKeyBundles(w http.ResponseWriter, bundles []store.PreKeyBundle, accessKey []byte) {
	type jsonBundle struct {
		DeviceID       uint32             `json:"deviceId"`
		MailboxID      string             `json:"mailboxId,omitempty"`
		RegistrationID uint32             `json:"registrationId"`
		IdentityKey    b64                `json:"identityKey"`
		SignedPreKey   jsonSignedPreKey   `json:"signedPreKey"`
		KyberPreKey    jsonSignedPreKey   `json:"kyberPreKey"`
		OneTimePreKey  *jsonOneTimePreKey `json:"oneTimePreKey"`
	}
	out := struct {
		Devices   []jsonBundle `json:"devices"`
		AccessKey b64          `json:"accessKey,omitempty"`
	}{Devices: make([]jsonBundle, 0, len(bundles)), AccessKey: b64(accessKey)}
	for _, b := range bundles {
		jb := jsonBundle{
			DeviceID:       b.DeviceID,
			MailboxID:      b.MailboxID,
			RegistrationID: b.RegistrationID,
			IdentityKey:    b.IdentityKey,
			SignedPreKey: jsonSignedPreKey{
				KeyID:     b.SignedPreKey.KeyID,
				PublicKey: b.SignedPreKey.PublicKey,
				Signature: b.SignedPreKey.Signature,
			},
			KyberPreKey: jsonSignedPreKey{
				KeyID:     b.KyberPreKey.KeyID,
				PublicKey: b.KyberPreKey.PublicKey,
				Signature: b.KyberPreKey.Signature,
			},
		}
		if b.OneTime != nil {
			jb.OneTimePreKey = &jsonOneTimePreKey{KeyID: b.OneTime.KeyID, PublicKey: b.OneTime.PublicKey}
		}
		out.Devices = append(out.Devices, jb)
	}
	writeJSON(w, http.StatusOK, out)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// b64 marshals []byte as standard padded base64, the encoding for all binary
// fields in the REST API.
type b64 []byte

func (b b64) MarshalJSON() ([]byte, error) {
	return json.Marshal(base64.StdEncoding.EncodeToString(b))
}

func (b *b64) UnmarshalJSON(data []byte) error {
	var s string
	if err := json.Unmarshal(data, &s); err != nil {
		return err
	}
	raw, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return err
	}
	*b = raw
	return nil
}

var errTrailingJSON = errors.New("unexpected data after the JSON body")

// decodeJSON decodes exactly one JSON value from the request body into v and
// rejects trailing non-whitespace data, so a handler always acts on the whole
// body the request signature covered and not just a prefix of it.
func decodeJSON(r *http.Request, v any) error {
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(v); err != nil {
		return err
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return errTrailingJSON
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func httpError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func internalError(w http.ResponseWriter, err error) {
	slog.Error("internal error", "err", privlog.Error(err))
	httpError(w, http.StatusInternalServerError, "internal error")
}

// ---------------------------------------------------------------------------
// Account deletion and abuse reports
// ---------------------------------------------------------------------------

// handleDeleteAccount permanently deletes the account and all server-side data
// keyed to it (see store.DeleteAccount), then drops the account's WebSockets.
// Its username enters the reuse cooldown.
//
// The optional body {"appleAuthorizationCode": "..."} carries a fresh Sign in
// with Apple code used to revoke the user's Apple grant after deletion. This
// is best effort, and the code is never stored or logged.
func (s *Server) handleDeleteAccount(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		AppleAuthorizationCode string `json:"appleAuthorizationCode"`
	}
	if err := decodeJSON(r, &req); err != nil && !errors.Is(err, io.EOF) { // empty body = no code
		httpError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if len(req.AppleAuthorizationCode) > 4096 {
		httpError(w, http.StatusBadRequest, "appleAuthorizationCode too long")
		return
	}
	// A demo account is reset instead: devices, keys and queues go but the
	// login stays, so the credentials keep working for the next reviewer.
	if s.isDemo(dev.AccountID) {
		if _, err := s.store.ResetDemoAccount(dev.AccountID); err != nil {
			internalError(w, err)
			return
		}
		s.hub.DisconnectAccount(dev.AccountID, "account deleted")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	// Read the linked Supabase user before the row is gone.
	supabaseUserID, err := s.store.SupabaseUserID(dev.AccountID)
	if err != nil {
		internalError(w, err)
		return
	}
	if err := s.store.DeleteAccount(dev.AccountID); errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusNotFound, "no such account")
		return
	} else if err != nil {
		internalError(w, err)
		return
	}
	s.hub.DisconnectAccount(dev.AccountID, "account deleted")
	_ = s.deleteSupabaseUser(context.WithoutCancel(r.Context()), supabaseUserID) // best effort; logged
	if req.AppleAuthorizationCode != "" && s.appleRevoker != nil {
		ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), appleRevokeTimeout)
		if err := s.appleRevoker.RevokeAuthorizationCode(ctx, req.AppleAuthorizationCode); err != nil {
			slog.Warn("sign in with apple: token revocation failed", "err", privlog.Error(err))
		}
		cancel()
	}
	w.WriteHeader(http.StatusNoContent)
}

const (
	maxReportDetailsChars = 2000
	maxReportMessages     = 10
	maxReportMessageChars = 4000
)

var validReportReasons = map[string]bool{
	"spam":          true,
	"harassment":    true,
	"inappropriate": true,
	"impersonation": true,
	"other":         true,
}

// handleCreateReport stores an abuse report filed by the authenticated account
// against another account. messages holds plaintext the reporter chose to
// forward from the conversation; the relay otherwise never sees content.
func (s *Server) handleCreateReport(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		ReportedAccount string   `json:"reportedAccount"`
		Reason          string   `json:"reason"`
		Details         string   `json:"details"`
		Messages        []string `json:"messages"`
	}
	if err := decodeJSON(r, &req); err != nil || req.ReportedAccount == "" {
		httpError(w, http.StatusBadRequest, "reportedAccount and reason required")
		return
	}
	if !validReportReasons[req.Reason] {
		httpError(w, http.StatusBadRequest, "reason must be one of spam, harassment, inappropriate, impersonation, other")
		return
	}
	if utf8.RuneCountInString(req.Details) > maxReportDetailsChars {
		httpError(w, http.StatusBadRequest, "details too long (max 2000 characters)")
		return
	}
	if len(req.Messages) > maxReportMessages {
		httpError(w, http.StatusBadRequest, "too many messages (max 10)")
		return
	}
	for _, m := range req.Messages {
		if utf8.RuneCountInString(m) > maxReportMessageChars {
			httpError(w, http.StatusBadRequest, "message too long (max 4000 characters)")
			return
		}
	}
	if req.ReportedAccount == dev.AccountID {
		httpError(w, http.StatusBadRequest, "cannot report your own account")
		return
	}
	exists, err := s.store.AccountExists(req.ReportedAccount)
	if err != nil {
		internalError(w, err)
		return
	}
	if !exists {
		httpError(w, http.StatusNotFound, "no such account")
		return
	}
	// Only well-formed reports against real accounts count toward the cap.
	if !reportLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "report rate limit exceeded; try again later")
		return
	}
	if req.Messages == nil {
		req.Messages = []string{}
	}
	msgs, err := json.Marshal(req.Messages)
	if err != nil {
		internalError(w, err)
		return
	}
	if _, err := s.store.CreateReport(dev.AccountID, req.ReportedAccount, req.Reason, req.Details, string(msgs)); err != nil {
		internalError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------------------------------------------------------------------------
// Nuke (remote wipe / crypto-shred)
// ---------------------------------------------------------------------------

// handleNuke verifies, records and broadcasts a signed remote-wipe command.
// The server cannot forge one, and clients verify the signature themselves
// before wiping.
func (s *Server) handleNuke(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		CommandID          string `json:"commandId"`
		CreationTimeMs     int64  `json:"creationTimeMs"`
		InitiatingDeviceID uint32 `json:"initiatingDeviceId"`
		Signature          b64    `json:"signature"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "malformed nuke request")
		return
	}
	if req.CommandID == "" || len(req.Signature) == 0 {
		httpError(w, http.StatusBadRequest, "commandId and signature required")
		return
	}
	if req.InitiatingDeviceID != dev.DeviceID {
		httpError(w, http.StatusForbidden, "initiatingDeviceId must match authenticated device")
		return
	}
	// Limit the replay window.
	age := time.Since(time.UnixMilli(req.CreationTimeMs))
	if age > 5*time.Minute || age < -30*time.Second {
		httpError(w, http.StatusBadRequest, "nuke command timestamp out of acceptable range")
		return
	}
	if len(dev.AuthPublicKey) == 0 {
		httpError(w, http.StatusForbidden, "device authorization key not set")
		return
	}
	if err := verifyNukeSignature(dev.AuthPublicKey, dev.AccountID, req.CommandID, req.CreationTimeMs, req.InitiatingDeviceID, req.Signature); err != nil {
		httpError(w, http.StatusForbidden, "invalid nuke signature")
		return
	}
	rec := store.NukeRecord{
		AccountID:          dev.AccountID,
		CommandID:          req.CommandID,
		CreationTimeMs:     req.CreationTimeMs,
		InitiatingDeviceID: req.InitiatingDeviceID,
		Signature:          req.Signature,
	}
	if err := s.store.StoreNuke(rec); errors.Is(err, store.ErrDuplicateNukeCommand) {
		httpError(w, http.StatusConflict, "nuke command already executed")
		return
	} else if err != nil {
		internalError(w, err)
		return
	}
	nukeProto := &relaypb.NukeCommand{
		AccountId:          dev.AccountID,
		CommandId:          req.CommandID,
		CreationTimeMs:     req.CreationTimeMs,
		InitiatingDeviceId: req.InitiatingDeviceID,
		Signature:          req.Signature,
	}
	s.hub.BroadcastNuke(dev.AccountID, nukeProto)
	w.WriteHeader(http.StatusNoContent)
}

func nukeCanonicalPayload(accountID, commandID string, creationTimeMs int64, initiatingDeviceID uint32) string {
	return strings.Join([]string{
		"relay-nuke-v1",
		accountID,
		commandID,
		strconv.FormatInt(creationTimeMs, 10),
		strconv.FormatUint(uint64(initiatingDeviceID), 10),
	}, "\n")
}

func verifyNukeSignature(authPublicKey []byte, accountID, commandID string, creationTimeMs int64, initiatingDeviceID uint32, sig []byte) error {
	x, y := elliptic.Unmarshal(elliptic.P256(), authPublicKey)
	if x == nil || y == nil {
		return errors.New("invalid device authorization key")
	}
	publicKey := ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}
	payload := nukeCanonicalPayload(accountID, commandID, creationTimeMs, initiatingDeviceID)
	digest := sha256.Sum256([]byte(payload))
	if !ecdsa.VerifyASN1(&publicKey, digest[:], sig) {
		return errors.New("signature verification failed")
	}
	return nil
}

// ---------------------------------------------------------------------------
// TURN credentials (coturn REST API format, 1-hour TTL)
// ---------------------------------------------------------------------------

const turnTTL = 3600 // seconds

// handleTurnCredentials issues time-limited TURN credentials using coturn's
// REST API format: username "{expiry}:{random}", password HMAC-SHA1. It
// returns 404 if TURN is not configured.
func (s *Server) handleTurnCredentials(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if len(s.turnURLs) == 0 || s.turnSecret == "" {
		httpError(w, http.StatusNotFound, "TURN not configured on this server")
		return
	}
	if !turnCredentialLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "too many requests")
		return
	}
	expiry := time.Now().Unix() + turnTTL
	// The suffix is random rather than derived from the account, so the TURN
	// server and its logs can't tie relayed call traffic to an account.
	var nonce [8]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		internalError(w, err)
		return
	}
	username := strconv.FormatInt(expiry, 10) + ":" + hex.EncodeToString(nonce[:])
	mac := hmac.New(sha1.New, []byte(s.turnSecret))
	mac.Write([]byte(username))
	credential := base64.StdEncoding.EncodeToString(mac.Sum(nil))
	own := iceServer{URLs: s.turnURLs, Username: username, Credential: credential}
	// Hand out only our coturn while it is healthy, and only Cloudflare's TURN
	// when it is down or overloaded, so a struggling box gets no new
	// allocations. The legacy top-level fields follow the same choice.
	servers, legacy := []iceServer{own}, own
	// ?failed=1 means the client's call just lost its relay: probe our TURN
	// now instead of waiting for the background prober.
	down := s.turnHealth != nil && !s.turnHealth.Healthy()
	if !down && s.cfTURN != nil && s.turnHealth != nil && r.URL.Query().Get("failed") == "1" {
		down = !s.turnHealth.CheckNow()
	}
	if s.cfTURN != nil && down {
		if cf, err := s.cfTURN.generate(r.Context(), turnTTL); err == nil {
			servers, legacy = []iceServer{cf}, cf
		} else {
			slog.Error("turn: cloudflare failover unavailable", "err", privlog.Error(err))
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"urls":       legacy.URLs,
		"username":   legacy.Username,
		"credential": legacy.Credential,
		"ttl":        turnTTL,
		"iceServers": servers,
	})
}

// ---------------------------------------------------------------------------
// Rate limiters
// ---------------------------------------------------------------------------

// slidingWindowLimiter is a generic keyed sliding-window rate limiter.
type slidingWindowLimiter struct {
	mu      sync.Mutex
	windows map[string][]time.Time
	limit   int
	window  time.Duration
}

func newSlidingWindowLimiter(limit int, window time.Duration) *slidingWindowLimiter {
	l := &slidingWindowLimiter{windows: make(map[string][]time.Time), limit: limit, window: window}
	allLimiters = append(allLimiters, l)
	return l
}

func (l *slidingWindowLimiter) reset() {
	l.mu.Lock()
	l.windows = make(map[string][]time.Time)
	l.mu.Unlock()
}

func (l *slidingWindowLimiter) allow(key string) bool {
	key = limitkey.Hash(key) // never hold raw IPs or account ids in memory
	now := time.Now()
	l.mu.Lock()
	defer l.mu.Unlock()
	cutoff := now.Add(-l.window)
	// Build a fresh slice so the old backing array can be collected.
	var valid []time.Time
	for _, t := range l.windows[key] {
		if t.After(cutoff) {
			valid = append(valid, t)
		}
	}
	if len(valid) >= l.limit {
		l.windows[key] = valid
		return false
	}
	valid = append(valid, now)
	l.windows[key] = valid
	return true
}

// PruneStaleLimiterKeys removes limiter entries with no activity within their
// window. Call it periodically so one-off keys don't accumulate.
func (s *Server) PruneStaleLimiterKeys() {
	for _, l := range allLimiters {
		l.prune()
	}
	if s.attachQuota != nil {
		s.attachQuota.prune()
	}
	recoveryLockout.prune()
	oprfBudget.prune()
}

func (l *slidingWindowLimiter) prune() {
	l.mu.Lock()
	defer l.mu.Unlock()
	cutoff := time.Now().Add(-l.window)
	for key, times := range l.windows {
		if len(times) == 0 || !times[len(times)-1].After(cutoff) {
			delete(l.windows, key)
		}
	}
}

const (
	// maxProvisioningBlobBytes caps the device-linking payload, which is
	// normally a few KiB.
	maxProvisioningBlobBytes = 64 * 1024
	// maxGroupNameBytes caps group names, in UTF-8 bytes.
	maxGroupNameBytes = 512
	// maxGroupDescriptionBytes caps group descriptions.
	maxGroupDescriptionBytes = 4096
	// maxGroupMembers bounds message fan-out.
	maxGroupMembers = 256
	// maxPasswordBytes bounds bcrypt input.
	maxPasswordBytes = 1024
	// maxOneTimePreKeysPerUpload caps one-time prekeys per upload.
	maxOneTimePreKeysPerUpload = 200
	// maxOneTimeKyberPreKeysPerUpload caps one-time Kyber prekeys per upload.
	maxOneTimeKyberPreKeysPerUpload = 100
)

// 20 registrations per source IP per hour.
var accountCreationLimiter = newSlidingWindowLimiter(20, time.Hour)

// 200 prekey-bundle fetches per (requester, target) pair per hour, so one
// account can't drain another's one-time prekey pool. Own-account fetches are
// exempt.
var preKeyFetchLimiter = newSlidingWindowLimiter(200, time.Hour)

// 20 group creations per account per day.
var groupCreateLimiter = newSlidingWindowLimiter(20, 24*time.Hour)

// Unauthenticated contact and group invite claims per IP per hour, to bound
// token brute-forcing.
var inviteClaimIPLimiter = newSlidingWindowLimiter(60, time.Hour)

// Unauthenticated attachment GET/PUT per source IP per minute.
var attachmentIPLimiter = newSlidingWindowLimiter(600, time.Minute)

// Call rings are unauthenticated, so they are bounded per IP and per
// destination mailbox.
// turnCredentialLimiter bounds TURN credential requests per account. Each
// credential is good for an hour, so 60 an hour covers back-to-back calls
// with reconnects without handing one account an unbounded supply.
var turnCredentialLimiter = newSlidingWindowLimiter(60, time.Hour)

var callRingIPLimiter = newSlidingWindowLimiter(60, time.Minute)
var callRingMailboxLimiter = newSlidingWindowLimiter(6, time.Minute)
var callRingMailboxDailyLimiter = newSlidingWindowLimiter(100, 24*time.Hour)

// usernameLookupLimiter bounds username availability checks per IP per hour:
// enough for sign-up typing, too few for bulk probing.
var usernameLookupLimiter = newSlidingWindowLimiter(120, time.Hour)

// Sealed-sender delivery is unauthenticated, so it is also limited per IP and
// per destination mailbox (sealedSendMailboxLimiter).
var sealedSendIPLimiter = newSlidingWindowLimiter(600, time.Minute)

// accountStorageLimiter bounds encrypted chat-list writes per account.
var accountStorageLimiter = newSlidingWindowLimiter(120, time.Hour)

// sealedKeyFetchIPLimiter bounds anonymous key fetches per source IP.
var sealedKeyFetchIPLimiter = newSlidingWindowLimiter(300, time.Hour)
var sealedSendMailboxLimiter = newSlidingWindowLimiter(120, time.Minute)

// directoryLimiter bounds discovery requests (OPRF and bucket fetch) per
// account per hour. Requests are batched, so an address-book sync takes only a
// few.
var directoryLimiter = newSlidingWindowLimiter(200, time.Hour)

// directoryIPLimiter bounds bucket fetches per IP per hour.
var directoryIPLimiter = newSlidingWindowLimiter(400, time.Hour)

// maxDirectoryBatch caps elements/buckets per discovery request.
const maxDirectoryBatch = 1024

// oprfBudget meters OPRF evaluations per element, per account and per IP per
// day: enough to sync a large address book, far too few to enumerate
// identifiers.
var oprfBudget = newElementBudget(map[string]budgetSpec{
	"acct:": {capacity: 5000, period: 24 * time.Hour},
	"ip:":   {capacity: 20000, period: 24 * time.Hour},
})

// 100 key uploads per account per hour.
var keyUploadLimiter = newSlidingWindowLimiter(100, time.Hour)

// 10 provisioning sessions per IP per 10 minutes.
var provisioningLimiter = newSlidingWindowLimiter(10, 10*time.Minute)

// 20 abuse reports per account per rolling 24 hours.
var reportLimiter = newSlidingWindowLimiter(20, 24*time.Hour)

type ipRateLimiter = slidingWindowLimiter

// validUsername allows only ASCII letters, digits, dots, underscores and
// hyphens, which rules out non-ASCII lookalike characters.
var validUsername = regexp.MustCompile(`^[a-zA-Z0-9._\-]{1,64}$`)
