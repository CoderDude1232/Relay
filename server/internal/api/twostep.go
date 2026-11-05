package api

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/subtle"
	"encoding/base32"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"slices"
	"sync"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/relayapp/relay-server/internal/store"
)

// Two-step verification. A sign-in by email or phone code to an account that
// has turned it on answers 423 with a ticket naming the second step; the app
// completes it at POST /v1/accounts/two-step (or signs in with the recovery
// key instead). See store/twostep.go for the methods.

const (
	twoStepTicketTTL  = 10 * time.Minute
	maxTwoStepTickets = 10000
	// maxTicketFailures ends a ticket after this many wrong answers; the
	// per-account lockout (recoveryLockout) bounds guessing across tickets.
	maxTicketFailures = 5

	totpPeriod   = 30
	totpDigits   = 6
	totpSkew     = 1 // steps either side, for clock drift
	totpSetupTTL = 10 * time.Minute
)

type twoStepTicket struct {
	accountID string
	// method lists the methods (comma joined) any one of which passes.
	method string
	// identity back-fills the account's links once the step passes (a
	// sign-in that found the account by its verified email).
	identity store.Identity
	failures int
	expires  time.Time
}

type twoStepTickets struct {
	mu sync.Mutex
	m  map[string]*twoStepTicket
}

func newTwoStepTickets() *twoStepTickets { return &twoStepTickets{m: map[string]*twoStepTicket{}} }

func (t *twoStepTickets) issue(accountID, method string, identity store.Identity) (string, error) {
	var raw [24]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	id := b64URL(raw[:])
	t.mu.Lock()
	defer t.mu.Unlock()
	if len(t.m) >= maxTwoStepTickets {
		t.pruneLocked(time.Now())
		if len(t.m) >= maxTwoStepTickets {
			return "", errors.New("too many pending sign-ins; try again later")
		}
	}
	t.m[id] = &twoStepTicket{accountID: accountID, method: method, identity: identity,
		expires: time.Now().Add(twoStepTicketTTL)}
	return id, nil
}

// get returns a copy of the unexpired ticket.
func (t *twoStepTickets) get(id string) (twoStepTicket, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	e, ok := t.m[id]
	if !ok || time.Now().After(e.expires) {
		delete(t.m, id)
		return twoStepTicket{}, false
	}
	return *e, true
}

func (t *twoStepTickets) fail(id string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if e, ok := t.m[id]; ok {
		if e.failures++; e.failures >= maxTicketFailures {
			delete(t.m, id)
		}
	}
}

func (t *twoStepTickets) consume(id string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.m, id)
}

func (t *twoStepTickets) prune() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.pruneLocked(time.Now())
}

func (t *twoStepTickets) pruneLocked(now time.Time) {
	for id, e := range t.m {
		if now.After(e.expires) {
			delete(t.m, id)
		}
	}
}

// writeTwoStepRequired answers a code sign-in that needs its second step.
// methods is comma joined; "method" names the first, for older clients.
func (s *Server) writeTwoStepRequired(w http.ResponseWriter, accountID, methods string, identity store.Identity) {
	list := store.ParseTwoStepMethods(methods)
	if len(list) == 0 {
		list = []string{methods}
	}
	ticket, err := s.twoStep.issue(accountID, store.JoinTwoStepMethods(list), identity)
	if err != nil {
		httpError(w, http.StatusTooManyRequests, err.Error())
		return
	}
	hasRecovery := false
	if m, err := s.store.AccountSignInMethods(accountID); err == nil {
		hasRecovery = m.RecoveryKey
	}
	writeJSON(w, http.StatusLocked, map[string]any{
		"error": "two-step verification required",
		"twoStep": map[string]any{
			"ticket": ticket, "method": list[0], "methods": list,
			// The recovery key always works instead (POST /v1/accounts/recovery-key/signin).
			"recoveryKey": hasRecovery,
		},
	})
}

func (s *Server) refuseTwoStepInUse(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, store.ErrTwoStepInUse):
		httpError(w, http.StatusConflict, "Two-step verification uses this. Choose another method or turn two-step verification off first.")
	default:
		internalError(w, err)
	}
	return true
}

// MARK: TOTP (RFC 6238: HMAC-SHA1, 30 s, 6 digits)

func totpCode(secret []byte, step int64) string {
	m := hmac.New(sha1.New, secret)
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], uint64(step))
	m.Write(b[:])
	sum := m.Sum(nil)
	off := sum[len(sum)-1] & 0x0f
	v := binary.BigEndian.Uint32(sum[off:off+4]) & 0x7fffffff
	return fmt.Sprintf("%0*d", totpDigits, v%1_000_000)
}

