package api

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/relayapp/relay-server/internal/store"
)

// Passkeys (WebAuthn) sign an existing account in on a fresh install. The
// client registers a discoverable credential from a signed-in device; a later
// passkey sign-in replaces the account's devices like a social login, and
// counts as the account password for the registration lock.

const (
	DefaultPasskeyRPID   = "relaymsg.app"
	DefaultPasskeyOrigin = "https://relaymsg.app"

	passkeySessionTTL = 5 * time.Minute
	// maxPasskeySessions caps each in-memory ceremony map.
	maxPasskeySessions  = 10_000
	maxPasskeyNameRunes = 64
	// maxPasskeyFieldBytes bounds each decoded WebAuthn field.
	maxPasskeyFieldBytes = 16 << 10

	errPasskeyDemo        = "not available for demo accounts"
	errPasskeySignInFails = "passkey sign-in failed"
	errPasskeySignUpFails = "passkey sign-up failed"
	errPasskeyCheckFails  = "passkey check failed"
)

// Unauthenticated passkey ceremonies, per source IP per hour.
var passkeyOptionsIPLimiter = newSlidingWindowLimiter(60, time.Hour)
var passkeyLoginIPLimiter = newSlidingWindowLimiter(120, time.Hour)

// passkeySessions holds go-webauthn session data between the options and
// finish calls. Entries are single use and expire after passkeySessionTTL.
type passkeySessions struct {
	mu sync.Mutex
	m  map[string]passkeySession
}

type passkeySession struct {
	webauthn.SessionData
	username string // passkey sign-up only
}

func newPasskeySessions() *passkeySessions {
	return &passkeySessions{m: map[string]passkeySession{}}
}

// put stores sd under key, replacing any previous entry. It returns false if
// the map is full of unexpired sessions.
func (p *passkeySessions) put(key string, sd webauthn.SessionData) bool {
	return p.putNamed(key, sd, "")
}

func (p *passkeySessions) putNamed(key string, sd webauthn.SessionData, username string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if _, ok := p.m[key]; !ok && len(p.m) >= maxPasskeySessions {
		now := time.Now()
		for k, v := range p.m {
			if now.After(v.Expires) {
				delete(p.m, k)
			}
		}
		if len(p.m) >= maxPasskeySessions {
			return false
		}
	}
	if sd.Expires.IsZero() {
		sd.Expires = time.Now().Add(passkeySessionTTL)
	}
	p.m[key] = passkeySession{sd, username}
	return true
}

// take removes and returns the unexpired session under key.
func (p *passkeySessions) take(key string) (webauthn.SessionData, bool) {
	e, ok := p.takeNamed(key)
	return e.SessionData, ok
}

func (p *passkeySessions) takeNamed(key string) (passkeySession, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	e, ok := p.m[key]
	delete(p.m, key)
	if !ok || time.Now().After(e.Expires) {
		return passkeySession{}, false
	}
	return e, true
}

// SetPasskeyRP configures the WebAuthn relying party: its ID (a registrable
// domain) and the origins clientDataJSON may carry.
func (s *Server) SetPasskeyRP(rpID string, origins []string) error {
	timeout := webauthn.TimeoutConfig{Enforce: true, Timeout: passkeySessionTTL, TimeoutUVD: passkeySessionTTL}
	w, err := webauthn.New(&webauthn.Config{
		RPID:          rpID,
		RPDisplayName: "Relay",
		RPOrigins:     origins,
		Timeouts:      webauthn.TimeoutsConfig{Login: timeout, Registration: timeout},
	})
	if err != nil {
		return err
	}
	s.webauthn = w
	return nil
}

// passkeyUser adapts an account to webauthn.User.
type passkeyUser struct {
	handle []byte
	name   string
	creds  []webauthn.Credential
}

func (u *passkeyUser) WebAuthnID() []byte                         { return u.handle }
func (u *passkeyUser) WebAuthnName() string                       { return u.name }
func (u *passkeyUser) WebAuthnDisplayName() string                { return u.name }
func (u *passkeyUser) WebAuthnCredentials() []webauthn.Credential { return u.creds }

// decodeB64URL accepts base64url with or without padding.
func decodeB64URL(s string) ([]byte, error) {
	b, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(s, "="))
	if err != nil {
		return nil, err
	}
	if len(b) == 0 || len(b) > maxPasskeyFieldBytes {
		return nil, errors.New("bad length")
	}
	return b, nil
}

