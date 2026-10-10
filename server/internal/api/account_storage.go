package api

import (
	"encoding/base64"
	"errors"
	"net/http"

	"github.com/relayapp/relay-server/internal/store"
)

// GET /v1/accounts/me/storage: {blob, version}, or 404.
func (s *Server) handleGetAccountStorage(w http.ResponseWriter, _ *http.Request, dev *store.Device) {
	blob, version, err := s.store.AccountStorage(dev.AccountID)
	if errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusNotFound, "no account storage")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"blob": b64(blob), "version": version})
}

// PUT /v1/accounts/me/storage {blob, baseVersion}: {version}, or 409 on a stale base.
func (s *Server) handlePutAccountStorage(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if !accountStorageLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "too many updates; try again later")
		return
	}
	var req struct {
		Blob        string `json:"blob"`
		BaseVersion int64  `json:"baseVersion"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "invalid body")
		return
	}
	blob, err := base64.StdEncoding.DecodeString(req.Blob)
	if err != nil || len(blob) == 0 || len(blob) > store.MaxAccountStorageBytes || req.BaseVersion < 0 {
		httpError(w, http.StatusBadRequest, "blob must be 1..512 KiB of base64")
		return
	}
	version, err := s.store.PutAccountStorage(dev.AccountID, blob, req.BaseVersion)
	if errors.Is(err, store.ErrStorageVersionConflict) {
		httpError(w, http.StatusConflict, "account storage changed; re-read and retry")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"version": version})
}