// totpMatch returns the time step code is valid for near now, or -1.
func totpMatch(secret []byte, code string, now time.Time) int64 {
	if len(code) != totpDigits {
		return -1
	}
	step := now.Unix() / totpPeriod
	match := int64(-1)
	for d := int64(-totpSkew); d <= totpSkew; d++ {
		if subtle.ConstantTimeCompare([]byte(totpCode(secret, step+d)), []byte(code)) == 1 {
			match = step + d
		}
	}
	return match
}

var totpBase32 = base32.StdEncoding.WithPadding(base32.NoPadding)

// totpAEAD seals authenticator secrets at rest, under a key derived from the
// OPRF key (so there's no other secret to keep).
func (s *Server) totpAEAD() (cipher.AEAD, error) {
	block, err := aes.NewCipher(s.oprf.DeriveKey("relay-totp-secret-v1"))
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func (s *Server) sealTOTP(accountID string, secret []byte) ([]byte, error) {
	aead, err := s.totpAEAD()
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return aead.Seal(nonce, nonce, secret, []byte("totp|"+accountID)), nil
}

func (s *Server) openTOTP(accountID string, sealed []byte) ([]byte, error) {
	aead, err := s.totpAEAD()
	if err != nil {
		return nil, err
	}
	if len(sealed) < aead.NonceSize() {
		return nil, errors.New("totp: sealed secret too short")
	}
	return aead.Open(nil, sealed[:aead.NonceSize()], sealed[aead.NonceSize():], []byte("totp|"+accountID))
}

type pendingTOTP struct {
	secret  []byte
	expires time.Time
}

var (
	totpSetupMu sync.Mutex
	totpSetups  = map[string]pendingTOTP{} // by account id
)

func (s *Server) twoStepUnavailable(w http.ResponseWriter, accountID string) bool {
	if s.oprf == nil {
		httpError(w, http.StatusServiceUnavailable, "two-step verification isn't available")
		return true
	}
	return accountID != "" && s.refuseIfDemo(w, accountID)
}

// POST /v1/accounts/me/totp/setup → {secret, uri}. Nothing changes until
// POST .../totp/confirm accepts a code from the authenticator.
func (s *Server) handleTOTPSetup(w http.ResponseWriter, _ *http.Request, dev *store.Device) {
	if s.twoStepUnavailable(w, dev.AccountID) {
		return
	}
	secret := make([]byte, 20)
	if _, err := rand.Read(secret); err != nil {
		internalError(w, err)
		return
	}
	username := ""
	if u, err := s.store.LookupUsername(dev.AccountID); err == nil {
		username = u
	}
	totpSetupMu.Lock()
	now := time.Now()
	for id, p := range totpSetups {
		if now.After(p.expires) {
			delete(totpSetups, id)
		}
	}
	totpSetups[dev.AccountID] = pendingTOTP{secret: secret, expires: now.Add(totpSetupTTL)}
	totpSetupMu.Unlock()
	encoded := totpBase32.EncodeToString(secret)
	uri := (&url.URL{Scheme: "otpauth", Host: "totp", Path: "/Relay:" + username, RawQuery: url.Values{
		"secret": {encoded}, "issuer": {"Relay"}, "algorithm": {"SHA1"}, "digits": {"6"}, "period": {"30"},
	}.Encode()}).String()
	writeJSON(w, http.StatusOK, map[string]any{"secret": encoded, "uri": uri})
}

// POST /v1/accounts/me/totp/confirm {code} → 204: the authenticator is now
// the two-step method.
func (s *Server) handleTOTPConfirm(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if s.twoStepUnavailable(w, dev.AccountID) {
		return
	}
	var req struct {
		Code string `json:"code"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "code required")
		return
	}
	if !twoStepSettingLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "too many tries; try again later")
		return
	}
	totpSetupMu.Lock()
	pending, ok := totpSetups[dev.AccountID]
	totpSetupMu.Unlock()
	if !ok || time.Now().After(pending.expires) {
		httpError(w, http.StatusConflict, "set up the authenticator again")
		return
	}
	step := totpMatch(pending.secret, req.Code, time.Now())
	if step < 0 {
		httpError(w, http.StatusUnauthorized, "that code isn't right")
		return
	}
	sealed, err := s.sealTOTP(dev.AccountID, pending.secret)
	if err != nil {
		internalError(w, err)
		return
	}
	if err := s.store.SetTOTP(dev.AccountID, sealed, step); err != nil {
		internalError(w, err)
		return
	}
	totpSetupMu.Lock()
	delete(totpSetups, dev.AccountID)
	totpSetupMu.Unlock()
	s.noticeAccountChange(dev, store.NoticeTwoStepChanged)
	w.WriteHeader(http.StatusNoContent)
}

// twoStepSettingLimiter bounds two-step setting changes and authenticator
// confirmations per account.
var twoStepSettingLimiter = newSlidingWindowLimiter(20, time.Hour)

// PUT /v1/accounts/me/two-step {method, enabled?} → 204. With enabled, turns
// that one method ("passkey", "pin", "recovery", or "totp" off) on or off and
// keeps the others; the authenticator is turned on through .../totp/confirm.
// Without it (older clients), method replaces them all: "" (off), "passkey",
// "pin" or "recovery".
func (s *Server) handleSetTwoStep(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if s.twoStepUnavailable(w, dev.AccountID) {
		return
	}
	var req struct {
		Method  *string `json:"method"`
		Enabled *bool   `json:"enabled"`
	}
	if err := decodeJSON(r, &req); err != nil || req.Method == nil {
		httpError(w, http.StatusBadRequest, `method ("", "passkey", "pin" or "recovery") required`)
		return
	}
	if !twoStepSettingLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "too many changes; try again later")
		return
	}
	set := func() error { return s.store.SetTwoStepMethod(dev.AccountID, *req.Method) }
	if req.Enabled != nil {
		set = func() error { return s.store.SetTwoStepEnabled(dev.AccountID, *req.Method, *req.Enabled) }
	}
	switch err := set(); {
	case errors.Is(err, store.ErrTwoStepUnavailable):
		httpError(w, http.StatusConflict, "add a passkey, PIN or recovery key for this method first")
		return
	case err != nil:
		internalError(w, err)
		return
	}
	s.noticeAccountChange(dev, store.NoticeTwoStepChanged)
	w.WriteHeader(http.StatusNoContent)
}

// DELETE /v1/accounts/me/account-password → 204 (the PIN). 409 while it's
// the two-step method.
func (s *Server) handleDeleteAccountPassword(w http.ResponseWriter, _ *http.Request, dev *store.Device) {
	if s.refuseIfDemo(w, dev.AccountID) {
		return
	}
	if s.refuseTwoStepInUse(w, s.store.ClearAccountPassword(dev.AccountID)) {
		return
	}
	s.noticeAccountChange(dev, store.NoticeAccountPasswordRemoved)
	w.WriteHeader(http.StatusNoContent)
}

// MARK: Completing a sign-in

// POST /v1/accounts/two-step/passkey-options {ticket} → {challenge,
// credentialIds}: the assertion for a passkey second step.
func (s *Server) handleTwoStepPasskeyOptions(w http.ResponseWriter, r *http.Request) {
	if s.passkeysUnavailable(w) {
		return
	}
	var req struct {
		Ticket string `json:"ticket"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "ticket required")
		return
	}
	t, ok := s.twoStep.get(req.Ticket)
	if !ok || !slices.Contains(store.ParseTwoStepMethods(t.method), store.TwoStepPasskey) {
		httpError(w, http.StatusUnauthorized, errTwoStepTicket)
		return
	}
	user, err := s.accountPasskeyUser(t.accountID)
	if err != nil {
		internalError(w, err)
		return
	}
	if len(user.creds) == 0 {
		httpError(w, http.StatusConflict, "this account has no passkey; use its recovery key")
		return
	}
	assertion, sd, err := s.webauthn.BeginLogin(user, webauthn.WithUserVerification(protocol.VerificationRequired))
	if err != nil {
		internalError(w, err)
		return
	}
	if err := s.passkeyTwoStep.put(req.Ticket, clientIP(r), *sd); err != nil {
		writePasskeySessionError(w, err)
		return
	}
	ids := make([]string, len(user.creds))
	for i, c := range user.creds {
		ids[i] = b64URL(c.ID)
	}
	writeJSON(w, http.StatusOK, map[string]any{"challenge": assertion.Response.Challenge.String(), "credentialIds": ids})
}