func b64URL(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// parseAttestation rebuilds the standard PublicKeyCredential JSON from the
// raw fields the client sends and parses it.
func parseAttestation(credID, clientData, attObj []byte) (*protocol.ParsedCredentialCreationData, error) {
	raw, err := json.Marshal(map[string]any{
		"id":    b64URL(credID),
		"rawId": b64URL(credID),
		"type":  string(protocol.PublicKeyCredentialType),
		"response": map[string]string{
			"clientDataJSON":    b64URL(clientData),
			"attestationObject": b64URL(attObj),
		},
		"clientExtensionResults": map[string]any{},
	})
	if err != nil {
		return nil, err
	}
	return protocol.ParseCredentialCreationResponseBytes(raw)
}

// parseAssertion is parseAttestation for a sign-in assertion.
func parseAssertion(credID, clientData, authData, sig, userHandle []byte) (*protocol.ParsedCredentialAssertionData, error) {
	raw, err := json.Marshal(map[string]any{
		"id":    b64URL(credID),
		"rawId": b64URL(credID),
		"type":  string(protocol.PublicKeyCredentialType),
		"response": map[string]string{
			"clientDataJSON":    b64URL(clientData),
			"authenticatorData": b64URL(authData),
			"signature":         b64URL(sig),
			"userHandle":        b64URL(userHandle),
		},
		"clientExtensionResults": map[string]any{},
	})
	if err != nil {
		return nil, err
	}
	return protocol.ParseCredentialRequestResponseBytes(raw)
}

func (s *Server) passkeysUnavailable(w http.ResponseWriter) bool {
	if s.webauthn == nil {
		httpError(w, http.StatusServiceUnavailable, "passkeys not configured")
		return true
	}
	return false
}

// beginPasskeyRegistration starts a registration ceremony: discoverable
// credential, UV required, no attestation.
func (s *Server) beginPasskeyRegistration(user *passkeyUser, exclude []protocol.CredentialDescriptor) (*protocol.CredentialCreation, *webauthn.SessionData, error) {
	requireRK := true
	return s.webauthn.BeginRegistration(user,
		webauthn.WithAuthenticatorSelection(protocol.AuthenticatorSelection{
			RequireResidentKey: &requireRK,
			ResidentKey:        protocol.ResidentKeyRequirementRequired,
			UserVerification:   protocol.VerificationRequired,
		}),
		webauthn.WithConveyancePreference(protocol.PreferNoAttestation),
		webauthn.WithExclusions(exclude))
}

func (s *Server) handlePasskeyRegisterOptions(w http.ResponseWriter, _ *http.Request, dev *store.Device) {
	if s.passkeysUnavailable(w) {
		return
	}
	if s.isDemo(dev.AccountID) {
		httpError(w, http.StatusForbidden, errPasskeyDemo)
		return
	}
	handle, username, err := s.store.PasskeyUserHandle(dev.AccountID)
	if err != nil {
		internalError(w, err)
		return
	}
	existing, err := s.store.ListPasskeys(dev.AccountID)
	if err != nil {
		internalError(w, err)
		return
	}
	if len(existing) >= store.MaxPasskeysPerAccount {
		httpError(w, http.StatusConflict, "passkey limit reached")
		return
	}
	exclude := make([]protocol.CredentialDescriptor, len(existing))
	excludeIDs := make([]string, len(existing))
	for i, p := range existing {
		exclude[i] = protocol.CredentialDescriptor{Type: protocol.PublicKeyCredentialType, CredentialID: p.CredentialID}
		excludeIDs[i] = b64URL(p.CredentialID)
	}
	creation, sd, err := s.beginPasskeyRegistration(&passkeyUser{handle: handle, name: username}, exclude)
	if err != nil {
		internalError(w, err)
		return
	}
	if !s.passkeyReg.put(dev.AccountID, *sd) {
		httpError(w, http.StatusServiceUnavailable, "too many pending passkey requests; try again later")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"challenge":            creation.Response.Challenge.String(),
		"userId":               b64URL(handle),
		"userName":             username,
		"excludeCredentialIds": excludeIDs,
	})
}

