package api

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/relayapp/relay-server/internal/sendtoken"
	"github.com/relayapp/relay-server/internal/store"
)

// Encrypted profiles (store/profiles.go). A client derives three values from
// its profile key: the id (the path), the write secret (header
// Relay-Profile-Write) and the encryption key, which never leaves its
// contacts. Neither route is authenticated, so the relay can't tell whose
// profile is written or who reads it. Writes spend a send token, like sealed
// sends; reads are limited per IP in memory only, like attachment downloads.

const profileWriteHeader = "Relay-Profile-Write"

var (
	profileReadIPLimiter  = newSlidingWindowLimiter(600, time.Minute)
	profileWriteIPLimiter = newSlidingWindowLimiter(30, time.Hour) // only without send tokens (tests, dev)
)

func profileID(r *http.Request) ([]byte, bool) {
	id, err := base64.RawURLEncoding.DecodeString(r.PathValue("id"))
	return id, err == nil && len(id) == 32
}

// profileWriteHash reads the write secret header and returns its hash, the
// only form the relay keeps.
func profileWriteHash(r *http.Request) ([]byte, bool) {
	secret, err := base64.RawURLEncoding.DecodeString(r.Header.Get(profileWriteHeader))
	if err != nil || len(secret) != 32 {
		return nil, false
	}
	h := sha256.Sum256(append([]byte("relay-profile-write|"), secret...))
	return h[:], true
}

func profileETag(blob []byte) string {
	h := sha256.Sum256(blob)
	return `"` + hex.EncodeToString(h[:16]) + `"`
}

// profileWriteAllowed spends a send token. New clients always have one, so
// one is required whenever the relay issues them.
func (s *Server) profileWriteAllowed(w http.ResponseWriter, r *http.Request) bool {
	if s.sendTokens == nil {
		if !profileWriteIPLimiter.allow(clientIP(r)) {
			httpError(w, http.StatusTooManyRequests, "too many profile updates; try again later")
			return false
		}
		return true
	}
	if err := s.sendTokens.Spend(r.Header.Get(sendTokenHeader)); err != nil {
		msg := "send token refused"
		if errors.Is(err, sendtoken.ErrSpent) {
			msg = "send token already used"
		}
		httpError(w, http.StatusUnauthorized, msg)
		return false
	}
	return true
}

// PUT /v1/profiles/{id} (body: exactly store.ProfileBlobSize bytes; headers
// Relay-Profile-Write, Relay-Token) → 204 {ETag}. 403 the id is held under
// another write secret; 413 wrong size; 507 storage full.
func (s *Server) handlePutProfile(w http.ResponseWriter, r *http.Request) {
	id, ok := profileID(r)
	if !ok {
		httpError(w, http.StatusBadRequest, "bad profile id")
		return
	}
	writeHash, ok := profileWriteHash(r)
	if !ok {
		httpError(w, http.StatusBadRequest, "profile write secret required")
		return
	}
	if !s.profileWriteAllowed(w, r) {
		return
	}
	blob, err := io.ReadAll(http.MaxBytesReader(w, r.Body, store.ProfileBlobSize+1))
	if err != nil || len(blob) != store.ProfileBlobSize {
		httpError(w, http.StatusRequestEntityTooLarge, "profile must be exactly 65536 bytes")
		return
	}
	switch err := s.store.PutProfile(id, writeHash, blob, time.Now().Unix()/86400); {
	case errors.Is(err, store.ErrProfileWriteKey):
		httpError(w, http.StatusForbidden, "not this profile's write secret")
	case errors.Is(err, store.ErrProfilesFull):
		httpError(w, http.StatusInsufficientStorage, "profile storage is full")
	case err != nil:
		internalError(w, err)
	default:
		w.Header().Set("ETag", profileETag(blob))
		w.WriteHeader(http.StatusNoContent)
	}
}

// GET /v1/profiles/{id} [If-None-Match] → 200 blob {ETag} | 304 | 404.
func (s *Server) handleGetProfile(w http.ResponseWriter, r *http.Request) {
	id, ok := profileID(r)
	if !ok {
		httpError(w, http.StatusBadRequest, "bad profile id")
		return
	}
	if !profileReadIPLimiter.allow(clientIP(r)) {
		httpError(w, http.StatusTooManyRequests, "too many profile fetches; try again later")
		return
	}
	blob, err := s.store.Profile(id)
	if errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusNotFound, "no such profile")
		return
	} else if err != nil {
		internalError(w, err)
		return
	}
	etag := profileETag(blob)
	w.Header().Set("ETag", etag)
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	_, _ = w.Write(blob)
}

// DELETE /v1/profiles/{id} (header Relay-Profile-Write) → 204, also when
// there's nothing there. 403 another write secret.
func (s *Server) handleDeleteProfile(w http.ResponseWriter, r *http.Request) {
	id, ok := profileID(r)
	if !ok {
		httpError(w, http.StatusBadRequest, "bad profile id")
		return
	}
	writeHash, ok := profileWriteHash(r)
	if !ok {
		httpError(w, http.StatusBadRequest, "profile write secret required")
		return
	}
	if err := s.store.DeleteProfile(id, writeHash); errors.Is(err, store.ErrProfileWriteKey) {
		httpError(w, http.StatusForbidden, "not this profile's write secret")
		return
	} else if err != nil {
		internalError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
