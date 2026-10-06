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
		attachQuota: newAttachmentQuota(defaultAttachmentDailyBytes, defaultAttachmentDailyCount)}
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
// and any drift is corrected on restart).
func (s *Server) SetOPRF(key *oprf.Key) error {
	s.oprf = key
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

// directoryEntries computes the OPRF token rows for an account's username/email.
func (s *Server) directoryEntries(a store.AccountDirInfo) []store.DirectoryEntry {
	var entries []store.DirectoryEntry
	if a.Username != "" {
		entries = append(entries, store.DirectoryEntry{
			Token: s.oprf.Token(a.Username), AccountID: a.AccountID, Kind: store.DirectoryKindUsername,
		})
	}
	if len(a.EmailToken) > 0 {
		entries = append(entries, store.DirectoryEntry{
			Token: a.EmailToken, AccountID: a.AccountID, Kind: store.DirectoryKindEmail,
		})
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
	mux.HandleFunc("POST /v1/directory/resolve", s.auth(s.handleDirectoryResolve))
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
	mux.HandleFunc("PUT /v1/devices/auth-key", s.auth(s.handleSetDeviceAuthKey))
	mux.HandleFunc("PUT /v1/devices/apns", s.auth(s.handleSetAPNSToken))
	mux.HandleFunc("PUT /v1/devices/fcm", s.auth(s.handleSetFCMToken))
	mux.HandleFunc("PUT /v1/devices/voip", s.auth(s.handleSetVoIPToken))
	mux.HandleFunc("PUT /v1/devices/me/push-content", s.auth(s.handleSetPushContent))
	mux.HandleFunc("POST /v1/calls/ring", s.handleCallRing) // unauthenticated by design (access-key capability)
	mux.HandleFunc("PUT /v1/keys", s.auth(s.handleSetKeys))
	mux.HandleFunc("GET /v1/keys/count", s.auth(s.handleKeyCount))
	mux.HandleFunc("GET /v1/keys/{account}", s.auth(s.handleGetKeys))
	mux.HandleFunc("GET /v1/usernames/{name}/available", s.handleUsernameAvailable) // unauthenticated, per-IP limited
	mux.HandleFunc("PUT /v1/accounts/me/username", s.auth(s.handleUpdateUsername))
	mux.HandleFunc("POST /v1/accounts/me/nuke", s.auth(s.handleNuke))
	mux.HandleFunc("DELETE /v1/accounts/me", s.auth(s.handleDeleteAccount))
	mux.HandleFunc("POST /v1/reports", s.auth(s.handleCreateReport))
	mux.HandleFunc("GET /v1/devices/{id}/auth-key", s.auth(s.handleGetDeviceAuthKey))
	mux.HandleFunc("GET /v1/turn-credentials", s.auth(s.handleTurnCredentials))
	mux.HandleFunc("GET /v1/accounts/{account}", s.auth(s.handleLookupAccount))
	mux.HandleFunc("POST /v1/attachments", s.auth(s.handleCreateAttachment))
	mux.HandleFunc("PUT /v1/attachments/{id}", s.handleUploadAttachment)   // unauthenticated: id is the capability
	mux.HandleFunc("GET /v1/attachments/{id}", s.handleDownloadAttachment) // unauthenticated: id is the capability
	mux.HandleFunc("POST /v1/group-invites", s.auth(s.handleCreateEncryptedGroupInvite))
	mux.HandleFunc("POST /v1/group-invites/claim", s.handleClaimEncryptedGroupInvite) // unauthenticated: token is the capability
	mux.HandleFunc("GET /v1/ws", s.auth(s.handleWebSocket))
	return stripVisitorIPHeaders(requestDeadlines(limitRequestBody(mux)))
}

// ---------------------------------------------------------------------------
// Auth: Relay-Sig (see sigauth.go), or HTTP Basic "<accountID>.<deviceID>"
// only for a device that has not registered an auth key yet.
// ---------------------------------------------------------------------------

type authedHandler func(w http.ResponseWriter, r *http.Request, dev *store.Device)

func (s *Server) auth(next authedHandler) http.HandlerFunc {
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
		dev, err := s.store.Authenticate(accountID, devID, pass)
		if err != nil {
			authFailIPLimiter.allow(ip)
			authFailDeviceLimiter.allow(deviceKey)
			httpError(w, http.StatusUnauthorized, "authentication failed")
			return
		}
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil ||
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.AccessToken == "" ||
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

	dev, created, err := s.store.ProvisionOAuthAccount(
		user.ID, emailToken, req.Username, req.Password, req.AccountPassword)
	switch {
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
	if !created {
		s.hub.BroadcastDeviceListChanged(dev.AccountID, dev.DeviceID, relaypb.DeviceListChanged_DEVICE_ADDED, dev.DeviceID)
	}
}

// supabaseUser is what the relay trusts from Supabase's /auth/v1/user.
type supabaseUser struct {
	ID             string
	Email          string
	EmailConfirmed bool
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
	return supabaseUser{ID: body.ID, Email: body.Email, EmailConfirmed: confirmed}, nil
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.MailboxID == "" {
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.EnvelopeID == "" {
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
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
// the client is querying — only opaque curve points cross the wire.
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if len(req.Blinded) == 0 || len(req.Blinded) > 1024 {
		httpError(w, http.StatusBadRequest, "blinded must contain 1..1024 elements")
		return
	}
	out := make([]string, 0, len(req.Blinded))
	for _, b := range req.Blinded {
		raw, err := base64.StdEncoding.DecodeString(b)
		if err != nil {
			httpError(w, http.StatusBadRequest, "invalid blinded element")
			return
		}
		eval, err := s.oprf.Evaluate(raw)
		if err != nil {
			httpError(w, http.StatusBadRequest, "invalid blinded element")
			return
		}
		out = append(out, base64.StdEncoding.EncodeToString(eval))
	}
	writeJSON(w, http.StatusOK, map[string]any{"evaluated": out})
}

// handleDirectoryResolve returns the account (and current username) for each
// token that matches the directory index. Tokens are OPRF outputs the client
// derived after the oblivious evaluation; unmatched tokens yield no result, so
// non-registered contacts stay private.
func (s *Server) handleDirectoryResolve(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if s.oprf == nil {
		httpError(w, http.StatusServiceUnavailable, "discovery not configured")
		return
	}
	if !directoryLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "discovery rate limit exceeded; try again later")
		return
	}
	var req struct {
		Tokens []string `json:"tokens"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if len(req.Tokens) == 0 || len(req.Tokens) > 1024 {
		httpError(w, http.StatusBadRequest, "tokens must contain 1..1024 elements")
		return
	}
	tokens := make([][]byte, 0, len(req.Tokens))
	for _, t := range req.Tokens {
		raw, err := base64.StdEncoding.DecodeString(t)
		if err != nil {
			httpError(w, http.StatusBadRequest, "invalid token")
			return
		}
		tokens = append(tokens, raw)
	}
	matches, err := s.store.ResolveDirectory(tokens)
	if err != nil {
		internalError(w, err)
		return
	}
	type result struct {
		Token     string `json:"token"`
		AccountID string `json:"accountId"`
		Username  string `json:"username"`
	}
	results := make([]result, 0, len(matches))
	for _, m := range matches {
		results = append(results, result{
			Token:     base64.StdEncoding.EncodeToString(m.Token),
			AccountID: m.AccountID,
			Username:  m.Username,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"results": results})
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
	expiresAt := time.Now().Add(7 * 24 * time.Hour).UnixMilli()
	cert, err := sealedsender.MintSenderCertificate(
		s.sealed.serverCert, s.sealed.serverCertKey,
		dev.AccountID, dev.DeviceID, identityKey, uint64(expiresAt),
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Token == "" {
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Email == "" || req.AccountPassword == "" ||
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
	s.hub.BroadcastDeviceListChanged(dev.AccountID, dev.DeviceID, relaypb.DeviceListChanged_DEVICE_ADDED, dev.DeviceID)
}

func (s *Server) handleUpdateUsername(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Username string `json:"username"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || !validUsername.MatchString(req.Username) {
		httpError(w, http.StatusBadRequest, "username must be 1–64 alphanumeric/._- characters")
		return
	}
	if err := s.store.UpdateUsername(dev.AccountID, req.Username); errors.Is(err, store.ErrUsernameTaken) {
		httpError(w, http.StatusConflict, "username already taken")
		return
	} else if err != nil {
		internalError(w, err)
		return
	}
	s.reindexAccount(dev.AccountID) // update the blinded directory for the new username
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAddDevice(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Password string             `json:"password"`
		Auth     deviceMutationAuth `json:"auth"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || len(req.Password) < 8 || len(req.Password) > maxPasswordBytes {
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
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
	var req struct {
		LinkToken        string `json:"linkToken"`
		VerificationCode string `json:"verificationCode"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.LinkToken == "" || req.VerificationCode == "" {
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || len(req.Blob) == 0 {
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Password == "" {
		httpError(w, http.StatusBadRequest, "password and device mutation signature required")
		return
	}
	if err := verifyDeviceMutation(dev, req.Auth, "link", 0, req.Password); err != nil {
		httpError(w, http.StatusForbidden, err.Error())
		return
	}
	name := req.DeviceName
	if len(name) > maxDeviceNameBytes {
		name = name[:maxDeviceNameBytes]
	}
	deviceID, err := s.store.AllocateLinkedDevice(dev.AccountID, req.Password, name, req.Auth.ExpectedVersion)
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || len(req.PublicKey) == 0 {
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || !validAPNsToken.MatchString(req.Token) {
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Token == "" {
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || !validAPNsToken.MatchString(req.Token) {
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.DestinationMailbox == "" ||
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

func (s *Server) handleLookupAccount(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if !lookupLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "lookup rate limit exceeded; try again later")
		return
	}
	username, err := s.store.LookupUsername(r.PathValue("account"))
	if errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusNotFound, "no such account")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"username": username})
}

// ---------------------------------------------------------------------------
// Attachments (opaque encrypted blobs)
// ---------------------------------------------------------------------------

// handleCreateAttachment allocates an attachment id for the authenticated
// device (charged to its daily attachment quota) and records it as reserved,
// so the (unauthenticated) PUT can only write ids the relay handed out, once.
func (s *Server) handleCreateAttachment(w http.ResponseWriter, r *http.Request, dev *store.Device) {
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Token == "" {
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
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
	if err := s.store.SetKeys(dev.AccountID, dev.DeviceID, req.RegistrationID, req.IdentityKey, spk, kyber, otks, req.ReplaceOneTimePreKeys); err != nil {
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

	type jsonBundle struct {
		DeviceID       uint32             `json:"deviceId"`
		MailboxID      string             `json:"mailboxId,omitempty"`
		RegistrationID uint32             `json:"registrationId"`
		IdentityKey    b64                `json:"identityKey"`
		SignedPreKey   jsonSignedPreKey   `json:"signedPreKey"`
		KyberPreKey    jsonSignedPreKey   `json:"kyberPreKey"`
		OneTimePreKey  *jsonOneTimePreKey `json:"oneTimePreKey"`
	}
	// Include the account's sealed-sender access key so a sender who establishes
	// a session (fetches the bundle) can then send sealed to this account.
	accessKey, _ := s.store.AccessKey(account)
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
// authenticate (401) and its username is free for re-registration.
func (s *Server) handleDeleteAccount(w http.ResponseWriter, r *http.Request, dev *store.Device) {
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ReportedAccount == "" {
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
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
func (s *Server) handleTurnCredentials(w http.ResponseWriter, _ *http.Request, _ *store.Device) {
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
	writeJSON(w, http.StatusOK, map[string]any{
		"urls":       s.turnURLs,
		"username":   username,
		"credential": credential,
		"ttl":        turnTTL,
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
	return &slidingWindowLimiter{windows: make(map[string][]time.Time), limit: limit, window: window}
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
	for _, l := range []*slidingWindowLimiter{
		accountCreationLimiter,
		preKeyFetchLimiter,
		groupCreateLimiter,
		inviteClaimIPLimiter,
		attachmentIPLimiter,
		callRingIPLimiter,
		callRingMailboxLimiter,
		lookupLimiter,
		usernameLookupLimiter,
		keyUploadLimiter,
		sealedSendIPLimiter,
		sealedSendMailboxLimiter,
		directoryLimiter,
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
	// maxDeviceNameBytes caps the linked-device label length.
	maxDeviceNameBytes = 64
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

// lookupLimiter: general account/profile lookups per account per hour (search, profile fetches).
var lookupLimiter = newSlidingWindowLimiter(600, time.Hour)

// usernameLookupLimiter: unauthenticated username-availability checks per IP per hour.
// Debounced in the client; enough for sign-up typing, too few for bulk probing.
var usernameLookupLimiter = newSlidingWindowLimiter(120, time.Hour)

// Sealed-sender delivery is unauthenticated, so rate-limit per source IP and per
// destination mailbox to bound abuse on top of the access-key check.
var sealedSendIPLimiter = newSlidingWindowLimiter(600, time.Minute)
var sealedSendMailboxLimiter = newSlidingWindowLimiter(120, time.Minute)

// directoryLimiter: blinded-discovery requests (OPRF eval + resolve) per account
// per hour. Batched (up to 1024 identifiers per request), so a full address-book
// sync is a couple of calls; generous enough for that without enabling the OPRF
// oracle to be hammered for offline enumeration.
var directoryLimiter = newSlidingWindowLimiter(200, time.Hour)

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
