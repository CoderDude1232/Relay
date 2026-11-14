package api

import (
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/relayapp/relay-server/internal/pinguard"
	"github.com/relayapp/relay-server/internal/store"
)

// PIN guard: the relay's half of the Relay PIN lock (internal/pinguard,
// docs/DISTRESS_PIN_PLAN.md). Every route acts on the signed-in device's own
// key only.
//
// Enrolment: POST /v1/devices/me/pin-guard with a blinded PIN makes a fresh
// key and answers it, then PUT …/verifier stores the tag the device will
// prove a correct PIN with. Unlocking: POST …/evaluate counts an attempt and
// answers; POST …/confirm with the right tag resets the count. After
// pinguard.MaxAttempts evaluations without a confirm the key is deleted.
// DELETE removes it (lock turned off, or the distress PIN).

// Requests per device per hour, on top of the attempt limit, so a stuck or
// hostile client can't hammer the database.
var pinGuardLimiter = newSlidingWindowLimiter(60, time.Hour)

func pinGuardKey(dev *store.Device) string { return fmt.Sprintf("%s.%d", dev.AccountID, dev.DeviceID) }

// decodeFixed reads a base64 field that must decode to exactly n bytes.
func decodeFixed(s string, n int) ([]byte, bool) {
	b, err := base64.StdEncoding.DecodeString(s)
	return b, err == nil && len(b) == n
}

func (s *Server) handleEnrolPinGuard(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Blinded string `json:"blinded"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "invalid body")
		return
	}
	blinded, ok := decodeFixed(req.Blinded, 32)
	if !ok {
		httpError(w, http.StatusBadRequest, "invalid blinded element")
		return
	}
	if !pinGuardLimiter.allow(pinGuardKey(dev)) {
		httpError(w, http.StatusTooManyRequests, "too many requests; try again later")
		return
	}
	// A retry before the verifier is set reuses the pending key, so the
	// device's two halves can't end up made with different keys.
	scalar, err := s.store.PinGuardEnrolmentScalar(dev.AccountID, dev.DeviceID)
	if err != nil {
		if !errors.Is(err, store.ErrNotFound) && !errors.Is(err, store.ErrPinGuardVerifierSet) {
			internalError(w, err)
			return
		}
		if scalar, err = pinguard.NewScalar(); err != nil {
			internalError(w, err)
			return
		}
		if err := s.store.EnrolPinGuard(dev.AccountID, dev.DeviceID, scalar); err != nil {
			internalError(w, err)
			return
		}
	}
	evaluated, err := pinguard.Evaluate(scalar, blinded)
	if errors.Is(err, pinguard.ErrBadElement) {
		httpError(w, http.StatusBadRequest, "invalid blinded element")
		return
	} else if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"evaluated":   base64.StdEncoding.EncodeToString(evaluated),
		"maxAttempts": pinguard.MaxAttempts,
	})
}

func (s *Server) handleSetPinGuardVerifier(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Verifier string `json:"verifier"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "invalid body")
		return
	}
	verifier, ok := decodeFixed(req.Verifier, pinguard.VerifierSize)
	if !ok {
		httpError(w, http.StatusBadRequest, "invalid verifier")
		return
	}
	switch err := s.store.SetPinGuardVerifier(dev.AccountID, dev.DeviceID, verifier); {
	case errors.Is(err, store.ErrNotFound):
		httpError(w, http.StatusNotFound, "no pin guard enrolment")
	case errors.Is(err, store.ErrPinGuardVerifierSet):
		httpError(w, http.StatusConflict, "pin guard already enrolled")
	case err != nil:
		internalError(w, err)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

func (s *Server) handleEvaluatePinGuard(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Blinded string `json:"blinded"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "invalid body")
		return
	}
	blinded, ok := decodeFixed(req.Blinded, 32)
	if !ok {
		httpError(w, http.StatusBadRequest, "invalid blinded element")
		return
	}
	if !pinGuardLimiter.allow(pinGuardKey(dev)) {
		httpError(w, http.StatusTooManyRequests, "too many requests; try again later")
		return
	}
	scalar, left, err := s.store.TakePinGuardAttempt(dev.AccountID, dev.DeviceID, pinguard.MaxAttempts)
	switch {
	case errors.Is(err, store.ErrNotFound):
		httpError(w, http.StatusNotFound, "no pin guard")
		return
	case errors.Is(err, store.ErrPinGuardExhausted):
		httpError(w, http.StatusGone, "too many wrong PINs; the key has been deleted")
		return
	case err != nil:
		internalError(w, err)
		return
	}
	evaluated, err := pinguard.Evaluate(scalar, blinded)
	if errors.Is(err, pinguard.ErrBadElement) {
		// The attempt still counts: it was taken before the element was checked
		// against the key, and a malformed guess is still a guess.
		httpError(w, http.StatusBadRequest, "invalid blinded element")
		return
	} else if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"evaluated":    base64.StdEncoding.EncodeToString(evaluated),
		"attemptsLeft": left,
	})
}

func (s *Server) handleConfirmPinGuard(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Verifier string `json:"verifier"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "invalid body")
		return
	}
	verifier, ok := decodeFixed(req.Verifier, pinguard.VerifierSize)
	if !ok {
		httpError(w, http.StatusBadRequest, "invalid verifier")
		return
	}
	matched, err := s.store.ConfirmPinGuard(dev.AccountID, dev.DeviceID, verifier)
	switch {
	case errors.Is(err, store.ErrNotFound):
		httpError(w, http.StatusNotFound, "no pin guard")
	case err != nil:
		internalError(w, err)
	case !matched:
		httpError(w, http.StatusForbidden, "verifier does not match")
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

func (s *Server) handleDeletePinGuard(w http.ResponseWriter, _ *http.Request, dev *store.Device) {
	if err := s.store.DeletePinGuard(dev.AccountID, dev.DeviceID); err != nil {
		internalError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
