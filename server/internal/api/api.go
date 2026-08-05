// Package api exposes the relay over HTTP: a JSON REST control plane
// (accounts, devices, prekeys) and a protobuf-framed WebSocket for
// real-time envelope delivery.
package api

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"

	"github.com/relayapp/relay-server/internal/blob"
	"github.com/relayapp/relay-server/internal/hub"
	"github.com/relayapp/relay-server/internal/store"
)

type Server struct {
	store *store.Store
	hub   *hub.Hub
	blobs *blob.Store
}

func New(st *store.Store, h *hub.Hub, blobs *blob.Store) *Server {
	return &Server{store: st, hub: h, blobs: blobs}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/accounts", s.handleCreateAccount)
	mux.HandleFunc("POST /v1/devices", s.auth(s.handleAddDevice))
	mux.HandleFunc("PUT /v1/devices/apns", s.auth(s.handleSetAPNSToken))
	mux.HandleFunc("PUT /v1/keys", s.auth(s.handleSetKeys))
	mux.HandleFunc("GET /v1/keys/count", s.auth(s.handleKeyCount))
	mux.HandleFunc("GET /v1/keys/{account}", s.auth(s.handleGetKeys))
	mux.HandleFunc("GET /v1/accounts/by-username/{username}", s.auth(s.handleLookupUsername))
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
	mux.HandleFunc("GET /v1/ws", s.auth(s.handleWebSocket))
	return mux
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
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Username == "" || len(req.Password) < 8 {
		httpError(w, http.StatusBadRequest, "username and password (min 8 chars) required")
		return
	}
	accountID, deviceID, err := s.store.CreateAccount(req.Username, req.Password)
	if errors.Is(err, store.ErrUsernameTaken) {
		httpError(w, http.StatusConflict, "username already taken")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"accountId": accountID, "deviceId": deviceID})
}

func (s *Server) handleAddDevice(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || len(req.Password) < 8 {
		httpError(w, http.StatusBadRequest, "password (min 8 chars) required")
		return
	}
	deviceID, err := s.store.AddDevice(dev.AccountID, req.Password)
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"accountId": dev.AccountID, "deviceId": deviceID})
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

func (s *Server) handleLookupUsername(w http.ResponseWriter, r *http.Request, _ *store.Device) {
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

func (s *Server) handleLookupAccount(w http.ResponseWriter, r *http.Request, _ *store.Device) {
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
func (s *Server) handlePresence(w http.ResponseWriter, r *http.Request, _ *store.Device) {
	account := r.PathValue("account")
	online := s.hub.IsOnline(account)
	lastSeen, err := s.store.LastSeen(account)
	if err != nil {
		internalError(w, err)
		return
	}
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
	writeJSON(w, status, map[string]any{
		"id":             g.ID,
		"name":           g.Name,
		"distributionId": g.DistributionID,
		"revision":       g.Revision,
		"members":        g.Members,
	})
}

func (s *Server) groupError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		httpError(w, http.StatusNotFound, "no such group")
	case errors.Is(err, store.ErrNotMember):
		httpError(w, http.StatusForbidden, "not a group member")
	default:
		internalError(w, err)
	}
}

func (s *Server) handleCreateGroup(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Name    string   `json:"name"`
		Members []string `json:"members"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "malformed body")
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
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Name == "" {
		httpError(w, http.StatusBadRequest, "name required")
		return
	}
	g, err := s.store.RenameGroup(r.PathValue("id"), dev.AccountID, req.Name)
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
func (s *Server) handleGetKeys(w http.ResponseWriter, r *http.Request, _ *store.Device) {
	account := r.PathValue("account")
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
		RegistrationID uint32             `json:"registrationId"`
		IdentityKey    b64                `json:"identityKey"`
		SignedPreKey   jsonSignedPreKey   `json:"signedPreKey"`
		KyberPreKey    jsonSignedPreKey   `json:"kyberPreKey"`
		OneTimePreKey  *jsonOneTimePreKey `json:"oneTimePreKey"`
	}
	out := struct {
		Devices []jsonBundle `json:"devices"`
	}{Devices: make([]jsonBundle, 0, len(bundles))}
	for _, b := range bundles {
		jb := jsonBundle{
			DeviceID:       b.DeviceID,
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
	slog.Error("internal error", "err", err)
	httpError(w, http.StatusInternalServerError, "internal error")
}
