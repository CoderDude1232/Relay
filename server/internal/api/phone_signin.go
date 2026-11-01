package api

import (
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/relayapp/relay-server/internal/limitkey"
	"github.com/relayapp/relay-server/internal/store"
)

// Signing in (or up) with a phone number from a new device:
//
//  1. POST /v1/app-attest/challenge, then POST /v1/app-attest/keys once per
//     install: the app's App Attest key, attested by Apple.
//  2. POST /v1/phone/start {phone, keyId, assertion, challenge}: an assertion
//     by that key over a fresh challenge and the number, so only a genuine
//     copy of the app can make the relay send a text.
//  3. POST /v1/phone/signin {phone, code, password}: signs in to the number's
//     account (423 with a ticket when it has two-step verification), or, for
//     a new number, 404 with a signup ticket for POST /v1/phone/signup.

// appAttestVerifier is implemented by appattest.Verifier.
type appAttestVerifier interface {
	VerifyAttestation(keyID, attestation, clientDataHash []byte, now time.Time) ([]byte, error)
	VerifyAssertion(publicKey, assertion, clientDataHash []byte, previous uint32) (uint32, error)
}

// SetAppAttest requires App Attest for unauthenticated phone codes. Without
// it (and without SetPhoneSignInWithoutAppAttest) phone sign-in is off.
func (s *Server) SetAppAttest(v appAttestVerifier) { s.appAttest = v }

// SetPhoneSignInWithoutAppAttest allows unauthenticated phone codes without
// App Attest. Development only (the simulator has no App Attest).
func (s *Server) SetPhoneSignInWithoutAppAttest(allow bool) { s.phoneWithoutAttest = allow }

const (
	appAttestChallengeTTL  = 5 * time.Minute
	maxAppAttestChallenges = 20000
	phoneSignupTTL         = 15 * time.Minute
	maxPhoneSignups        = 5000
)

var (
	appAttestChallengeIPLimiter = newSlidingWindowLimiter(60, time.Hour)
	appAttestKeyIPLimiter       = newSlidingWindowLimiter(10, 24*time.Hour)
)

type challengeSet struct {
	mu sync.Mutex
	m  map[string]time.Time
}

var appAttestChallenges = &challengeSet{m: map[string]time.Time{}}

func (c *challengeSet) issue() (string, error) {
	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	id := b64URL(raw[:])
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.m) >= maxAppAttestChallenges {
		c.pruneLocked(time.Now())
		if len(c.m) >= maxAppAttestChallenges {
			return "", errors.New("too many pending requests; try again later")
		}
	}
	c.m[id] = time.Now().Add(appAttestChallengeTTL)
	return id, nil
}

// take consumes an unexpired challenge.
func (c *challengeSet) take(id string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	exp, ok := c.m[id]
	delete(c.m, id)
	return ok && time.Now().Before(exp)
}

func (c *challengeSet) prune() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.pruneLocked(time.Now())
}

func (c *challengeSet) pruneLocked(now time.Time) {
	for id, exp := range c.m {
		if now.After(exp) {
			delete(c.m, id)
		}
	}
}

// Client data the app signs. Domain-separated, and the start binds the number
// so an assertion can't be spent on another one.
func attestKeyClientData(challenge string) []byte {
	h := sha256.Sum256([]byte("relay-app-attest-key-v1|" + challenge))
	return h[:]
}

func phoneStartClientData(challenge, phone string) []byte {
	h := sha256.Sum256([]byte("relay-phone-start-v1|" + challenge + "|" + phone))
	return h[:]
}

// POST /v1/app-attest/challenge → {challenge}, single use, 5 minutes.
func (s *Server) handleAppAttestChallenge(w http.ResponseWriter, r *http.Request) {
	if !appAttestChallengeIPLimiter.allow(clientIP(r)) {
		httpError(w, http.StatusTooManyRequests, "too many requests; try again later")
		return
	}
	c, err := appAttestChallenges.issue()
	if err != nil {
		httpError(w, http.StatusTooManyRequests, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"challenge": c})
}

