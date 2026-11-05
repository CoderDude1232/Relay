package api

import (
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/relayapp/relay-server/internal/kt"
	"github.com/relayapp/relay-server/internal/store"
)

// Key transparency (docs/KEY_TRANSPARENCY.md). Binary values are base64.

// SetKeyTransparencyEndorsements are the endorsements served at /v1/kt/keys.
func (s *Server) SetKeyTransparencyEndorsements(e []kt.Endorsement) { s.ktEndorsements = e }

// GET /v1/kt/keys → {endorsements: [{key, by, sig}]}: signing keys that
// replaced the one built into the app, each vouched for by the one before.
func (s *Server) handleKTKeys(w http.ResponseWriter, r *http.Request) {
	out := make([]map[string]any, len(s.ktEndorsements))
	for i, e := range s.ktEndorsements {
		out[i] = map[string]any{"key": ktB64(e.Key), "by": ktB64(e.By), "sig": ktB64(e.Sig)}
	}
	writeJSON(w, http.StatusOK, map[string]any{"endorsements": out})
}

// SetKeyTransparency enables the kt endpoints with a directory restored from
// storage, and starts the loop that records key changes and publishes epochs.
func (s *Server) SetKeyTransparency(d *kt.Directory, every time.Duration) {
	s.kt = d
	go func() {
		for {
			s.ktPublish()
			time.Sleep(every)
		}
	}()
}

func (s *Server) ktPublish() {
	current, err := s.store.KTCurrentKeys()
	if err != nil {
		slog.Error("kt: read keys", "err", err)
		return
	}
	if _, err := s.kt.Sync(current); err != nil {
		slog.Error("kt: sync", "err", err)
		return
	}
	head, isNew, err := s.kt.Publish(time.Now(), s.store.KTSaveEpoch)
	if err != nil {
		// The directory is now ahead of what's stored; restart restores it.
		slog.Error("kt: couldn't store epoch; exiting", "err", err)
		os.Exit(1)
	}
	if isNew {
		slog.Info("kt: published", "epoch", head.Epoch)
	}
}

func ktB64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

func ktHeadJSON(h kt.Head) map[string]any {
	return map[string]any{
		"epoch": h.Epoch, "smtRoot": ktB64(h.SMTRoot[:]), "logSize": h.LogSize,
		"logRoot": ktB64(h.LogRoot[:]), "time": h.Time, "sig": ktB64(h.Sig),
	}
}

func ktProofJSON(p kt.Proof) map[string]any {
	siblings := make([]string, len(p.Siblings))
	for i, sib := range p.Siblings {
		siblings[i] = ktB64(sib[:])
	}
	return map[string]any{"bitmap": ktB64(p.Bitmap[:]), "siblings": siblings}
}

func ktKeysJSON(keys [][]byte) []string {
	out := make([]string, len(keys))
	for i, k := range keys {
		out[i] = ktB64(k)
	}
	return out
}

// GET /v1/kt/head → the latest signed head.
func (s *Server) handleKTHead(w http.ResponseWriter, r *http.Request) {
	if s.kt == nil {
		httpError(w, http.StatusServiceUnavailable, "key transparency not configured")
		return
	}
	head, ok := s.kt.Head()
	if !ok {
		httpError(w, http.StatusServiceUnavailable, "nothing published yet")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, ktHeadJSON(head))
}

// GET /v1/kt/lookup/{account} → proof of the account's current keys.
// ktLookupLimiter: a device checks its contacts, not the whole directory.
var ktLookupLimiter = newSlidingWindowLimiter(600, time.Hour)

// ktSealedLookupIPLimiter bounds the anonymous lookup per address.
var ktSealedLookupIPLimiter = newSlidingWindowLimiter(600, time.Hour)

func (s *Server) handleKTLookup(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if !ktLookupLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "too many lookups; try again later")
		return
	}
	s.writeKTLookup(w, r)
}

