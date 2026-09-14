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
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/relayapp/relay-server/gen/relaypb"
	"github.com/relayapp/relay-server/internal/blob"
	"github.com/relayapp/relay-server/internal/hub"
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
	supabaseURL         string
	supabaseAnonKey     string
	verifySupabaseToken func(ctx context.Context, accessToken string) (userID, email string, err error)

	// Sealed-sender certificate issuance. When set, GET /v1/certificate/delivery
	// mints a libsignal-compatible sender certificate for the authenticated device.
	sealed *sealedIssuer

	// Blinded discovery. When set, the directory endpoints evaluate the OPRF and
	// resolve tokens; the server (re)builds the directory index under this key.
	oprf *oprf.Key
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
	s := &Server{store: st, hub: h, blobs: blobs, turnURLs: urls, turnSecret: turnSecret}
	s.verifySupabaseToken = s.verifySupabaseTokenHTTP
	return s
}

// SetSupabaseAuth enables the social-login account endpoint by pointing the
// server at a Supabase project. projectURL is the base (e.g.
// https://xxxx.supabase.co); anonKey is the project's anon API key, required as
// the apikey header on GoTrue calls.
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
	if a.Email != "" {
		entries = append(entries, store.DirectoryEntry{
			Token: s.oprf.Token(a.Email), AccountID: a.AccountID, Kind: store.DirectoryKindEmail,
		})
	}
	return entries
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
	mux.HandleFunc("POST /v1/contact-invites", s.auth(s.handleCreateContactInvite))
	mux.HandleFunc("POST /v1/contact-invites/claim", s.auth(s.handleClaimContactInvite))
	mux.HandleFunc("POST /v1/devices", s.auth(s.handleAddDevice))
	mux.HandleFunc("POST /v1/devices/link-invitations", s.auth(s.handleCreateDeviceLinkInvitation))
	mux.HandleFunc("POST /v1/devices/link-claims", s.handleClaimDeviceLink)
	mux.HandleFunc("GET /v1/devices", s.auth(s.handleListDevices))
	mux.HandleFunc("DELETE /v1/devices/{id}", s.auth(s.handleRemoveDevice))
	mux.HandleFunc("PUT /v1/devices/auth-key", s.auth(s.handleSetDeviceAuthKey))
	mux.HandleFunc("PUT /v1/devices/apns", s.auth(s.handleSetAPNSToken))
	mux.HandleFunc("PUT /v1/devices/voip", s.auth(s.handleSetVoIPToken))
	mux.HandleFunc("POST /v1/call/{account}", s.auth(s.handleCallOffer))
	mux.HandleFunc("PUT /v1/keys", s.auth(s.handleSetKeys))
	mux.HandleFunc("GET /v1/keys/count", s.auth(s.handleKeyCount))
	mux.HandleFunc("GET /v1/keys/{account}", s.auth(s.handleGetKeys))
	mux.HandleFunc("GET /v1/accounts/by-username/{username}", s.handleLookupUsername)
	mux.HandleFunc("GET /v1/accounts/by-email/{email}", s.auth(s.handleLookupEmail))
	mux.HandleFunc("PUT /v1/accounts/me/username", s.auth(s.handleUpdateUsername))
	mux.HandleFunc("POST /v1/accounts/me/nuke", s.auth(s.handleNuke))
	mux.HandleFunc("GET /v1/devices/{id}/auth-key", s.auth(s.handleGetDeviceAuthKey))
	mux.HandleFunc("GET /v1/turn-credentials", s.auth(s.handleTurnCredentials))
	mux.HandleFunc("GET /v1/accounts/{account}", s.auth(s.handleLookupAccount))
	mux.HandleFunc("GET /v1/presence/{account}", s.auth(s.handlePresence))
	mux.HandleFunc("POST /v1/attachments", s.auth(s.handleCreateAttachment))
	mux.HandleFunc("PUT /v1/attachments/{id}", s.auth(s.handleUploadAttachment))
	mux.HandleFunc("GET /v1/attachments/{id}", s.auth(s.handleDownloadAttachment))
	mux.HandleFunc("POST /v1/groups", s.auth(s.handleCreateGroup))
	mux.HandleFunc("GET /v1/groups/{id}", s.auth(s.handleGetGroup))
	mux.HandleFunc("POST /v1/groups/{id}/members", s.auth(s.handleAddMember))
	mux.HandleFunc("DELETE /v1/groups/{id}/members/{account}", s.auth(s.handleRemoveMember))
	mux.HandleFunc("PUT /v1/groups/{id}", s.auth(s.handleRenameGroup))
	mux.HandleFunc("POST /v1/groups/{id}/admins/{account}", s.auth(s.handlePromoteAdmin))
	mux.HandleFunc("DELETE /v1/groups/{id}/admins/{account}", s.auth(s.handleDemoteAdmin))
	mux.HandleFunc("PUT /v1/groups/{id}/announce", s.auth(s.handleSetAnnounceOnly))
	mux.HandleFunc("POST /v1/groups/{id}/invite", s.auth(s.handleCreateGroupInvite))
	mux.HandleFunc("POST /v1/groups/join", s.auth(s.handleJoinGroupByInvite))
	mux.HandleFunc("POST /v1/group-invites", s.auth(s.handleCreateEncryptedGroupInvite))
	mux.HandleFunc("POST /v1/group-invites/claim", s.auth(s.handleClaimEncryptedGroupInvite))
	mux.HandleFunc("GET /v1/ws", s.auth(s.handleWebSocket))
	return stripVisitorIPHeaders(limitRequestBody(mux))
}