// POST /v1/app-attest/keys {keyId, attestation, challenge} → 204: the key
// can now sign phone-code requests.
func (s *Server) handleAppAttestKey(w http.ResponseWriter, r *http.Request) {
	if s.appAttest == nil {
		httpError(w, http.StatusServiceUnavailable, "App Attest isn't available")
		return
	}
	if !appAttestKeyIPLimiter.allow(clientIP(r)) {
		httpError(w, http.StatusTooManyRequests, "too many requests; try again later")
		return
	}
	var req struct {
		KeyID       string `json:"keyId"`
		Attestation string `json:"attestation"`
		Challenge   string `json:"challenge"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "keyId, attestation and challenge required")
		return
	}
	keyID, err1 := decodeB64URL(req.KeyID)
	attestation, err2 := decodeB64URL(req.Attestation)
	if err1 != nil || err2 != nil || len(keyID) != sha256.Size || len(attestation) == 0 || len(attestation) > 16<<10 {
		httpError(w, http.StatusBadRequest, "keyId (32 bytes) and attestation (base64url) required")
		return
	}
	if !appAttestChallenges.take(req.Challenge) {
		httpError(w, http.StatusUnauthorized, "challenge expired; get a new one")
		return
	}
	pub, err := s.appAttest.VerifyAttestation(keyID, attestation, attestKeyClientData(req.Challenge), time.Now())
	if err != nil {
		slog.Info("app attest: attestation refused", "err", err)
		httpError(w, http.StatusForbidden, "this device couldn't be verified")
		return
	}
	if err := s.store.PutAppAttestKey(keyID, pub); err != nil {
		internalError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// POST /v1/phone/start {phone, keyId, assertion, challenge} → 204 once a code
// is on its way.
func (s *Server) handlePhoneSignInStart(w http.ResponseWriter, r *http.Request) {
	if s.phone == nil || s.oprf == nil || (s.appAttest == nil && !s.phoneWithoutAttest) {
		httpError(w, http.StatusServiceUnavailable, "phone sign-in isn't available yet")
		return
	}
	var req struct {
		Phone     string `json:"phone"`
		KeyID     string `json:"keyId"`
		Assertion string `json:"assertion"`
		Challenge string `json:"challenge"`
	}
	if err := decodeJSON(r, &req); err != nil || !e164.MatchString(req.Phone) {
		httpError(w, http.StatusBadRequest, "phone must be in international format, like +61412345678")
		return
	}
	if !s.phone.allowedNumber(req.Phone) {
		httpError(w, http.StatusUnprocessableEntity, "phone numbers from this country aren't supported yet")
		return
	}
	callerKey := "ip:" + clientIP(r)
	if s.appAttest != nil {
		keyID, err1 := decodeB64URL(req.KeyID)
		assertion, err2 := decodeB64URL(req.Assertion)
		if err1 != nil || err2 != nil || len(keyID) != sha256.Size || len(assertion) == 0 || len(assertion) > 4<<10 {
			httpError(w, http.StatusBadRequest, "keyId and assertion (base64url) required")
			return
		}
		if !appAttestChallenges.take(req.Challenge) {
			httpError(w, http.StatusUnauthorized, "challenge expired; get a new one")
			return
		}
		pub, previous, err := s.store.AppAttestKey(keyID)
		if errors.Is(err, store.ErrNotFound) {
			// Unknown (or purged) key: the app attests a new one and retries.
			httpError(w, http.StatusPreconditionFailed, "attest this device first")
			return
		} else if err != nil {
			internalError(w, err)
			return
		}
		counter, err := s.appAttest.VerifyAssertion(pub, assertion, phoneStartClientData(req.Challenge, req.Phone), previous)
		if err != nil {
			slog.Info("app attest: assertion refused", "err", err)
			httpError(w, http.StatusForbidden, "this device couldn't be verified")
			return
		}
		if ok, err := s.store.AdvanceAppAttestCounter(keyID, counter); err != nil {
			internalError(w, err)
			return
		} else if !ok {
			httpError(w, http.StatusForbidden, "this device couldn't be verified")
			return
		}
		callerKey = limitkey.Hash("attest-key", string(keyID))
	}
	if s.sendPhoneCode(w, r, req.Phone, phoneStartKeyLimiter, callerKey) {
		w.WriteHeader(http.StatusNoContent)
	}
}

// POST /v1/phone/signin {phone, code, password} → 200 {accountId, deviceId,
// username, mailboxId, created:false}; 423 with a two-step ticket; or, when
// no account has the number, 404 {signupTicket}.
func (s *Server) handlePhoneSignIn(w http.ResponseWriter, r *http.Request) {
	if s.phone == nil || s.oprf == nil {
		httpError(w, http.StatusServiceUnavailable, "phone sign-in isn't available yet")
		return
	}
	var req struct {
		Phone    string `json:"phone"`
		Code     string `json:"code"`
		Password string `json:"password"`
	}
	if err := decodeJSON(r, &req); err != nil || !e164.MatchString(req.Phone) ||
		len(req.Code) < 4 || len(req.Code) > 10 || len(req.Password) < 8 || len(req.Password) > maxPasswordBytes {
		httpError(w, http.StatusBadRequest, "phone, code and password (8–1024 chars) required")
		return
	}
	if !phoneSignInNumberLimiter.allow(limitkey.Hash("phone-signin", req.Phone)) || !phoneSignInIPLimiter.allow(clientIP(r)) {
		httpError(w, http.StatusTooManyRequests, "too many tries; try again later")
		return
	}
	ok, err := s.phone.verifier.Check(r.Context(), req.Phone, req.Code)
	if err != nil {
		slog.Warn("phone: twilio check failed", "err", err)
		httpError(w, http.StatusBadGateway, "couldn't check the code; try again")
		return
	}
	if !ok {
		httpError(w, http.StatusUnauthorized, "that code isn't right or has expired")
		return
	}
	token := s.oprf.Token(req.Phone)
	accountID, demo, err := s.store.AccountByPhoneToken(token)
	switch {
	case errors.Is(err, store.ErrNotFound):
		ticket, err := s.phoneSignup.issue(token)
		if err != nil {
			httpError(w, http.StatusTooManyRequests, err.Error())
			return
		}
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "username required", "signupTicket": ticket})
		return
	case err != nil:
		internalError(w, err)
		return
	case demo:
		httpError(w, http.StatusForbidden, demoForbiddenMessage)
		return
	}
	twoStep, err := s.store.TwoStepFor(accountID)
	if err != nil {
		internalError(w, err)
		return
	}
	if twoStep.Method != store.TwoStepNone {
		s.writeTwoStepRequired(w, accountID, twoStep.Method, "")
		return
	}
	s.finishSignIn(w, accountID, req.Password)
}

// POST /v1/phone/signup {signupTicket, username, password, discoverable} →
// 201 {accountId, deviceId, username, mailboxId, created:true}.
func (s *Server) handlePhoneSignup(w http.ResponseWriter, r *http.Request) {
	if s.phone == nil || s.oprf == nil {
		httpError(w, http.StatusServiceUnavailable, "phone sign-in isn't available yet")
		return
	}
	if !accountCreationLimiter.allow("phone:" + clientIP(r)) {
		httpError(w, http.StatusTooManyRequests, "registration rate limit exceeded; try again later")
		return
	}
	var req struct {
		SignupTicket string `json:"signupTicket"`
		Username     string `json:"username"`
		Password     string `json:"password"`
		Discoverable bool   `json:"discoverable"`
	}
	if err := decodeJSON(r, &req); err != nil || !validUsername.MatchString(req.Username) ||
		len(req.Password) < 8 || len(req.Password) > maxPasswordBytes {
		httpError(w, http.StatusBadRequest, "signupTicket, username (1–64 alphanumeric/._- chars) and password (8–1024 chars) required")
		return
	}
	token, ok := s.phoneSignup.get(req.SignupTicket)
	if !ok {
		httpError(w, http.StatusUnauthorized, "this sign-up has expired; verify your number again")
		return
	}
	dev, err := s.store.CreatePhoneAccount(req.Username, token, req.Discoverable, req.Password)
	switch {
	case errors.Is(err, store.ErrUsernameTaken):
		// The ticket stays, so another name can be tried.
		httpError(w, http.StatusConflict, "username already taken")
		return
	case errors.Is(err, store.ErrIdentityInUse):
		s.phoneSignup.consume(req.SignupTicket)
		httpError(w, http.StatusConflict, errSignInInstead)
		return
	case err != nil:
		internalError(w, err)
		return
	}
	s.phoneSignup.consume(req.SignupTicket)
	s.reindexAccount(dev.AccountID)
	writeJSON(w, http.StatusCreated, map[string]any{
		"accountId": dev.AccountID, "deviceId": dev.DeviceID, "username": dev.Username,
		"mailboxId": dev.MailboxID, "created": true,
	})
}

// phoneSignups holds verified numbers (their tokens) waiting for a username.
type phoneSignups struct {
	mu sync.Mutex
	m  map[string]phoneSignup
}

type phoneSignup struct {
	token   []byte
	expires time.Time
}

func newPhoneSignups() *phoneSignups { return &phoneSignups{m: map[string]phoneSignup{}} }

func (p *phoneSignups) issue(token []byte) (string, error) {
	var raw [24]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	id := b64URL(raw[:])
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.m) >= maxPhoneSignups {
		p.pruneLocked(time.Now())
		if len(p.m) >= maxPhoneSignups {
			return "", errors.New("too many pending sign-ups; try again later")
		}
	}
	p.m[id] = phoneSignup{token: token, expires: time.Now().Add(phoneSignupTTL)}
	return id, nil
}

func (p *phoneSignups) get(id string) ([]byte, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	e, ok := p.m[id]
	if !ok || time.Now().After(e.expires) {
		delete(p.m, id)
		return nil, false
	}
	return e.token, true
}

func (p *phoneSignups) consume(id string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	delete(p.m, id)
}

func (p *phoneSignups) prune() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.pruneLocked(time.Now())
}

func (p *phoneSignups) pruneLocked(now time.Time) {
	for id, e := range p.m {
		if now.After(e.expires) {
			delete(p.m, id)
		}
	}
}