func (s *Server) handlePasskeyRegister(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if s.passkeysUnavailable(w) {
		return
	}
	var req struct {
		CredentialID      string `json:"credentialId"`
		ClientDataJSON    string `json:"clientDataJSON"`
		AttestationObject string `json:"attestationObject"`
		Name              string `json:"name"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "invalid body")
		return
	}
	credID, err1 := decodeB64URL(req.CredentialID)
	clientData, err2 := decodeB64URL(req.ClientDataJSON)
	attObj, err3 := decodeB64URL(req.AttestationObject)
	if err1 != nil || err2 != nil || err3 != nil {
		httpError(w, http.StatusBadRequest, "credentialId, clientDataJSON and attestationObject (base64url) required")
		return
	}
	name := strings.TrimSpace(req.Name)
	if !utf8.ValidString(name) || utf8.RuneCountInString(name) > maxPasskeyNameRunes {
		httpError(w, http.StatusBadRequest, "name must be at most 64 characters")
		return
	}
	sd, ok := s.passkeyReg.take(dev.AccountID)
	if !ok {
		httpError(w, http.StatusBadRequest, "no pending passkey registration; request options again")
		return
	}
	parsed, err := parseAttestation(credID, clientData, attObj)
	if err != nil {
		httpError(w, http.StatusBadRequest, "passkey verification failed")
		return
	}
	cred, err := s.webauthn.CreateCredential(&passkeyUser{handle: sd.UserID}, sd, parsed)
	if err != nil || !bytes.Equal(cred.ID, credID) || !cred.Flags.UserVerified {
		httpError(w, http.StatusBadRequest, "passkey verification failed")
		return
	}
	stored, err := json.Marshal(cred)
	if err != nil {
		internalError(w, err)
		return
	}
	switch err := s.store.AddPasskey(dev.AccountID, cred.ID, stored, name); {
	case errors.Is(err, store.ErrPasskeyLimit):
		httpError(w, http.StatusConflict, "passkey limit reached")
		return
	case errors.Is(err, store.ErrPasskeyExists):
		httpError(w, http.StatusConflict, "passkey already registered")
		return
	case err != nil:
		internalError(w, err)
		return
	}
	s.noticeAccountChange(dev, store.NoticePasskeyAdded)
	writeJSON(w, http.StatusCreated, map[string]string{"id": b64URL(cred.ID)})
}

func (s *Server) handleListPasskeys(w http.ResponseWriter, _ *http.Request, dev *store.Device) {
	list, err := s.store.ListPasskeys(dev.AccountID)
	if err != nil {
		internalError(w, err)
		return
	}
	out := make([]map[string]any, len(list))
	for i, p := range list {
		out[i] = map[string]any{"id": b64URL(p.CredentialID), "name": p.Name, "createdAt": p.CreatedAt}
	}
	writeJSON(w, http.StatusOK, map[string]any{"passkeys": out})
}

func (s *Server) handleDeletePasskey(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	id, err := decodeB64URL(r.PathValue("id"))
	if err != nil {
		httpError(w, http.StatusNotFound, "no such passkey")
		return
	}
	if err := s.store.DeletePasskey(dev.AccountID, id); errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusNotFound, "no such passkey")
		return
	} else if err != nil {
		internalError(w, err)
		return
	}
	s.noticeAccountChange(dev, store.NoticePasskeyRemoved)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handlePasskeyLoginOptions(w http.ResponseWriter, r *http.Request) {
	if !passkeyOptionsIPLimiter.allow(clientIP(r)) {
		httpError(w, http.StatusTooManyRequests, "too many attempts; try again later")
		return
	}
	if s.passkeysUnavailable(w) {
		return
	}
	assertion, sd, err := s.webauthn.BeginDiscoverableLogin(webauthn.WithUserVerification(protocol.VerificationRequired))
	if err != nil {
		internalError(w, err)
		return
	}
	sessionID, err := newPasskeySessionID()
	if err != nil {
		internalError(w, err)
		return
	}
	if !s.passkeyLogin.put(sessionID, *sd) {
		httpError(w, http.StatusServiceUnavailable, "too many pending passkey requests; try again later")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"challenge": assertion.Response.Challenge.String(),
		"sessionId": sessionID,
	})
}

func (s *Server) handlePasskeyLogin(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	// A passkey can't be guessed, so failures don't count toward the shared
	// per-address lockout that would also block other people behind a proxy.
	if !passkeyLoginIPLimiter.allow(ip) {
		httpError(w, http.StatusTooManyRequests, "too many attempts; try again later")
		return
	}
	if s.passkeysUnavailable(w) {
		return
	}
	var req struct {
		SessionID         string `json:"sessionId"`
		CredentialID      string `json:"credentialId"`
		ClientDataJSON    string `json:"clientDataJSON"`
		AuthenticatorData string `json:"authenticatorData"`
		Signature         string `json:"signature"`
		UserHandle        string `json:"userHandle"`
		Password          string `json:"password"`
	}
	if err := decodeJSON(r, &req); err != nil || req.SessionID == "" || len(req.SessionID) > 128 ||
		len(req.Password) < 8 || len(req.Password) > maxPasswordBytes {
		httpError(w, http.StatusBadRequest, "sessionId and password (8–1024 chars) required")
		return
	}
	credID, err1 := decodeB64URL(req.CredentialID)
	clientData, err2 := decodeB64URL(req.ClientDataJSON)
	authData, err3 := decodeB64URL(req.AuthenticatorData)
	sig, err4 := decodeB64URL(req.Signature)
	userHandle, err5 := decodeB64URL(req.UserHandle)
	if err1 != nil || err2 != nil || err3 != nil || err4 != nil || err5 != nil {
		httpError(w, http.StatusBadRequest, "credentialId, clientDataJSON, authenticatorData, signature and userHandle (base64url) required")
		return
	}
	fail := func() { httpError(w, http.StatusUnauthorized, errPasskeySignInFails) }
	sd, ok := s.passkeyLogin.take(req.SessionID)
	if !ok {
		fail()
		return
	}
	parsed, err := parseAssertion(credID, clientData, authData, sig, userHandle)
	if err != nil {
		fail()
		return
	}
	var accountID string
	var demo bool
	lookup := func(rawID, handle []byte) (webauthn.User, error) {
		id, username, isDemo, err := s.store.PasskeyAccount(handle)
		if err != nil {
			return nil, err
		}
		list, err := s.store.ListPasskeys(id)
		if err != nil {
			return nil, err
		}
		u := &passkeyUser{handle: handle, name: username}
		owned := false
		for _, p := range list {
			var c webauthn.Credential
			if err := json.Unmarshal(p.Credential, &c); err != nil {
				return nil, err
			}
			owned = owned || bytes.Equal(c.ID, rawID)
			u.creds = append(u.creds, c)
		}
		if !owned {
			return nil, store.ErrNotFound
		}
		accountID, demo = id, isDemo
		return u, nil
	}
	cred, err := s.webauthn.ValidateDiscoverableLogin(lookup, sd, parsed)
	if err != nil || accountID == "" || cred.Authenticator.CloneWarning {
		fail()
		return
	}
	if demo {
		httpError(w, http.StatusForbidden, errPasskeyDemo)
		return
	}
	stored, err := json.Marshal(cred)
	if err != nil {
		internalError(w, err)
		return
	}
	dev, err := s.store.ProvisionPasskeyDevice(accountID, cred.ID, stored, req.Password)
	switch {
	case errors.Is(err, store.ErrNotFound):
		fail()
		return
	case errors.Is(err, store.ErrDeviceLimit):
		httpError(w, http.StatusConflict, "device limit reached; unlink a device first")
		return
	case err != nil:
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"accountId": dev.AccountID,
		"deviceId":  dev.DeviceID,
		"username":  dev.Username,
		"mailboxId": dev.MailboxID,
		"created":   false,
	})
	s.retireReplacedDevices(dev)
}

func newPasskeySessionID() (string, error) {
	var id [32]byte
	if _, err := rand.Read(id[:]); err != nil {
		return "", err
	}
	return b64URL(id[:]), nil
}

// handlePasskeySignupOptions starts a sign-up with a passkey and no email:
// a fresh user handle and a registration ceremony for the requested username.
func (s *Server) handlePasskeySignupOptions(w http.ResponseWriter, r *http.Request) {
	if !passkeyOptionsIPLimiter.allow("signup:" + clientIP(r)) {
		httpError(w, http.StatusTooManyRequests, "too many attempts; try again later")
		return
	}
	if s.passkeysUnavailable(w) {
		return
	}
	var req struct {
		Username string `json:"username"`
	}
	if err := decodeJSON(r, &req); err != nil || !validUsername.MatchString(req.Username) {
		httpError(w, http.StatusBadRequest, "username must be 1–64 alphanumeric/._- characters")
		return
	}
	if taken, err := s.store.UsernameTaken(req.Username); err != nil {
		internalError(w, err)
		return
	} else if taken {
		httpError(w, http.StatusConflict, "username already taken")
		return
	}
	handle := make([]byte, 32)
	if _, err := rand.Read(handle); err != nil {
		internalError(w, err)
		return
	}
	creation, sd, err := s.beginPasskeyRegistration(&passkeyUser{handle: handle, name: req.Username}, nil)
	if err != nil {
		internalError(w, err)
		return
	}
	sessionID, err := newPasskeySessionID()
	if err != nil {
		internalError(w, err)
		return
	}
	if !s.passkeySignup.putNamed(sessionID, *sd, req.Username) {
		httpError(w, http.StatusServiceUnavailable, "too many pending passkey requests; try again later")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"sessionId": sessionID,
		"challenge": creation.Response.Challenge.String(),
		"userId":    b64URL(handle),
		"userName":  req.Username,
	})
}

// handlePasskeySignup verifies the sign-up registration and creates the
// account (no email, no account password) with device 1 and the passkey.
func (s *Server) handlePasskeySignup(w http.ResponseWriter, r *http.Request) {
	if !accountCreationLimiter.allow("passkey:" + clientIP(r)) {
		httpError(w, http.StatusTooManyRequests, "registration rate limit exceeded; try again later")
		return
	}
	if s.passkeysUnavailable(w) {
		return
	}
	var req struct {
		SessionID         string `json:"sessionId"`
		CredentialID      string `json:"credentialId"`
		ClientDataJSON    string `json:"clientDataJSON"`
		AttestationObject string `json:"attestationObject"`
		Password          string `json:"password"`
		Name              string `json:"name"`
	}
	if err := decodeJSON(r, &req); err != nil || req.SessionID == "" || len(req.SessionID) > 128 ||
		len(req.Password) < 8 || len(req.Password) > maxPasswordBytes {
		httpError(w, http.StatusBadRequest, "sessionId and password (8–1024 chars) required")
		return
	}
	credID, err1 := decodeB64URL(req.CredentialID)
	clientData, err2 := decodeB64URL(req.ClientDataJSON)
	attObj, err3 := decodeB64URL(req.AttestationObject)
	if err1 != nil || err2 != nil || err3 != nil {
		httpError(w, http.StatusBadRequest, "credentialId, clientDataJSON and attestationObject (base64url) required")
		return
	}
	name := strings.TrimSpace(req.Name)
	if !utf8.ValidString(name) || utf8.RuneCountInString(name) > maxPasskeyNameRunes {
		httpError(w, http.StatusBadRequest, "name must be at most 64 characters")
		return
	}
	sess, ok := s.passkeySignup.takeNamed(req.SessionID)
	if !ok {
		httpError(w, http.StatusUnauthorized, errPasskeySignUpFails)
		return
	}
	parsed, err := parseAttestation(credID, clientData, attObj)
	if err != nil {
		httpError(w, http.StatusUnauthorized, errPasskeySignUpFails)
		return
	}
	cred, err := s.webauthn.CreateCredential(&passkeyUser{handle: sess.UserID, name: sess.username}, sess.SessionData, parsed)
	if err != nil || !bytes.Equal(cred.ID, credID) || !cred.Flags.UserVerified {
		httpError(w, http.StatusUnauthorized, errPasskeySignUpFails)
		return
	}
	stored, err := json.Marshal(cred)
	if err != nil {
		internalError(w, err)
		return
	}
	dev, err := s.store.CreatePasskeyAccount(sess.username, sess.UserID, cred.ID, stored, name, req.Password)
	switch {
	case errors.Is(err, store.ErrUsernameTaken):
		httpError(w, http.StatusConflict, "username already taken")
		return
	case errors.Is(err, store.ErrPasskeyExists):
		httpError(w, http.StatusConflict, "passkey already registered")
		return
	case err != nil:
		internalError(w, err)
		return
	}
	s.reindexAccount(dev.AccountID)
	writeJSON(w, http.StatusCreated, map[string]any{
		"accountId": dev.AccountID,
		"deviceId":  dev.DeviceID,
		"username":  dev.Username,
		"mailboxId": dev.MailboxID,
		"created":   true,
	})
}

// accountPasskeyUser loads the account's stored credentials and, if it has
// any, its user handle.
func (s *Server) accountPasskeyUser(accountID string) (*passkeyUser, error) {
	list, err := s.store.ListPasskeys(accountID)
	if err != nil || len(list) == 0 {
		return &passkeyUser{}, err
	}
	handle, username, err := s.store.PasskeyUserHandle(accountID)
	if err != nil {
		return nil, err
	}
	u := &passkeyUser{handle: handle, name: username}
	for _, p := range list {
		var c webauthn.Credential
		if err := json.Unmarshal(p.Credential, &c); err != nil {
			return nil, err
		}
		u.creds = append(u.creds, c)
	}
	return u, nil
}

// handleRemoveEmailOptions starts the passkey assertion that authorises
// removing the account's email, restricted to the account's own passkeys.
func (s *Server) handleRemoveEmailOptions(w http.ResponseWriter, _ *http.Request, dev *store.Device) {
	if s.passkeysUnavailable(w) {
		return
	}
	if s.isDemo(dev.AccountID) {
		httpError(w, http.StatusForbidden, errPasskeyDemo)
		return
	}
	user, err := s.accountPasskeyUser(dev.AccountID)
	if err != nil {
		internalError(w, err)
		return
	}
	if len(user.creds) == 0 {
		httpError(w, http.StatusConflict, "add a passkey first")
		return
	}
	assertion, sd, err := s.webauthn.BeginLogin(user, webauthn.WithUserVerification(protocol.VerificationRequired))
	if err != nil {
		internalError(w, err)
		return
	}
	if !s.passkeyEmailRemove.put(dev.AccountID, *sd) {
		httpError(w, http.StatusServiceUnavailable, "too many pending passkey requests; try again later")
		return
	}
	ids := make([]string, len(user.creds))
	for i, c := range user.creds {
		ids[i] = b64URL(c.ID)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"challenge":     assertion.Response.Challenge.String(),
		"credentialIds": ids,
	})
}

// handleRemoveEmail verifies the assertion, deletes the linked Supabase user
// and unlinks the email: no email token, no Supabase link, no email
// discovery.
func (s *Server) handleRemoveEmail(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if s.passkeysUnavailable(w) {
		return
	}
	if s.isDemo(dev.AccountID) {
		httpError(w, http.StatusForbidden, errPasskeyDemo)
		return
	}
	var req struct {
		CredentialID      string `json:"credentialId"`
		ClientDataJSON    string `json:"clientDataJSON"`
		AuthenticatorData string `json:"authenticatorData"`
		Signature         string `json:"signature"`
		UserHandle        string `json:"userHandle"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "invalid body")
		return
	}
	credID, err1 := decodeB64URL(req.CredentialID)
	clientData, err2 := decodeB64URL(req.ClientDataJSON)
	authData, err3 := decodeB64URL(req.AuthenticatorData)
	sig, err4 := decodeB64URL(req.Signature)
	userHandle, err5 := decodeB64URL(req.UserHandle)
	if err1 != nil || err2 != nil || err3 != nil || err4 != nil || err5 != nil {
		httpError(w, http.StatusBadRequest, "credentialId, clientDataJSON, authenticatorData, signature and userHandle (base64url) required")
		return
	}
	sd, ok := s.passkeyEmailRemove.take(dev.AccountID)
	if !ok {
		httpError(w, http.StatusUnauthorized, errPasskeyCheckFails)
		return
	}
	parsed, err := parseAssertion(credID, clientData, authData, sig, userHandle)
	if err != nil {
		httpError(w, http.StatusUnauthorized, errPasskeyCheckFails)
		return
	}
	user, err := s.accountPasskeyUser(dev.AccountID)
	if err != nil {
		internalError(w, err)
		return
	}
	cred, err := s.webauthn.ValidateLogin(user, sd, parsed)
	if err != nil || cred.Authenticator.CloneWarning {
		httpError(w, http.StatusUnauthorized, errPasskeyCheckFails)
		return
	}
	stored, err := json.Marshal(cred)
	if err != nil {
		internalError(w, err)
		return
	}
	if err := s.store.UpdatePasskeyCredential(dev.AccountID, cred.ID, stored); errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusUnauthorized, errPasskeyCheckFails)
		return
	} else if err != nil {
		internalError(w, err)
		return
	}
	supabaseUserID, err := s.store.SupabaseUserID(dev.AccountID)
	if err != nil {
		internalError(w, err)
		return
	}
	if supabaseUserID != "" {
		if s.supabaseServiceKey == "" {
			slog.Warn("email removal: supabase user not deleted (no service key)")
		}
		// The policy promises the address is gone from the sign-in provider
		// too, so a failed delete fails the request (the user can retry).
		if err := s.deleteSupabaseUser(context.WithoutCancel(r.Context()), supabaseUserID); err != nil {
			httpError(w, http.StatusBadGateway, "Couldn't remove your email from our sign-in provider. Please try again.")
			return
		}
	}
	if err := s.store.RemoveAccountEmail(dev.AccountID); errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusNotFound, "no such account")
		return
	} else if err != nil {
		internalError(w, err)
		return
	}
	s.noticeAccountChange(dev, store.NoticeEmailRemoved)
	w.WriteHeader(http.StatusNoContent)
}
