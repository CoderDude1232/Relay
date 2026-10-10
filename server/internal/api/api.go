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
	store      *store.Store
	hub        *hub.Hub
	blobs      *blob.Store
	turnURLs   []string // empty = TURN not configured
	turnSecret string
	turnHealth *TURNHealth     // nil = no failover
	cfTURN     *CloudflareTURN // nil = no failover

	// Supabase social-login verification. When supabaseURL is set, the OAuth
	// account endpoint verifies a user's Supabase access token by asking
	// Supabase who it belongs to (server-to-server GET /auth/v1/user), then
	// trusts the returned id/email. verifySupabaseToken is a field so tests can
	// stub it without hitting the network.
	supabaseURL     string
	supabaseAnonKey string
	// supabaseServiceKey (service-role) lets account deletion also delete the
	// user's Supabase auth record, which holds their email. Optional.
	supabaseServiceKey  string
	verifySupabaseToken func(ctx context.Context, accessToken string) (supabaseUser, error)

	// Sealed-sender certificate issuance. When set, GET /v1/certificate/delivery
	// mints a libsignal-compatible sender certificate for the authenticated device.
	sealed *sealedIssuer

	// Blinded discovery. When set, the directory endpoints evaluate the OPRF and
	// resolve tokens; the server (re)builds the directory index under this key.
	oprf *oprf.Key

	// Per-account attachment upload budgets (count/day at allocation,
	// bytes/day at upload).
	attachQuota *attachmentQuota

	// attachDiskCap is the global attachment disk watermark: once the blob
	// directory holds this many bytes, new allocations and uploads get 507
	// until GC frees space. 0 = unlimited.
	attachDiskCap int64

	// appleRevoker, when set, revokes the user's Sign in with Apple grant on
	// account deletion (see handleDeleteAccount). nil = not configured.
	appleRevoker AppleRevoker
}

// AppleRevoker exchanges a Sign in with Apple authorization code for the
// user's tokens and revokes them (implemented by siwa.Revoker).
type AppleRevoker interface {
	RevokeAuthorizationCode(ctx context.Context, code string) error
}

// SetAppleRevoker enables Sign in with Apple token revocation on account
// deletion.
func (s *Server) SetAppleRevoker(r AppleRevoker) { s.appleRevoker = r }

// appleRevokeTimeout bounds the whole exchange + revoke on account deletion.
const appleRevokeTimeout = 10 * time.Second

// DefaultAttachmentDiskCap is the default global attachment disk watermark.
const DefaultAttachmentDiskCap = 20 << 30 // 20 GiB

// SetAttachmentDiskCap sets the global attachment disk watermark in bytes
// (0 disables it).
func (s *Server) SetAttachmentDiskCap(bytes int64) { s.attachDiskCap = bytes }

// attachmentDiskFull reports whether the blob directory is at its watermark.
func (s *Server) attachmentDiskFull() bool {
	return s.attachDiskCap > 0 && s.blobs.Usage() >= s.attachDiskCap
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
		attachDiskCap: DefaultAttachmentDiskCap}
	s.verifySupabaseToken = s.verifySupabaseTokenHTTP
	return s
}

// SetAttachmentQuota sets the per-account daily attachment upload budgets:
// total ciphertext bytes and number of allocations per rolling day.
func (s *Server) SetAttachmentQuota(dailyBytes int64, dailyCount int) {
	s.attachQuota = newAttachmentQuota(dailyBytes, dailyCount)
}

// SetSupabaseAuth enables the social-login account endpoint by pointing the
// server at a Supabase project. projectURL is the base (e.g.
// https://xxxx.supabase.co); anonKey is the project's anon API key, required as
// the apikey header on GoTrue calls.
// SetSupabaseServiceKey enables deleting the Supabase auth user when its
// relay account is deleted. Requires SetSupabaseAuth for the project URL.
func (s *Server) SetSupabaseServiceKey(key string) {
	s.supabaseServiceKey = strings.TrimSpace(key)
}

