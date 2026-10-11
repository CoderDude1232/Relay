package api

import (
	"crypto/sha256"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/relayapp/relay-server/internal/store"
)

// Recovery key: a client-generated key whose hash the relay stores. It signs
// the account in on a fresh install, replacing its devices, and satisfies the
// registration lock like a passkey.

const (
	recoveryKeyHashPrefix = "relay-recovery-key-v1|"
	maxRecoveryKeyChars   = 128
	minRecoveryKeyNormLen = 20
	maxRecoveryKeyNormLen = 40
	errRecoveryKeySignIn  = "recovery key sign-in failed"
)

// Recovery-key sign-ins per source IP per hour.
var recoveryKeyIPLimiter = newSlidingWindowLimiter(60, time.Hour)

// normalizeRecoveryKey upper-cases ASCII letters and drops every character
// that isn't A–Z or 0–9.
func normalizeRecoveryKey(key string) string {
	var b strings.Builder
	for _, c := range key {
		switch {
		case c >= 'a' && c <= 'z':
			b.WriteRune(c - 'a' + 'A')
		case c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
			b.WriteRune(c)
		}
	}
	return b.String()
}

// recoveryKeyHash is SHA-256("relay-recovery-key-v1|" + normalized key).
func recoveryKeyHash(normalized string) []byte {
	h := sha256.Sum256([]byte(recoveryKeyHashPrefix + normalized))
	return h[:]
}

func (s *Server) handleSignInMethods(w http.ResponseWriter, _ *http.Request, dev *store.Device) {
	m, err := s.store.AccountSignInMethods(dev.AccountID)
	if errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusNotFound, "no such account")
		return
	} else if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"email":           m.Email,
		"passkeys":        m.Passkeys,
		"accountPassword": m.AccountPassword,
		"recoveryKey":     m.RecoveryKey,
	})
}

func (s *Server) handleSetRecoveryKey(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if s.isDemo(dev.AccountID) {
		httpError(w, http.StatusForbidden, errPasskeyDemo)
		return
	}
	var req struct {
		Hash string `json:"hash"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "invalid body")
		return
	}
	hash, err := decodeB64URL(req.Hash)
	if err != nil || len(hash) != sha256.Size {
		httpError(w, http.StatusBadRequest, "hash must be 32 bytes (base64url)")
		return
	}
	switch err := s.store.SetRecoveryKeyHash(dev.AccountID, hash); {
	case errors.Is(err, store.ErrRecoveryKeyInUse):
		httpError(w, http.StatusConflict, "recovery key already in use; generate another")
		return
	case errors.Is(err, store.ErrAccountNotFound):
		httpError(w, http.StatusNotFound, "no such account")
		return
	case err != nil:
		internalError(w, err)
		return
	}
	s.noticeAccountChange(dev, store.NoticeRecoveryKeySet)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleDeleteRecoveryKey(w http.ResponseWriter, _ *http.Request, dev *store.Device) {
	if err := s.store.ClearRecoveryKeyHash(dev.AccountID); err != nil {
		internalError(w, err)
		return
	}
	s.noticeAccountChange(dev, store.NoticeRecoveryKeyRemoved)
	w.WriteHeader(http.StatusNoContent)
}

// handleRecoveryKeySignIn signs in with a recovery key, replacing the
// account's devices with a new one. No account password is needed.
func (s *Server) handleRecoveryKeySignIn(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	// About 118 random bits can't be guessed, so this only bounds load; it isn't
	// tied to the shared lockout that would block others behind a proxy.
	if !recoveryKeyIPLimiter.allow(ip) {
		httpError(w, http.StatusTooManyRequests, "too many attempts; try again later")
		return
	}
	var req struct {
		Key      string `json:"key"`
		Password string `json:"password"`
	}
	if err := decodeJSON(r, &req); err != nil || req.Key == "" || len(req.Key) > maxRecoveryKeyChars ||
		len(req.Password) < 8 || len(req.Password) > maxPasswordBytes {
		httpError(w, http.StatusBadRequest, "key (≤128 chars) and password (8–1024 chars) required")
		return
	}
	fail := func() { httpError(w, http.StatusUnauthorized, errRecoveryKeySignIn) }
	norm := normalizeRecoveryKey(req.Key)
	if len(norm) < minRecoveryKeyNormLen || len(norm) > maxRecoveryKeyNormLen {
		fail()
		return
	}
	accountID, demo, err := s.store.RecoveryKeyAccount(recoveryKeyHash(norm))
	if errors.Is(err, store.ErrNotFound) {
		fail()
		return
	} else if err != nil {
		internalError(w, err)
		return
	}
	if demo {
		httpError(w, http.StatusForbidden, errPasskeyDemo)
		return
	}
	dev, err := s.store.ProvisionReplacementDevice(accountID, req.Password)
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