const errTwoStepTicket = "this sign-in has expired; start again"

// twoStepIPLimiter bounds completion attempts per address (the per-account
// lockout bounds them per account).
var twoStepIPLimiter = newSlidingWindowLimiter(60, time.Hour)

// POST /v1/accounts/two-step {ticket, password, code? | accountPasswordKey? |
// credentialId, clientDataJSON, authenticatorData, signature, userHandle} →
// 200, the same body as a sign-in: the account's devices are replaced by
// this one.
func (s *Server) handleCompleteTwoStep(w http.ResponseWriter, r *http.Request) {
	if s.twoStepUnavailable(w, "") {
		return
	}
	if !twoStepIPLimiter.allow(clientIP(r)) {
		httpError(w, http.StatusTooManyRequests, "too many attempts; try again later")
		return
	}
	var req struct {
		Ticket             string `json:"ticket"`
		Password           string `json:"password"`
		Code               string `json:"code"`
		AccountPassword    string `json:"accountPassword"`
		AccountPasswordKey string `json:"accountPasswordKey"`
		CredentialID       string `json:"credentialId"`
		ClientDataJSON     string `json:"clientDataJSON"`
		AuthenticatorData  string `json:"authenticatorData"`
		Signature          string `json:"signature"`
		UserHandle         string `json:"userHandle"`
	}
	if err := decodeJSON(r, &req); err != nil || len(req.Password) < 8 || len(req.Password) > maxPasswordBytes {
		httpError(w, http.StatusBadRequest, "ticket and password (8–1024 chars) required")
		return
	}
	t, ok := s.twoStep.get(req.Ticket)
	if !ok {
		httpError(w, http.StatusUnauthorized, errTwoStepTicket)
		return
	}
	lockKey := registrationLockKey(t.accountID)
	if !recoveryLockout.attempt(lockKey) {
		httpError(w, http.StatusTooManyRequests, "too many attempts; try again later")
		return
	}
	passed, err := s.checkSecondStep(r, req.Ticket, t, req.Code,
		req.AccountPasswordKey, req.AccountPassword,
		[5]string{req.CredentialID, req.ClientDataJSON, req.AuthenticatorData, req.Signature, req.UserHandle})
	if err != nil {
		internalError(w, err)
		return
	}
	if !passed {
		s.twoStep.fail(req.Ticket)
		httpError(w, http.StatusUnauthorized, "that isn't right")
		return
	}
	recoveryLockout.succeed(lockKey)
	s.twoStep.consume(req.Ticket)
	if t.identity != (store.Identity{}) {
		if err := s.store.LinkIdentityIfUnlinked(t.accountID, t.identity); err != nil {
			internalError(w, err)
			return
		}
	}
	s.finishSignIn(w, t.accountID, req.Password)
}