// deleteSupabaseUser removes a Supabase auth user via the admin API. Best
// effort: the relay account is already gone, so failures are only logged.
func (s *Server) deleteSupabaseUser(ctx context.Context, userID string) {
	if s.supabaseURL == "" || s.supabaseServiceKey == "" || userID == "" {
		return
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete,
		s.supabaseURL+"/auth/v1/admin/users/"+url.PathEscape(userID), nil)
	if err != nil {
		slog.Error("supabase user delete: request", "err", privlog.Error(err))
		return
	}
	req.Header.Set("apikey", s.supabaseServiceKey)
	req.Header.Set("Authorization", "Bearer "+s.supabaseServiceKey)
	resp, err := supabaseHTTPClient.Do(req)
	if err != nil {
		slog.Error("supabase user delete failed", "err", privlog.Error(err))
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusNotFound {
		slog.Error("supabase user delete failed", "status", resp.StatusCode)
	}
}

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

// SetOPRF enables blinded discovery under the given OPRF key and rebuilds the
// directory index from the current accounts (so existing users are discoverable
// and any drift is corrected on restart). It also enables the username reuse
// cooldown (see store.UsernameReuseCooldown).
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

// directoryEntries computes the OPRF token rows for an account's username/email,
// each with its bucket, match tag and a box sealing (accountId, username) under
// a key derived from the token — so a bucket fetch is a plain read and only a
// client that already holds the token can recognise or open its entry.
func (s *Server) directoryEntries(a store.AccountDirInfo) []store.DirectoryEntry {
	var entries []store.DirectoryEntry
	add := func(token []byte, kind int16) {
		box, err := oprf.SealDirectoryEntry(token, a.AccountID, a.Username)
		if err != nil {
			slog.Error("directory: seal entry failed", "err", privlog.Error(err))
			return
		}
		entries = append(entries, store.DirectoryEntry{
			Token: token, AccountID: a.AccountID, Kind: kind,
			Bucket: oprf.DirectoryBucket(token), Tag: oprf.DirectoryTag(token), Box: box,
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

// emailToken derives the OPRF-keyed token we store in place of a plaintext
// email. Returns nil when there's no email or OPRF isn't configured (in which
// case email-based features degrade rather than storing anything sensitive).
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
	// Reversed device linking (shared account identity). The new device creates
	// a blind provisioning session and shows a QR; the primary scans it, creates
	// the device, and drops an encrypted payload the new device polls for.
	// Top-level path (NOT under /v1/devices/) so the `{id}` wildcard doesn't
	// collide with GET /v1/devices/{id}/auth-key — Go 1.22's mux rejects such
	// ambiguous patterns at registration.
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
	mux.HandleFunc("GET /v1/keys/{account}/sealed", s.handleGetKeysSealed) // unauthenticated by design (access-key capability)
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
// "<accountID>.<deviceID>" is accepted on exactly one route — the bootstrap
// PUT /v1/devices/auth-key (wrapped with bootstrapAuth) — and only for a
// device that has not registered an auth key yet.
// ---------------------------------------------------------------------------

type authedHandler func(w http.ResponseWriter, r *http.Request, dev *store.Device)

// auth requires a Relay-Sig signature.
func (s *Server) auth(next authedHandler) http.HandlerFunc { return s.authenticate(false, next) }

// bootstrapAuth additionally accepts HTTP Basic, for the one-time upload of a
// new device's auth key (which it has no other way to prove itself for).
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
		// Failed-auth throttling: a source that keeps failing is cut off before
		// any bcrypt / signature work is done (see authFailIPLimiter).
		ip := clientIP(r)
		if authFailIPLimiter.exhausted(ip) {
			httpError(w, http.StatusTooManyRequests, "too many failed authentication attempts; try again later")
			return
		}
		// Preferred: signature auth (proves possession of the device's auth private
		// key without sending a reusable secret).
		if strings.HasPrefix(r.Header.Get("Authorization"), sigAuthScheme+" ") {
			dev, err := s.authenticateSignature(r)
			if errors.Is(err, errNonceBudget) {
				// A valid signature from a device over its replay-cache budget.
				httpError(w, http.StatusTooManyRequests, errNonceBudget.Error())
				return
			}
			if err != nil {
				authFailIPLimiter.allow(ip)
				httpError(w, http.StatusUnauthorized, "signature authentication failed")
				return
			}
			next(w, r, dev)
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
		// Basic is a bootstrap credential only: once a device has registered an
		// auth key it must sign every request, so a leaked device password alone
		// can no longer act as the device (or swap its auth key — rotating the key
		// therefore requires a Relay-Sig request signed by the old key).
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
	// Rate limit: 20 registrations per source IP per hour.
	ip := clientIP(r)
	if !accountCreationLimiter.allow(ip) {
		httpError(w, http.StatusTooManyRequests, "registration rate limit exceeded; try again later")
		return
	}
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
		// Optional Supabase access token. When present the relay asks Supabase
		// who it belongs to and links the account to that user; the email is
		// kept (as its OPRF token) ONLY if Supabase reports it confirmed. A raw
		// client-supplied email is never accepted — that let anyone pre-claim
		// someone else's address (account pre-hijack via recovery/OAuth adoption).
		SupabaseAccessToken string `json:"supabaseAccessToken"`
		AccountPassword     string `json:"accountPassword"`
		Email               string `json:"email"` // rejected; see above
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
	if req.AccountPassword != "" && (len(req.AccountPassword) < 8 || len(req.AccountPassword) > maxPasswordBytes) {
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
	accountID, deviceID, err := s.store.CreateAccount(req.Username, emailToken, supabaseUserID, req.Password, req.AccountPassword)
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
	s.reindexAccount(accountID) // make the new user discoverable immediately
	writeJSON(w, http.StatusCreated, map[string]any{"accountId": accountID, "deviceId": deviceID, "mailboxId": mailboxID})
}

// errSignInInstead is the one response for "this sign-in identity can't create
// a new account" — it never says whether (or which) account exists.
const errSignInInstead = "could not create an account with this sign-in; sign in instead"

// handleOAuthAccount signs a Supabase-authenticated user into their relay
// account, creating it on first use, and provisions a fresh device. The request
// carries the user's Supabase access token, which the server verifies directly
// with Supabase; the returned id/email are authoritative. An existing account
// is adopted by email only when Supabase reports the email confirmed (and the
// relay only ever stores confirmed emails).
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
		AccessToken     string `json:"accessToken"`
		Username        string `json:"username"`
		Password        string `json:"password"`
		AccountPassword string `json:"accountPassword"`
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
	if req.AccountPassword != "" && (len(req.AccountPassword) < 8 || len(req.AccountPassword) > maxPasswordBytes) {
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
		user.ID, emailToken, req.Username, req.Password, req.AccountPassword,
		func(accountID string) bool { return recoveryLockout.permit(registrationLockKey(accountID)) })
	switch {
	case errors.Is(err, store.ErrAccountPasswordLocked):
		httpError(w, http.StatusTooManyRequests, "too many account password attempts; try again later")
		return
	case errors.Is(err, store.ErrAccountPasswordRequired):
		httpError(w, http.StatusLocked, "account password required")
		return
	case errors.Is(err, store.ErrAccountPasswordIncorrect):
		recoveryLockout.fail(registrationLockKey(dev.AccountID))
		httpError(w, http.StatusLocked, "account password incorrect")
		return
	case errors.Is(err, store.ErrUsernameRequired):
		// No account exists yet for this user and no username was supplied.
		// Signal the client to prompt for one and retry.
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

	if !created && req.AccountPassword != "" {
		recoveryLockout.succeed(registrationLockKey(dev.AccountID))
	}
	status := http.StatusOK
	if created {
		status = http.StatusCreated
		s.reindexAccount(dev.AccountID) // index the new social-login user for discovery
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

// retireReplacedDevices tells each device a fresh sign-in/recovery replaced
// that it was removed (so a still-running app signs itself out), then drops
// its socket. Its rows are already gone, so its credentials no longer work.
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

// verifySupabaseTokenHTTP asks Supabase who an access token belongs to via a
// server-to-server GET /auth/v1/user. Returns the authoritative user id, email
// and whether that email has been confirmed (email_confirmed_at, or
// confirmed_at for an email-only user).
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
// mailbox (or an account with no access key), so the comparison work is the
// same either way. Random per process; it can never match because a known
// mailbox's real key is used instead and an unknown one is rejected regardless.
var sealedDummyAccessKey = func() (k [32]byte) {
	if _, err := rand.Read(k[:]); err != nil {
		panic("api: crypto/rand failed: " + err.Error())
	}
	return k
}()

// handleSealedSend delivers a sealed-sender message. It is UNAUTHENTICATED by
// design — the relay must not learn who sent the message. The sender proves it's
// allowed to reach the destination by presenting the recipient's access key
// (obtained with the prekey bundle); the server verifies it in constant time
// without learning the sender's identity. The delivered envelope carries no
// sender fields; the recipient recovers the sender by decrypting the sealed blob.
func (s *Server) handleSealedSend(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !sealedSendIPLimiter.allow(ip) {
		httpError(w, http.StatusTooManyRequests, "rate limit exceeded; try again later")
		return
	}
	// No client timestamp is accepted: a sender clock on the wire is a
	// clock-offset fingerprint that could link anonymous sends to one device.
	// Timestamps that matter (ordering, receipts) live inside the encrypted
	// content; the envelope carries only the relay's receive time.
	var req struct {
		MailboxID string `json:"mailboxId"`
		Type      int32  `json:"type"`
		Content   string `json:"content"`   // base64 sealed blob
		AccessKey string `json:"accessKey"` // base64, recipient's access key
		Ephemeral bool   `json:"ephemeral"`
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
	if !sealedSendMailboxLimiter.allow(req.MailboxID) {
		httpError(w, http.StatusTooManyRequests, "rate limit exceeded; try again later")
		return
	}
	dest, ok := s.checkMailboxAccess(req.MailboxID, token)
	if !ok {
		httpError(w, http.StatusForbidden, "delivery rejected")
		return
	}

	now := time.Now().UnixMilli()
	env := &relaypb.Envelope{
		Id: newEnvelopeID(),
		// SenderAccount / SenderDevice intentionally left empty: the relay does
		// not know who sent a sealed message. The recipient recovers the sender
		// from the sealed blob.
		Type:            relaypb.CiphertextType(req.Type),
		Content:         content,
		ClientTimestamp: now, // server-stamped, never the sender's clock
		ServerTimestamp: now,
		Ephemeral:       req.Ephemeral,
	}
	// Queue fairness for an anonymous sender is keyed by its source-IP bucket.
	if err := s.hub.DeliverFrom("ip:"+ip, dest.AccountID, dest.DeviceID, env); err != nil {
		if errors.Is(err, hub.ErrSenderQuota) || errors.Is(err, store.ErrQueueFull) {
			httpError(w, http.StatusTooManyRequests, "rate limit exceeded; try again later")
			return
		}
		if errors.Is(err, store.ErrNotFound) {
			// The device vanished after the access check: same answer as an
			// unknown mailbox.
			httpError(w, http.StatusForbidden, "delivery rejected")
			return
		}
		slog.Error("sealed send: deliver failed", "err", privlog.Error(err))
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"serverTimestamp": env.ServerTimestamp})
}

// checkMailboxAccess is the unauthenticated-path capability check shared by
// sealed sends and call rings: the presented key must equal the access key of
// the account owning the mailbox. Any failure is the same false result and
// takes the same path — one query either way, and the constant-time comparison
// always runs (against a random dummy key when the mailbox or its key is
// unknown) — so a caller can't tell an unknown mailbox from a wrong key.
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

// handleFetchQueue returns this device's currently-queued envelopes over the
// (HTTP/3-capable) REST plane. Used as a QUIC fallback for receiving when the
// TCP WebSocket can't connect (congested networks / stadiums). Does not dequeue
// — the client acks each envelope via POST /v1/messages/ack, preserving
// at-least-once delivery. The WebSocket stays the primary live path.
//
// Paged: `?limit=N` (1–100, default 100) caps the envelope count, and a page
// also stops once it holds 4 MiB of ciphertext. The response carries
// `more` (bool) and, when more is true, an opaque `cursor`; pass it back as
// `?cursor=` to read the next page. Acking is independent of paging.
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

// handleAckMessage removes a delivered envelope from this device's queue (the
// REST equivalent of the WebSocket AckRequest).
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

// handleSetAccessKey stores this account's sealed-sender access key (32 bytes).
// The client uploads it once (and on rotation); senders present it on the
// unauthenticated delivery path.
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
	w.WriteHeader(http.StatusNoContent)
}

// handleRotateMailbox assigns the authenticated device a fresh mailbox id and
// returns it. The relay never rotates mailboxes on its own (ids are stable);
// this exists only for an explicit client request (e.g. after a suspected
// mailbox-id leak). Peers pick up the new id on their next bundle fetch, and
// sealed sends to the stale id fail-and-retry.
func (s *Server) handleRotateMailbox(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	mailboxID, err := s.store.RotateMailbox(dev.AccountID, dev.DeviceID)
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"mailboxId": mailboxID})
}

// handleDirectoryOPRF evaluates the OPRF over a batch of client-blinded elements
// (returns E = k·B for each). The server learns nothing about the identifiers
// the client is querying — only opaque curve points cross the wire. Every
// evaluated element spends one unit of a per-account and a per-IP daily budget,
// so the oracle can't be driven to enumerate identifiers offline.
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
// 16-bit buckets. The client derives bucket(t) from each OPRF token t locally
// and sends only that; tokens never leave the device. Each entry is a match
// tag plus a box only a holder of the token can open, so the relay learns at
// most which buckets were requested — not which identifiers, nor which matched.
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
	rows, err := s.store.DirectoryBuckets(buckets)
	if err != nil {
		internalError(w, err)
		return
	}
	type entry struct {
		Tag b64 `json:"tag"`
		Box b64 `json:"box"`
	}
	type bucket struct {
		Bucket  uint16  `json:"bucket"`
		Entries []entry `json:"entries"`
	}
	byBucket := make(map[uint16][]entry, len(buckets))
	for _, e := range rows {
		byBucket[e.Bucket] = append(byBucket[e.Bucket], entry{Tag: e.Tag, Box: e.Box})
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
// authenticated device, binding its account id, device id, and stored identity
// key with a 7-day expiry. The client uses it to send sealed-sender messages.
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
	// The relay-attested username travels inside the certificate, so
	// recipients learn who wrote without asking the relay about the sender.
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
// inviter's account id and username. Single-use: the row is deleted on claim,
// so a second claim returns 404. UNAUTHENTICATED — the token is the capability
// — so the relay can't record which account redeemed whose invite.
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

// handleRecoverAccount provisions a new device for the account whose verified
// email matches, given its recovery password. Every recovery failure (unknown
// email, no recovery password, wrong password) gets the same 401 after the
// same bcrypt work, and repeated failures for one email back off
// exponentially — applied identically whether or not the email is registered,
// so neither status, timing nor lockout reveals account existence.
// passwordResetWindow bounds how old the Supabase recovery sign-in may be.
const passwordResetWindow = 15 * time.Minute

// handlePasswordReset is "forgot password". The client proves control of the
// account's verified email with a Supabase session minted by a password-
// recovery code (amr "recovery", within passwordResetWindow) — an ordinary
// social or password session is NOT enough, so a stolen session can't be used
// to get past the account-password lock. The account gets the new account
// password and, like any fresh sign-in, its devices are replaced by this one.
func (s *Server) handlePasswordReset(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !accountCreationLimiter.allow("reset:" + ip) {
		httpError(w, http.StatusTooManyRequests, "password reset rate limit exceeded; try again later")
		return
	}
	var req struct {
		AccessToken     string `json:"accessToken"`
		AccountPassword string `json:"accountPassword"`
		Password        string `json:"password"`
	}
	if err := decodeJSON(r, &req); err != nil || req.AccessToken == "" ||
		len(req.AccountPassword) < 8 || len(req.AccountPassword) > maxPasswordBytes ||
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
	dev, err := s.store.ResetAccountPassword(user.ID, s.emailToken(user.Email), req.AccountPassword, req.Password)
	switch {
	case errors.Is(err, store.ErrAccountNotFound):
		httpError(w, http.StatusNotFound, "no Relay account for this email")
		return
	case errors.Is(err, store.ErrIdentityInUse):
		httpError(w, http.StatusConflict, errSignInInstead)
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

// handleUpdateEmail runs after the user confirmed a new email with Supabase:
// the client sends its (now updated) Supabase session, the relay checks it
// belongs to this account's linked Supabase user and that the new email is
// confirmed, then re-keys the account's email token (recovery and the opt-in
// email discovery follow the new address).
func (s *Server) handleUpdateEmail(w http.ResponseWriter, r *http.Request, dev *store.Device) {
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
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleRecoverAccount(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !accountCreationLimiter.allow("recover:" + ip) {
		httpError(w, http.StatusTooManyRequests, "recovery rate limit exceeded; try again later")
		return
	}
	var req struct {
		Email           string `json:"email"`
		AccountPassword string `json:"accountPassword"`
	}
	if err := decodeJSON(r, &req); err != nil || req.Email == "" || req.AccountPassword == "" ||
		len(req.AccountPassword) > maxPasswordBytes {
		httpError(w, http.StatusBadRequest, "email and accountPassword required")
		return
	}
	token := s.emailToken(req.Email)
	if token == nil {
		httpError(w, http.StatusServiceUnavailable, "email recovery unavailable")
		return
	}
	lockKey := hex.EncodeToString(token)
	if !recoveryLockout.permit(lockKey) {
		httpError(w, http.StatusTooManyRequests, "too many recovery attempts; try again later")
		return
	}
	dev, devicePassword, err := s.store.RecoverAccount(token, req.AccountPassword)
	switch {
	case errors.Is(err, store.ErrAuthFailed):
		recoveryLockout.fail(lockKey)
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
	s.reindexAccount(dev.AccountID)            // update the blinded directory for the new username
	w.WriteHeader(http.StatusNoContent)
}

// handleSetDiscoverability sets whether the account's verified email gets a
// blinded-directory entry (opt-in; off by default) and reindexes the account.
// Username entries are unaffected. Body: {"email": bool} — the field is required.
func (s *Server) handleSetDiscoverability(w http.ResponseWriter, r *http.Request, dev *store.Device) {
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

// handleSetAccountPassword sets or changes the account password, which guards
// email recovery and the sign-in registration lock. Any signed device of the
// account may set it (such a device already controls the account).
func (s *Server) handleSetAccountPassword(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		AccountPassword string `json:"accountPassword"`
	}
	if err := decodeJSON(r, &req); err != nil ||
		len(req.AccountPassword) < 8 || len(req.AccountPassword) > maxPasswordBytes {
		httpError(w, http.StatusBadRequest, "accountPassword (8–1024 chars) required")
		return
	}
	if !accountPasswordLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "too many account password changes; try again later")
		return
	}
	if err := s.store.SetAccountPassword(dev.AccountID, req.AccountPassword); err != nil {
		internalError(w, err)
		return
	}
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

// handleCreateProvisioningSession mints a blind mailbox for the reversed
// linking flow. Unauthenticated: the new device has no account yet.
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
// payload. 204 while it's not there yet, 404 once expired/consumed.
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
		w.WriteHeader(http.StatusNoContent) // not provisioned yet; keep polling
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"blob": blob})
}

// handleStoreProvisioning lets the primary deposit the encrypted payload for a
// session. Authenticated so only a real account device can write; the payload
// itself is end-to-end encrypted to the new device's ephemeral key.
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

// handleLinkDevice creates a new device row for the primary's account using a
// primary-supplied password, bound into the device-mutation signature. The
// reversed-flow replacement for the invitation/claim round-trip: the QR scan is
// the trust anchor, so there is no separate verification code.
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
	// req.DeviceName is accepted for older clients but ignored: device names
	// travel only between the account's own devices, end-to-end encrypted.
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
	// Like every other add path, tell the account's live devices.
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
	// The removed device's credentials are gone; drop its live socket too.
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
	// Validate that the bytes represent a valid, uncompressed P-256 public key
	// before persisting. elliptic.Unmarshal returns nil on invalid input.
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

// handleGetDeviceAuthKey returns the auth public key for any device in the same
// account. Used by clients to independently verify nuke command signatures.
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

// validAPNsToken matches an APNs / PushKit device token: hex, 64–200 chars
// (32 bytes today; Apple documents tokens as variable length). Anything else
// would only be spliced into the APNs request path.
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

// handleSetPushContent records this device's push-content preference: false
// (default) = content-free wake, the NSE fetches the envelope; true = embed the
// encrypted envelope in the APNs payload for a faster, slightly less private wake.
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

// handleCallRing wakes the callee's devices for an incoming call. It is
// UNAUTHENTICATED by design, exactly like sealed sends: the caller proves it
// may reach the callee by presenting the callee's access key for one of their
// mailboxes, so the relay never learns who is calling whom. Unknown mailbox
// and wrong key get the identical 403. The push carries only the call id; the
// caller's identity reaches the callee solely inside the E2E-encrypted offer
// (delivered as a sealed message).
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
	if !callRingMailboxLimiter.allow(req.DestinationMailbox) {
		httpError(w, http.StatusTooManyRequests, "rate limit exceeded; try again later")
		return
	}
	dest, ok := s.checkMailboxAccess(req.DestinationMailbox, key)
	if !ok {
		httpError(w, http.StatusForbidden, "ring rejected")
		return
	}
	s.hub.PushCallToAccount(dest.AccountID, req.CallID)
	w.WriteHeader(http.StatusNoContent)
}

// handleUsernameAvailable answers "is this username free?" for sign-up and
// rename. Unauthenticated (new users have no credentials) and rate-limited per
// source IP. It returns only a boolean — never an account id — so it can't be
// used to map usernames to accounts; comparison is case-insensitive, matching
// how uniqueness is enforced.
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

// handleCreateAttachment allocates an attachment id for the authenticated
// device (charged to its daily attachment quota) and records it as reserved,
// so the (unauthenticated) PUT can only write ids the relay handed out, once.
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

// countingReader counts bytes read through it (attachment byte quota).
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
// UNAUTHENTICATED: the unguessable 128-bit id is the capability, so the upload
// can't be tied to the uploader's account. Write-once: an id that was never
// allocated, has expired, or was already written gets 404. Bytes are charged
// to the allocating account's quota via the in-memory allocation record.
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
	if known && !s.attachQuota.uploadAllowed(owner) {
		httpError(w, http.StatusTooManyRequests, "daily attachment quota exceeded; try again later")
		return
	}
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
	if known && body.n > 0 {
		s.attachQuota.charge(id, owner, body.n)
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

// handleDownloadAttachment streams the blob from disk (never buffering it in
// memory) via http.ServeContent, which also serves Range requests so large
// downloads can resume. No Last-Modified is sent: the upload time is not
// disclosed. UNAUTHENTICATED: knowing the id (shared only inside E2E-encrypted
// content) is the capability, so downloads can't be linked to an account.
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
// Group invites (relay stores only opaque encrypted blobs; groups are fully
// client-managed — the server keeps no roster, name, admin, or membership state)
// ---------------------------------------------------------------------------

// handleCreateEncryptedGroupInvite stores an opaque encrypted invite blob and
// returns a token. The relay never learns the group id, name, or roster — the
// blob is decryptable only with the key carried in the invite URL fragment.
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
// redeemer can decrypt it client-side with the fragment key. Multi-use until
// expiry. UNAUTHENTICATED — the token is the capability — and rate-limited per
// source IP, so the relay can't tell which account joined via which link.
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
		// When true, the device's existing one-time pool is deleted before this
		// batch is stored (fresh install/restore or desync heal). Defaults false
		// so ordinary top-ups keep appending.
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
	if err := s.store.SetKeys(dev.AccountID, dev.DeviceID, req.RegistrationID, req.IdentityKey, spk, kyber, otks, req.ReplaceOneTimePreKeys); errors.Is(err, store.ErrPreKeyPoolFull) {
		httpError(w, http.StatusConflict, fmt.Sprintf("one-time prekey pool full (max %d per device); upload fewer or set replaceOneTimePreKeys", store.MaxOneTimePreKeysPerDevice))
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
	writeJSON(w, http.StatusOK, map[string]any{"count": n})
}

// GET /v1/keys/{account}?device=N — omit ?device to fetch bundles for all
// of the account's devices. Each fetch consumes a one-time prekey when one
// is available; `oneTimePreKey` is null when the pool is exhausted.
func (s *Server) handleGetKeys(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	account := r.PathValue("account")
	// Exempt own-account fetches (device sync / session refresh). Rate-limit
	// cross-account fetches to prevent prekey-pool depletion attacks.
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
	// One-time prekey budgets (cross-account only): once the target device's
	// hourly budget or the requester's is spent, the bundle is still served,
	// just without a one-time prekey (see preKeyTargetOTKLimiter).
	var allowOneTime func(uint32) bool
	if dev.AccountID != account {
		allowOneTime = func(deviceID uint32) bool {
			if preKeyRequesterOTKLimiter.exhausted(dev.AccountID) {
				return false
			}
			if !preKeyTargetOTKLimiter.allow(account + "/" + strconv.FormatUint(uint64(deviceID), 10)) {
				return false
			}
			return preKeyRequesterOTKLimiter.allow(dev.AccountID)
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

	// Include the account's sealed-sender access key so a sender who establishes
	// a session (fetches the bundle) can then send sealed to this account.
	accessKey, _ := s.store.AccessKey(account)
	writeKeyBundles(w, bundles, accessKey)
}

// handleGetKeysSealed serves prekey bundles to a caller that proves it may
// reach `account` with the account's sealed-sender access key — without saying
// who it is, so the relay can't record who fetches whose keys. Clients use it
// whenever they already know the peer's access key (every fetch after the first
// contact); the signed GET /v1/keys/{account} remains for first contact.
// Unknown account and wrong key get the same 403. Abuse is bounded per source
// IP and by the target's one-time-prekey budget.
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
	// Same one-time prekey budgets as the signed path, with the source IP
	// standing in for the (unknown) requester.
	requester := "ip:" + ip
	allowOneTime := func(deviceID uint32) bool {
		if preKeyRequesterOTKLimiter.exhausted(requester) {
			return false
		}
		if !preKeyTargetOTKLimiter.allow(account + "/" + strconv.FormatUint(uint64(deviceID), 10)) {
			return false
		}
		return preKeyRequesterOTKLimiter.allow(requester)
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

// b64 marshals []byte as standard (padded) base64 in JSON, the encoding
// all clients must use for binary key material in the REST API.
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

// errTrailingJSON rejects a request body that carries anything after its
// single JSON value.
var errTrailingJSON = errors.New("unexpected data after the JSON body")

// decodeJSON decodes exactly one JSON value from the request body into v and
// rejects any trailing data (whitespace aside). Every JSON handler uses it, so
// the body a handler acts on is the whole body the request signature covered —
// never a prefix followed by bytes nothing looked at.
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

// handleDeleteAccount permanently deletes the authenticated account and all
// server-side data keyed to it (see store.DeleteAccount), then drops every live
// WebSocket of the account. After this, the account's credentials no longer
// authenticate (401) and its username enters the reuse cooldown.
//
// The optional body {"appleAuthorizationCode": "..."} carries a fresh Sign in
// with Apple authorization code; when the relay is configured for it, the
// user's Apple grant is revoked after the deletion (best-effort: Apple being
// unreachable never fails the deletion). The code is used once and never
// stored or logged.
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
	// Read the linked Supabase user before the row (and the link) is gone.
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
	s.deleteSupabaseUser(context.WithoutCancel(r.Context()), supabaseUserID)
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
// against another account. `messages` are plaintext messages the reporter
// explicitly chose to forward from their decrypted conversation — the relay
// otherwise never sees message content.
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
	// Count only well-formed reports against real accounts toward the cap.
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

// handleNuke processes a signed remote-wipe command. The server validates the
// signature shape but cannot generate a valid command; clients independently
// verify the full signature before wiping local storage.
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
	// A device may only issue a nuke command in its own name.
	if req.InitiatingDeviceID != dev.DeviceID {
		httpError(w, http.StatusForbidden, "initiatingDeviceId must match authenticated device")
		return
	}
	// Reject commands more than 5 minutes old to limit replay window.
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
// REST API HMAC format: username="{expiry}:{random}", password=HMAC-SHA1.
// Returns 404 if TURN is not configured on this server.
func (s *Server) handleTurnCredentials(w http.ResponseWriter, r *http.Request, _ *store.Device) {
	if len(s.turnURLs) == 0 || s.turnSecret == "" {
		httpError(w, http.StatusNotFound, "TURN not configured on this server")
		return
	}
	expiry := time.Now().Unix() + turnTTL
	// The part after the expiry is 16 random hex chars, NOT derived from the
	// account: the TURN server (and its logs) must not be able to tie relayed
	// call traffic to a relay account. coturn only needs it to be unique-ish.
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
	// While our coturn is healthy it's the only server handed out. When it's
	// down or overloaded only Cloudflare's TURN is (listing ours too would keep
	// adding allocations to a box that needs the load taken off it), in both
	// the list and the legacy top-level fields older clients read.
	servers, legacy := []iceServer{own}, own
	// ?failed=1: the phone's call just lost its relay. Check our TURN now
	// instead of waiting for the background prober (~15 s) to notice.
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
	key = limitkey.Hash(key) // never hold a raw IP / account id / pair in memory
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

// PruneStaleLimiterKeys removes map entries that have no activity within
// their window. Called periodically so low-frequency callers (e.g. one-time
// source IPs hitting the registration endpoint) don't leak memory forever.
func (s *Server) PruneStaleLimiterKeys() {
	s.pruneTokenBuckets()
	recoveryLockout.prune()
	oprfBudget.prune()
	for _, l := range []*slidingWindowLimiter{
		accountCreationLimiter,
		preKeyFetchLimiter,
		groupCreateLimiter,
		inviteClaimIPLimiter,
		attachmentIPLimiter,
		callRingIPLimiter,
		callRingMailboxLimiter,
		usernameLookupLimiter,
		keyUploadLimiter,
		sealedSendIPLimiter,
		sealedSendMailboxLimiter,
		directoryLimiter,
		directoryIPLimiter,
		provisioningLimiter,
		reportLimiter,
	} {
		now := time.Now()
		l.mu.Lock()
		cutoff := now.Add(-l.window)
		for key, times := range l.windows {
			allExpired := true
			for _, t := range times {
				if t.After(cutoff) {
					allExpired = false
					break
				}
			}
			if allExpired {
				delete(l.windows, key)
			}
		}
		l.mu.Unlock()
	}
}

const (
	// maxProvisioningBlobBytes caps the sealed device-linking payload. The blob
	// is identity + credentials + up to ~50 conversation stubs — a few KiB — so
	// 64 KiB is generous while preventing a huge-blob DoS on the session table.
	maxProvisioningBlobBytes = 64 * 1024
	// maxGroupNameBytes caps group name length at 512 UTF-8 bytes.
	maxGroupNameBytes = 512
	// maxGroupDescriptionBytes caps group descriptions at 4 KiB.
	maxGroupDescriptionBytes = 4096
	// maxGroupMembers caps the roster size to prevent fan-out explosions.
	maxGroupMembers = 256
	// maxPasswordBytes caps password length to prevent DoS via huge bcrypt inputs.
	maxPasswordBytes = 1024
	// maxOneTimePreKeysPerUpload caps how many OTKs a client can upload in one call.
	maxOneTimePreKeysPerUpload = 200
)

// 20 registrations per source IP per hour.
var accountCreationLimiter = newSlidingWindowLimiter(20, time.Hour)

// 200 prekey-bundle fetches per (requester, target) pair per hour.
// Prevents one account from draining another's one-time prekey pool.
// Own-account fetches (device sync) are exempt.
var preKeyFetchLimiter = newSlidingWindowLimiter(200, time.Hour)

// 20 group creations per account per day.
var groupCreateLimiter = newSlidingWindowLimiter(20, 24*time.Hour)

// Unauthenticated invite claims (contact + group) per source IP per hour, to
// bound token brute-forcing.
var inviteClaimIPLimiter = newSlidingWindowLimiter(60, time.Hour)

// Unauthenticated attachment GET/PUT per source IP per minute.
var attachmentIPLimiter = newSlidingWindowLimiter(600, time.Minute)

// Call rings are unauthenticated (access-key capability, like sealed sends):
// bound them per source IP and per destination mailbox.
var callRingIPLimiter = newSlidingWindowLimiter(60, time.Minute)
var callRingMailboxLimiter = newSlidingWindowLimiter(20, time.Minute)

// usernameLookupLimiter: unauthenticated username-availability checks per IP per hour.
// Debounced in the client; enough for sign-up typing, too few for bulk probing.
var usernameLookupLimiter = newSlidingWindowLimiter(120, time.Hour)

// Sealed-sender delivery is unauthenticated, so rate-limit per source IP and per
// destination mailbox to bound abuse on top of the access-key check.
var sealedSendIPLimiter = newSlidingWindowLimiter(600, time.Minute)

// sealedKeyFetchIPLimiter bounds anonymous key fetches per source IP.
var sealedKeyFetchIPLimiter = newSlidingWindowLimiter(300, time.Hour)
var sealedSendMailboxLimiter = newSlidingWindowLimiter(120, time.Minute)

// directoryLimiter: blinded-discovery requests (OPRF eval + bucket fetch) per
// account per hour. Batched (up to 1024 per request), so a full address-book
// sync is a couple of calls.
var directoryLimiter = newSlidingWindowLimiter(200, time.Hour)

// directoryIPLimiter: bucket fetches per source IP per hour.
var directoryIPLimiter = newSlidingWindowLimiter(400, time.Hour)

// maxDirectoryBatch caps elements/buckets per discovery request.
const maxDirectoryBatch = 1024

// oprfBudget meters OPRF evaluations per ELEMENT (not per request): a few
// thousand per account and per source IP per day — enough to sync a large
// address book, far too few to enumerate the identifier space offline.
var oprfBudget = newElementBudget(map[string]budgetSpec{
	"acct:": {capacity: 5000, period: 24 * time.Hour},
	"ip:":   {capacity: 20000, period: 24 * time.Hour},
})

// 100 key uploads per account per hour.
var keyUploadLimiter = newSlidingWindowLimiter(100, time.Hour)

// 10 new provisioning (device-linking) sessions per source IP per 10 minutes.
var provisioningLimiter = newSlidingWindowLimiter(10, 10*time.Minute)

// 20 abuse reports per reporting account per rolling 24 hours.
var reportLimiter = newSlidingWindowLimiter(20, 24*time.Hour)

// ipRateLimiter kept for backward compatibility with existing call site.
type ipRateLimiter = slidingWindowLimiter

// validUsername matches alphanumeric, dots, underscores, and hyphens only.
// This avoids homograph attacks by excluding non-ASCII lookalike characters.
var validUsername = regexp.MustCompile(`^[a-zA-Z0-9._\-]{1,64}$`)