// ---------------------------------------------------------------------------
// Auth: HTTP Basic with username "<accountID>.<deviceID>".
// ---------------------------------------------------------------------------

type authedHandler func(w http.ResponseWriter, r *http.Request, dev *store.Device)

func (s *Server) auth(next authedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		user, pass, ok := r.BasicAuth()
		if !ok {
			w.Header().Set("WWW-Authenticate", `Basic realm="relay"`)
			httpError(w, http.StatusUnauthorized, "missing credentials")
			return
		}
		accountID, devStr, ok := strings.Cut(user, ".")
		if !ok {
			httpError(w, http.StatusUnauthorized, "auth username must be <accountID>.<deviceID>")
			return
		}
		devID, err := strconv.ParseUint(devStr, 10, 32)
		if err != nil {
			httpError(w, http.StatusUnauthorized, "bad device id")
			return
		}
		dev, err := s.store.Authenticate(accountID, uint32(devID), pass)
		if err != nil {
			httpError(w, http.StatusUnauthorized, "authentication failed")
			return
		}
		next(w, r, dev)
	}
}

// ---------------------------------------------------------------------------
// Accounts and devices
// ---------------------------------------------------------------------------

func (s *Server) handleCreateAccount(w http.ResponseWriter, r *http.Request) {
	// Rate limit: 5 registrations per source IP per hour.
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	if !accountCreationLimiter.allow(ip) {
		httpError(w, http.StatusTooManyRequests, "registration rate limit exceeded; try again later")
		return
	}
	var req struct {
		Username        string `json:"username"`
		Password        string `json:"password"`
		Email           string `json:"email"`
		AccountPassword string `json:"accountPassword"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil ||
		!validUsername.MatchString(req.Username) ||
		len(req.Password) < 8 || len(req.Password) > maxPasswordBytes {
		httpError(w, http.StatusBadRequest, "username (1–64 alphanumeric/._- chars) and password (8–1024 chars) required")
		return
	}
	if req.AccountPassword != "" && (len(req.AccountPassword) < 8 || len(req.AccountPassword) > maxPasswordBytes) {
		httpError(w, http.StatusBadRequest, "accountPassword must be 8–1024 chars")
		return
	}
	accountID, deviceID, err := s.store.CreateAccount(req.Username, req.Email, req.Password, req.AccountPassword)
	if errors.Is(err, store.ErrUsernameTaken) {
		httpError(w, http.StatusConflict, "username already taken")
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

// handleOAuthAccount signs a Supabase-authenticated user into their relay
// account, creating it on first use, and provisions a fresh device. The request
// carries the user's Supabase access token, which the server verifies directly
// with Supabase; the returned id/email are authoritative. This lets a
// passwordless social-login user recover their account on any device instead of
// colliding with their own email on a fresh registration.
func (s *Server) handleOAuthAccount(w http.ResponseWriter, r *http.Request) {
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
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

	userID, email, err := s.verifySupabaseToken(r.Context(), req.AccessToken)
	if err != nil {
		httpError(w, http.StatusUnauthorized, "invalid or expired social login token")
		return
	}

	accountID, username, deviceID, mailboxID, created, err := s.store.ProvisionOAuthAccount(
		userID, email, req.Username, req.Password, req.AccountPassword)
	if errors.Is(err, store.ErrUsernameRequired) {
		// No account exists yet for this user and no username was supplied.
		// Signal the client to prompt for one and retry.
		httpError(w, http.StatusNotFound, "username required")
		return
	}
	if errors.Is(err, store.ErrUsernameTaken) {
		httpError(w, http.StatusConflict, "username already taken")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}

	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	if created {
		s.reindexAccount(accountID) // index the new social-login user for discovery
	}
	writeJSON(w, status, map[string]any{
		"accountId": accountID,
		"deviceId":  deviceID,
		"username":  username,
		"mailboxId": mailboxID,
		"created":   created,
	})
}

// verifySupabaseTokenHTTP asks Supabase who an access token belongs to via a
// server-to-server GET /auth/v1/user. Returns the authoritative user id and
// email if the token is valid.
func (s *Server) verifySupabaseTokenHTTP(ctx context.Context, accessToken string) (userID, email string, err error) {
	if s.supabaseURL == "" {
		return "", "", errors.New("supabase auth not configured")
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.supabaseURL+"/auth/v1/user", nil)
	if err != nil {
		return "", "", err
	}
	req.Header.Set("apikey", s.supabaseAnonKey)
	req.Header.Set("Authorization", "Bearer "+accessToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("supabase user lookup failed: HTTP %d", resp.StatusCode)
	}
	var body struct {
		ID    string `json:"id"`
		Email string `json:"email"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return "", "", err
	}
	if body.ID == "" {
		return "", "", errors.New("supabase returned no user id")
	}
	return body.ID, body.Email, nil
}