// checkSecondStep verifies the answer, for whichever method it's for: one the
// ticket offered that is still one of the account's.
func (s *Server) checkSecondStep(_ *http.Request, ticketID string, t twoStepTicket, code, pinKey, pinLegacy string, assertion [5]string) (bool, error) {
	ts, err := s.store.TwoStepFor(t.accountID)
	if errors.Is(err, store.ErrAccountNotFound) {
		return false, nil
	} else if err != nil {
		return false, err
	}
	method := store.TwoStepPasskey
	switch {
	case code != "":
		method = store.TwoStepTOTP
	case pinKey != "" || pinLegacy != "":
		method = store.TwoStepPIN
	}
	if !ts.Has(method) || !slices.Contains(store.ParseTwoStepMethods(t.method), method) {
		return false, nil
	}
	switch method {
	case store.TwoStepTOTP:
		if len(ts.TOTPSecret) == 0 {
			return false, nil
		}
		secret, err := s.openTOTP(t.accountID, ts.TOTPSecret)
		if err != nil {
			return false, err
		}
		step := totpMatch(secret, code, time.Now())
		if step < 0 {
			return false, nil
		}
		return s.store.UseTOTPStep(t.accountID, step)
	case store.TwoStepPIN:
		pin, ok := accountPasswordFrom(pinKey, pinLegacy, false)
		if !ok || pin.Empty() {
			return false, nil
		}
		return s.store.CheckAccountPassword(t.accountID, pin)
	case store.TwoStepPasskey:
		var raw [5][]byte
		for i, v := range assertion {
			b, err := decodeB64URL(v)
			if err != nil || len(b) == 0 {
				return false, nil
			}
			raw[i] = b
		}
		sd, ok := s.passkeyTwoStep.take(ticketID)
		if !ok {
			return false, nil
		}
		parsed, err := parseAssertion(raw[0], raw[1], raw[2], raw[3], raw[4])
		if err != nil {
			return false, nil
		}
		user, err := s.accountPasskeyUser(t.accountID)
		if err != nil {
			return false, err
		}
		cred, err := s.webauthn.ValidateLogin(user, sd, parsed)
		if err != nil || cred.Authenticator.CloneWarning {
			return false, nil
		}
		stored, err := json.Marshal(cred)
		if err != nil {
			return false, err
		}
		if err := s.store.UpdatePasskeyCredential(t.accountID, cred.ID, stored); errors.Is(err, store.ErrNotFound) {
			return false, nil
		} else if err != nil {
			return false, err
		}
		return true, nil
	}
	// TwoStepRecovery: only the recovery key's own sign-in.
	return false, nil
}

// finishSignIn replaces the account's devices with a new one and answers
// like a sign-in.
func (s *Server) finishSignIn(w http.ResponseWriter, accountID, devicePassword string) {
	dev, err := s.store.ProvisionReplacementDevice(accountID, devicePassword)
	switch {
	case errors.Is(err, store.ErrNotFound):
		httpError(w, http.StatusUnauthorized, errTwoStepTicket)
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