// GET /v1/kt/lookup/{account}/sealed with Relay-Access-Key: the same proof,
// authorized by the account's access key instead of our signature (like the
// sealed bundle fetch), so the relay can't record who checks whose keys.
// Unknown account and wrong key get the same 403.
func (s *Server) handleKTLookupSealed(w http.ResponseWriter, r *http.Request) {
	if !ktSealedLookupIPLimiter.allow(clientIP(r)) {
		httpError(w, http.StatusTooManyRequests, "too many lookups; try again later")
		return
	}
	token, err := base64.StdEncoding.DecodeString(r.Header.Get("Relay-Access-Key"))
	if err != nil || len(token) != 32 {
		httpError(w, http.StatusForbidden, "not allowed")
		return
	}
	stored, err := s.store.AccessKey(r.PathValue("account"))
	if err != nil || len(stored) != 32 || subtle.ConstantTimeCompare(stored, token) != 1 {
		httpError(w, http.StatusForbidden, "not allowed")
		return
	}
	s.writeKTLookup(w, r)
}

func (s *Server) writeKTLookup(w http.ResponseWriter, r *http.Request) {
	if s.kt == nil {
		httpError(w, http.StatusServiceUnavailable, "key transparency not configured")
		return
	}
	account := r.PathValue("account")
	if account == "" || len(account) > 64 {
		httpError(w, http.StatusBadRequest, "account required")
		return
	}
	var since uint32
	if v, err := strconv.ParseUint(r.URL.Query().Get("since"), 10, 32); err == nil {
		since = uint32(v)
	}
	res, err := s.kt.LookupSince(account, since)
	if errors.Is(err, kt.ErrNotPublished) {
		httpError(w, http.StatusServiceUnavailable, "nothing published yet")
		return
	} else if err != nil {
		internalError(w, err)
		return
	}
	links := make([]map[string]any, len(res.Links))
	for i, l := range res.Links {
		links[i] = map[string]any{"version": l.Version, "commitment": ktB64(l.Commitment[:])}
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{
		"links":    links,
		"vrfProof": ktB64(res.VRFProof), "version": res.Version,
		"commitment": ktB64(res.Commitment[:]), "prevChain": ktB64(res.PrevChain[:]),
		"nonce": ktB64(res.Nonce[:]), "keys": ktKeysJSON(res.Keys),
		"proof": ktProofJSON(res.Proof), "head": ktHeadJSON(res.Head),
	})
}

// GET /v1/kt/consistency?from=M&to=N → proof the log of size N extends size M.
func (s *Server) handleKTConsistency(w http.ResponseWriter, r *http.Request) {
	if s.kt == nil {
		httpError(w, http.StatusServiceUnavailable, "key transparency not configured")
		return
	}
	from, err1 := strconv.ParseUint(r.URL.Query().Get("from"), 10, 64)
	to, err2 := strconv.ParseUint(r.URL.Query().Get("to"), 10, 64)
	if err1 != nil || err2 != nil {
		httpError(w, http.StatusBadRequest, "from and to required")
		return
	}
	proof, err := s.kt.Consistency(from, to)
	if err != nil {
		httpError(w, http.StatusBadRequest, "no such log sizes")
		return
	}
	out := make([]string, len(proof))
	for i, p := range proof {
		out[i] = ktB64(p[:])
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"proof": out})
}

// GET /v1/kt/monitor → the caller's own account history, with openings, and
// the lookup it should end at.
func (s *Server) handleKTMonitor(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if s.kt == nil {
		httpError(w, http.StatusServiceUnavailable, "key transparency not configured")
		return
	}
	res, err := s.kt.Lookup(dev.AccountID)
	if errors.Is(err, kt.ErrNotPublished) {
		httpError(w, http.StatusServiceUnavailable, "nothing published yet")
		return
	} else if err != nil {
		internalError(w, err)
		return
	}
	var versions []map[string]any
	for _, v := range s.kt.History(dev.AccountID) {
		versions = append(versions, map[string]any{
			"version": v.Version, "commitment": ktB64(v.Commitment[:]), "nonce": ktB64(v.Nonce[:]),
			"keys": ktKeysJSON(v.Keys), "epoch": v.Epoch,
		})
	}
	if versions == nil {
		versions = []map[string]any{}
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{
		"versions": versions,
		"latest": map[string]any{
			"vrfProof": ktB64(res.VRFProof), "version": res.Version,
			"commitment": ktB64(res.Commitment[:]), "prevChain": ktB64(res.PrevChain[:]),
			"proof": ktProofJSON(res.Proof), "head": ktHeadJSON(res.Head),
		},
	})
}