// handleSealedSend delivers a sealed-sender message. It is UNAUTHENTICATED by
// design — the relay must not learn who sent the message. The sender proves it's
// allowed to reach the destination by presenting the recipient's access key
// (obtained with the prekey bundle); the server verifies it in constant time
// without learning the sender's identity. The delivered envelope carries no
// sender fields; the recipient recovers the sender by decrypting the sealed blob.
func (s *Server) handleSealedSend(w http.ResponseWriter, r *http.Request) {
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	if !sealedSendIPLimiter.allow(ip) {
		httpError(w, http.StatusTooManyRequests, "rate limit exceeded; try again later")
		return
	}
	var req struct {
		MailboxID       string `json:"mailboxId"`
		Type            int32  `json:"type"`
		Content         string `json:"content"`   // base64 sealed blob
		AccessKey       string `json:"accessKey"` // base64, recipient's access key
		Ephemeral       bool   `json:"ephemeral"`
		ClientTimestamp int64  `json:"clientTimestamp"`
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
	// Resolve the mailbox and verify the access key. Any failure returns the same
	// 403 so the endpoint doesn't reveal whether a mailbox exists.
	dest, err := s.store.DeviceByMailbox(req.MailboxID)
	if err != nil {
		httpError(w, http.StatusForbidden, "delivery rejected")
		return
	}
	stored, err := s.store.AccessKey(dest.AccountID)
	if err != nil || len(stored) == 0 || subtle.ConstantTimeCompare(stored, token) != 1 {
		httpError(w, http.StatusForbidden, "delivery rejected")
		return
	}

	env := &relaypb.Envelope{
		Id: newEnvelopeID(),
		// SenderAccount / SenderDevice intentionally left empty: the relay does
		// not know who sent a sealed message. The recipient recovers the sender
		// from the sealed blob.
		Type:            relaypb.CiphertextType(req.Type),
		Content:         content,
		ClientTimestamp: req.ClientTimestamp,
		ServerTimestamp: time.Now().UnixMilli(),
		Ephemeral:       req.Ephemeral,
	}
	if err := s.hub.Deliver(dest.AccountID, dest.DeviceID, env); err != nil {
		slog.Error("sealed send: deliver failed", "err", privlog.Error(err))
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"serverTimestamp": env.ServerTimestamp})
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
// returns it. Clients call this periodically so the relay can't track a
// long-lived routing identifier; peers pick up the new id on their next bundle
// fetch, and sealed sends to the stale id fail-and-retry.
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
// inviter's account id and username. Single-use: a second claim returns 404.
func (s *Server) handleClaimContactInvite(w http.ResponseWriter, r *http.Request, dev *store.Device) {
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

func (s *Server) handleRecoverAccount(w http.ResponseWriter, r *http.Request) {
	// Rate-limit recovery attempts (same bucket as account creation per IP).
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	if !accountCreationLimiter.allow("recover:" + ip) {
		httpError(w, http.StatusTooManyRequests, "recovery rate limit exceeded; try again later")
		return
	}
	var req struct {
		Email           string `json:"email"`
		AccountPassword string `json:"accountPassword"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Email == "" || req.AccountPassword == "" {
		httpError(w, http.StatusBadRequest, "email and accountPassword required")
		return
	}
	accountID, username, deviceID, devicePassword, err := s.store.RecoverAccount(req.Email, req.AccountPassword)
	switch {
	case errors.Is(err, store.ErrAccountNotFound):
		httpError(w, http.StatusNotFound, "no account with that email")
		return
	case errors.Is(err, store.ErrNoRecoveryPassword):
		httpError(w, http.StatusUnprocessableEntity, "account has no recovery password; use device linking instead")
		return
	case errors.Is(err, store.ErrAuthFailed):
		httpError(w, http.StatusUnauthorized, "incorrect recovery password")
		return
	case err != nil:
		internalError(w, err)
		return
	}
	devices, err := s.store.ListDevices(accountID)
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
	writeJSON(w, http.StatusCreated, map[string]any{
		"accountId":      accountID,
		"username":       username,
		"deviceId":       deviceID,
		"devicePassword": devicePassword,
		"mailboxId":      mailboxID,
	})
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
	password, err := newLinkPassword()
	if err != nil {
		internalError(w, err)
		return
	}
	token, code, expiresAt, err := s.store.CreateDeviceLinkToken(dev.AccountID, password, req.Auth.ExpectedVersion)
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

func (s *Server) handleListDevices(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	devices, err := s.store.ListDevices(dev.AccountID)
	if err != nil {
		internalError(w, err)
		return
	}
	type jsonDevice struct {
		DeviceID  uint32 `json:"deviceId"`
		MailboxID string `json:"mailboxId,omitempty"`
	}
	out := make([]jsonDevice, len(devices))
	for i, d := range devices {
		out[i] = jsonDevice{DeviceID: d.DeviceID, MailboxID: d.MailboxID}
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

func newLinkPassword() (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b[:]), nil
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

func (s *Server) handleSetAPNSToken(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Token == "" {
		httpError(w, http.StatusBadRequest, "token required")
		return
	}
	if err := s.store.SetAPNSToken(dev.AccountID, dev.DeviceID, req.Token); err != nil {
		internalError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleSetVoIPToken(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Token == "" {
		httpError(w, http.StatusBadRequest, "token required")
		return
	}
	if err := s.store.SetVoIPToken(dev.AccountID, dev.DeviceID, req.Token); err != nil {
		internalError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleCallOffer triggers a VoIP push to the target account so CallKit can
// present the incoming-call UI before the E2EE offer envelope arrives over WS.
func (s *Server) handleCallOffer(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	target := r.PathValue("account")
	var req struct {
		CallID     string `json:"callId"`
		CallerName string `json:"callerName"`
		Kind       string `json:"kind"` // "audio" or "video"
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.CallID == "" {
		httpError(w, http.StatusBadRequest, "callId required")
		return
	}
	s.hub.PushCallToAccount(target, req.CallID, dev.AccountID, req.CallerName, req.Kind)
	w.WriteHeader(http.StatusNoContent)
}

// handleLookupUsername is intentionally unauthenticated so clients can check
// username availability during sign-up before they have credentials.
// Rate-limited by source IP to prevent bulk enumeration.
func (s *Server) handleLookupUsername(w http.ResponseWriter, r *http.Request) {
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	if !usernameLookupLimiter.allow(ip) {
		httpError(w, http.StatusTooManyRequests, "lookup rate limit exceeded; try again later")
		return
	}
	accountID, err := s.store.LookupAccountID(r.PathValue("username"))
	if errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusNotFound, "no such user")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"accountId": accountID})
}

func (s *Server) handleLookupEmail(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if !emailLookupLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "lookup rate limit exceeded; try again later")
		return
	}
	email := r.PathValue("email")
	accountID, username, err := s.store.LookupAccountByEmail(email)
	if errors.Is(err, store.ErrAccountNotFound) {
		httpError(w, http.StatusNotFound, "no such user")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"accountId": accountID, "username": username})
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

// handlePresence reports whether an account currently has a live connection
// and, if not, when it was last seen (ms since epoch, 0 if never).
// Rate-limited to limit metadata exposure to any single requester.
func (s *Server) handlePresence(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if !presenceLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "presence rate limit exceeded; try again later")
		return
	}
	account := r.PathValue("account")
	online := s.hub.IsOnline(account)
	// last_seen is in-memory only — not persisted to the DB.
	lastSeen := s.hub.LastSeen(account)
	writeJSON(w, http.StatusOK, map[string]any{"online": online, "lastSeen": lastSeen})
}

// ---------------------------------------------------------------------------
// Attachments (opaque encrypted blobs)
// ---------------------------------------------------------------------------

func (s *Server) handleCreateAttachment(w http.ResponseWriter, r *http.Request, _ *store.Device) {
	id, err := s.blobs.NewID()
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"id": id})
}

func (s *Server) handleUploadAttachment(w http.ResponseWriter, r *http.Request, _ *store.Device) {
	err := s.blobs.Put(r.PathValue("id"), r.Body)
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

func (s *Server) handleDownloadAttachment(w http.ResponseWriter, r *http.Request, _ *store.Device) {
	data, err := s.blobs.Get(r.PathValue("id"))
	switch {
	case errors.Is(err, blob.ErrNotFound):
		httpError(w, http.StatusNotFound, "no such attachment")
	case err != nil:
		internalError(w, err)
	default:
		w.Header().Set("Content-Type", "application/octet-stream")
		w.WriteHeader(http.StatusOK)
		w.Write(data)
	}
}

// ---------------------------------------------------------------------------
// Groups (server-stored roster; the relay never sees group plaintext)
// ---------------------------------------------------------------------------

func writeGroup(w http.ResponseWriter, status int, g *store.Group) {
	admins := g.Admins
	if admins == nil {
		admins = []string{}
	}
	members := g.Members
	if members == nil {
		members = []string{}
	}
	writeJSON(w, status, map[string]any{
		"id":             g.ID,
		"name":           g.Name,
		"description":    g.Description,
		"avatarId":       g.AvatarID,
		"distributionId": g.DistributionID,
		"revision":       g.Revision,
		"members":        members,
		"admins":         admins,
		"announceOnly":   g.AnnounceOnly,
	})
}

func (s *Server) groupError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		httpError(w, http.StatusNotFound, "no such group")
	case errors.Is(err, store.ErrNotMember):
		httpError(w, http.StatusForbidden, "not a group member")
	case errors.Is(err, store.ErrNotAdmin):
		httpError(w, http.StatusForbidden, "not a group admin")
	default:
		internalError(w, err)
	}
}

func (s *Server) handlePromoteAdmin(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	g, err := s.store.PromoteAdmin(r.PathValue("id"), dev.AccountID, r.PathValue("account"))
	if err != nil {
		s.groupError(w, err)
		return
	}
	writeGroup(w, http.StatusOK, g)
}

func (s *Server) handleDemoteAdmin(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	g, err := s.store.DemoteAdmin(r.PathValue("id"), dev.AccountID, r.PathValue("account"))
	if err != nil {
		s.groupError(w, err)
		return
	}
	writeGroup(w, http.StatusOK, g)
}

func (s *Server) handleSetAnnounceOnly(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		AnnounceOnly bool `json:"announceOnly"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "malformed body")
		return
	}
	g, err := s.store.SetAnnounceOnly(r.PathValue("id"), dev.AccountID, req.AnnounceOnly)
	if err != nil {
		s.groupError(w, err)
		return
	}
	writeGroup(w, http.StatusOK, g)
}

func (s *Server) handleCreateGroup(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	// Rate-limit group creation to prevent resource exhaustion.
	if !groupCreateLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "group creation rate limit exceeded; try again later")
		return
	}
	var req struct {
		Name    string   `json:"name"`
		Members []string `json:"members"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "malformed body")
		return
	}
	if len(req.Name) == 0 || len(req.Name) > maxGroupNameBytes {
		httpError(w, http.StatusBadRequest, "group name must be 1–512 bytes")
		return
	}
	if len(req.Members) > maxGroupMembers {
		httpError(w, http.StatusBadRequest, "group member count exceeds limit")
		return
	}
	g, err := s.store.CreateGroup(dev.AccountID, req.Name, req.Members)
	if err != nil {
		s.groupError(w, err)
		return
	}
	writeGroup(w, http.StatusCreated, g)
}

func (s *Server) handleGetGroup(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	g, err := s.store.GetGroup(r.PathValue("id"), dev.AccountID)
	if err != nil {
		s.groupError(w, err)
		return
	}
	writeGroup(w, http.StatusOK, g)
}

func (s *Server) handleAddMember(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Account string `json:"account"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Account == "" {
		httpError(w, http.StatusBadRequest, "account required")
		return
	}
	g, err := s.store.AddMember(r.PathValue("id"), dev.AccountID, req.Account)
	if errors.Is(err, store.ErrGroupFull) {
		httpError(w, http.StatusUnprocessableEntity, "group member limit reached")
		return
	}
	if err != nil {
		s.groupError(w, err)
		return
	}
	writeGroup(w, http.StatusOK, g)
}

