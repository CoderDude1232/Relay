package api

import (
	"crypto/sha256"
	"errors"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"

	"github.com/relayapp/relay-server/internal/store"
)

// Step-up: on an account with two-step verification, a signed-in device
// answers the second step again before changing how the account is signed in
// to or which devices it has. Someone with a few minutes on an unlocked phone
// can't link their own device, add their own passkey or number, or switch
// two-step off. One answer covers this device for stepUpTTL, and so does
// signing in (the new device just passed the account's second step). Adding
// protection (turning a method on) never asks.

const stepUpTTL = 15 * time.Minute

type stepUps struct {
	mu sync.Mutex
	m  map[string]time.Time // accountID|deviceID → until
}

func newStepUps() *stepUps { return &stepUps{m: map[string]time.Time{}} }

func stepUpKey(dev *store.Device) string {
	return dev.AccountID + "|" + strconv.FormatUint(uint64(dev.DeviceID), 10)
}

func (s *stepUps) mark(dev *store.Device) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	for k, until := range s.m {
		if now.After(until) {
			delete(s.m, k)
		}
	}
	s.m[stepUpKey(dev)] = now.Add(stepUpTTL)
}

func (s *stepUps) fresh(dev *store.Device) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	until, ok := s.m[stepUpKey(dev)]
	return ok && time.Now().Before(until)
}

// stepUp wraps a sensitive handler: with a two-step method set and no fresh
// answer from this device, it answers 403 {error, stepUp: {method}}.
func (s *Server) stepUp(next authedHandler) authedHandler {
	return func(w http.ResponseWriter, r *http.Request, dev *store.Device) {
		if !s.needsStepUp(w, dev) {
			next(w, r, dev)
		}
	}
}

// needsStepUp answers the step-up 403 (true) unless the account has no second
// step or this device answered it recently, for handlers that ask only for
// some changes.
func (s *Server) needsStepUp(w http.ResponseWriter, dev *store.Device) bool {
	if s.twoStep == nil || s.stepUps.fresh(dev) {
		return false
	}
	ts, err := s.store.TwoStepFor(dev.AccountID)
	if err != nil && !errors.Is(err, store.ErrAccountNotFound) {
		internalError(w, err)
		return true
	}
	if ts.Method == "" {
		return false
	}
	writeJSON(w, http.StatusForbidden, map[string]any{
		"error":  "confirm it's you with two-step verification",
		"stepUp": map[string]any{"method": ts.Method, "methods": ts.Methods},
	})
	return true
}

// POST /v1/accounts/me/two-step/challenge → 200 {ticket, method, challenge?,
// credentialIds?} (challenge for a passkey), or {method: ""} when there's
// nothing to ask: the account has no second step, or this device answered it
// within stepUpTTL.
func (s *Server) handleStepUpChallenge(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	ts, err := s.store.TwoStepFor(dev.AccountID)
	if err != nil {
		internalError(w, err)
		return
	}
	if ts.Method == "" || s.stepUps.fresh(dev) {
		writeJSON(w, http.StatusOK, map[string]any{"method": ""})
		return
	}
	ticket, err := s.twoStep.issue(dev.AccountID, ts.Joined(), store.Identity{})
	if err != nil {
		httpError(w, http.StatusTooManyRequests, err.Error())
		return
	}
	resp := map[string]any{"ticket": ticket, "method": ts.Method, "methods": ts.Methods}
	if ts.Has(store.TwoStepPasskey) && s.webauthn != nil {
		user, err := s.accountPasskeyUser(dev.AccountID)
		if err != nil {
			internalError(w, err)
			return
		}
		if len(user.creds) > 0 {
			assertion, sd, err := s.webauthn.BeginLogin(user, webauthn.WithUserVerification(protocol.VerificationRequired))
			if err != nil {
				internalError(w, err)
				return
			}
			if err := s.passkeyTwoStep.put(ticket, clientIP(r), *sd); err != nil {
				writePasskeySessionError(w, err)
				return
			}
			ids := make([]string, len(user.creds))
			for i, c := range user.creds {
				ids[i] = b64URL(c.ID)
			}
			resp["challenge"] = assertion.Response.Challenge.String()
			resp["credentialIds"] = ids
		}
	}
	writeJSON(w, http.StatusOK, resp)
}

// POST /v1/accounts/me/two-step/verify {ticket, code? | accountPasswordKey? |
// passkey assertion | recoveryAuthKey?} → 204: this device may make sensitive
// changes for the next 15 minutes. 401 wrong answer; 429 locked out.
func (s *Server) handleStepUpVerify(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Ticket             string `json:"ticket"`
		Code               string `json:"code"`
		AccountPasswordKey string `json:"accountPasswordKey"`
		AccountPassword    string `json:"accountPassword"`
		CredentialID       string `json:"credentialId"`
		ClientDataJSON     string `json:"clientDataJSON"`
		AuthenticatorData  string `json:"authenticatorData"`
		Signature          string `json:"signature"`
		UserHandle         string `json:"userHandle"`
		RecoveryAuthKey    string `json:"recoveryAuthKey"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "ticket required")
		return
	}
	lockKey := registrationLockKey(dev.AccountID)
	if !recoveryLockout.attempt(lockKey) {
		httpError(w, http.StatusTooManyRequests, "too many attempts; try again later")
		return
	}
	passed := false
	if req.RecoveryAuthKey != "" {
		// The recovery key always works instead.
		if len(req.RecoveryAuthKey) <= 128 {
			h := sha256.Sum256([]byte(recoveryKeyAuthHashPrefix + req.RecoveryAuthKey))
			accountID, _, err := s.store.RecoveryKeyAccount(h[:])
			if err != nil && !errors.Is(err, store.ErrNotFound) {
				internalError(w, err)
				return
			}
			passed = err == nil && accountID == dev.AccountID
		}
	} else {
		t, ok := s.twoStep.get(req.Ticket)
		if !ok || t.accountID != dev.AccountID {
			httpError(w, http.StatusUnauthorized, errTwoStepTicket)
			return
		}
		var err error
		passed, err = s.checkSecondStep(r, req.Ticket, t, req.Code, req.AccountPasswordKey, req.AccountPassword,
			[5]string{req.CredentialID, req.ClientDataJSON, req.AuthenticatorData, req.Signature, req.UserHandle})
		if err != nil {
			internalError(w, err)
			return
		}
		if !passed {
			s.twoStep.fail(req.Ticket)
		} else {
			s.twoStep.consume(req.Ticket)
		}
	}
	if !passed {
		httpError(w, http.StatusUnauthorized, "that isn't right")
		return
	}
	recoveryLockout.succeed(lockKey)
	s.stepUps.mark(dev)
	w.WriteHeader(http.StatusNoContent)
}