func (s *Server) handleRemoveMember(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	g, err := s.store.RemoveMember(r.PathValue("id"), dev.AccountID, r.PathValue("account"))
	if err != nil {
		s.groupError(w, err)
		return
	}
	writeGroup(w, http.StatusOK, g)
}

func (s *Server) handleRenameGroup(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Name        *string `json:"name"`
		Description *string `json:"description"`
		AvatarID    *string `json:"avatarId"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "malformed body")
		return
	}
	id := r.PathValue("id")
	if req.Name != nil && (len(*req.Name) == 0 || len(*req.Name) > maxGroupNameBytes) {
		httpError(w, http.StatusBadRequest, "group name must be 1–512 bytes")
		return
	}
	if req.Description != nil && len(*req.Description) > maxGroupDescriptionBytes {
		httpError(w, http.StatusBadRequest, "group description too long (max 4096 bytes)")
		return
	}
	var g *store.Group
	var err error
	switch {
	case req.Name != nil:
		g, err = s.store.RenameGroup(id, dev.AccountID, *req.Name)
	case req.Description != nil:
		g, err = s.store.SetGroupDescription(id, dev.AccountID, *req.Description)
	case req.AvatarID != nil:
		g, err = s.store.SetGroupAvatar(id, dev.AccountID, *req.AvatarID)
	default:
		httpError(w, http.StatusBadRequest, "name, description, or avatarId required")
		return
	}
	if err != nil {
		s.groupError(w, err)
		return
	}
	writeGroup(w, http.StatusOK, g)
}

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
// redeemer can decrypt it client-side with the fragment key. Multi-use until expiry.
func (s *Server) handleClaimEncryptedGroupInvite(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if !groupJoinLimiter.allow(dev.AccountID) {
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

func (s *Server) handleCreateGroupInvite(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	token, err := s.store.CreateGroupInvite(r.PathValue("id"), dev.AccountID)
	if err != nil {
		s.groupError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{
		"token": token,
		"url":   "relay://join/" + token,
	})
}

func (s *Server) handleJoinGroupByInvite(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	// Rate-limit invite attempts per account to prevent token brute-forcing.
	if !groupJoinLimiter.allow(dev.AccountID) {
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
	g, err := s.store.JoinGroupByInvite(req.Token, dev.AccountID)
	if errors.Is(err, store.ErrGroupFull) {
		httpError(w, http.StatusUnprocessableEntity, "group member limit reached")
		return
	}
	if err != nil {
		s.groupError(w, err)
		return
	}
	writeGroup(w, http.StatusOK, g)
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
	if err := s.store.SetKeys(dev.AccountID, dev.DeviceID, req.RegistrationID, req.IdentityKey, spk, kyber, otks); err != nil {
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
	bundles, err := s.store.TakePreKeyBundles(account, deviceIDs)
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
// REST API HMAC format: username="{expiry}:{accountId}", password=HMAC-SHA1.
// Returns 404 if TURN is not configured on this server.
func (s *Server) handleTurnCredentials(w http.ResponseWriter, _ *http.Request, dev *store.Device) {
	if len(s.turnURLs) == 0 || s.turnSecret == "" {
		httpError(w, http.StatusNotFound, "TURN not configured on this server")
		return
	}
	expiry := time.Now().Unix() + turnTTL
	// Use first 8 chars of account ID as an opaque user hint — long enough for
	// coturn ACLs, short enough to limit metadata in the username field.
	username := strconv.FormatInt(expiry, 10) + ":" + dev.AccountID[:min(8, len(dev.AccountID))]
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
	for _, l := range []*slidingWindowLimiter{
		accountCreationLimiter,
		preKeyFetchLimiter,
		groupCreateLimiter,
		groupJoinLimiter,
		presenceLimiter,
		lookupLimiter,
		emailLookupLimiter,
		usernameLookupLimiter,
		keyUploadLimiter,
		sealedSendIPLimiter,
		sealedSendMailboxLimiter,
		directoryLimiter,
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

// 50 invite-join attempts per account per hour to prevent token brute-forcing.
var groupJoinLimiter = newSlidingWindowLimiter(50, time.Hour)

// 300 presence lookups per account per minute.
var presenceLimiter = newSlidingWindowLimiter(300, time.Minute)

// lookupLimiter: general account/profile lookups per account per hour (search, profile fetches).
var lookupLimiter = newSlidingWindowLimiter(600, time.Hour)

// emailLookupLimiter: contact-discovery lookups per account per hour.
// Contact sync fires one request per address book email — needs to cover
// a full address book in a single sync pass without hitting the limit.
var emailLookupLimiter = newSlidingWindowLimiter(3000, time.Hour)

// usernameLookupLimiter: unauthenticated username-availability checks per IP per hour.
// Debounced in the client, but generous enough for normal sign-up typing.
var usernameLookupLimiter = newSlidingWindowLimiter(600, time.Hour)

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

// ipRateLimiter kept for backward compatibility with existing call site.
type ipRateLimiter = slidingWindowLimiter

// validUsername matches alphanumeric, dots, underscores, and hyphens only.
// This avoids homograph attacks by excluding non-ASCII lookalike characters.
var validUsername = regexp.MustCompile(`^[a-zA-Z0-9._\-]{1,64}$`)
