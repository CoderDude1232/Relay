package api

import (
	"encoding/base64"
	"errors"
	"net/http"
	"sync"

	"github.com/relayapp/relay-server/internal/limitkey"
	"github.com/relayapp/relay-server/internal/sendtoken"
	"github.com/relayapp/relay-server/internal/store"
)

// Anonymous send tokens (internal/sendtoken): the anonymous capability routes
// (sealed sends, sealed key and key-transparency fetches, call rings) are
// rate-limited by a token the sender got while signed in, instead of by its IP
// address, so nothing about the sender's network reaches those handlers.

const (
	sendTokenHeader = "Relay-Token"
	// Per account per day, and per request. A busy group user sends a few
	// thousand sealed messages and receipts a day.
	maxSendTokensPerDay   = 10000
	maxSendTokensPerBatch = 100
)

// SetSendTokens enables POST /v1/send-tokens and token-limited anonymous
// requests. With require set, an anonymous request without a token gets 426.
func (s *Server) SetSendTokens(is *sendtoken.Issuer, require bool) {
	s.sendTokens, s.requireSendTokens = is, require
}

type sendTokenCounts struct {
	mu  sync.Mutex
	day int64
	n   map[string]int // limitkey hash of the account → tokens issued today
}

var issuedSendTokens = &sendTokenCounts{n: map[string]int{}}

// take reserves n of the account's tokens for day, if it has them left.
func (c *sendTokenCounts) take(accountID string, day int64, n int) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.day != day {
		c.day, c.n = day, map[string]int{}
	}
	k := limitkey.Hash("send-tokens", accountID)
	if c.n[k]+n > maxSendTokensPerDay {
		return false
	}
	c.n[k] += n
	return true
}

// POST /v1/send-tokens {day, blinded: [base64 B]} → 200 {day, tokens:
// [{evaluated, proof}]}. When day isn't the relay's today the answer is that
// day and no tokens (the app blinds again for it); 429 past the daily
// allowance.
func (s *Server) handleSendTokens(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if s.sendTokens == nil {
		httpError(w, http.StatusNotFound, "send tokens not configured")
		return
	}
	var req struct {
		Day     int64    `json:"day"`
		Blinded []string `json:"blinded"`
	}
	if err := decodeJSON(r, &req); err != nil || len(req.Blinded) == 0 || len(req.Blinded) > maxSendTokensPerBatch {
		httpError(w, http.StatusBadRequest, "day and 1–100 blinded elements required")
		return
	}
	today := s.sendTokens.Today()
	if req.Day != today {
		writeJSON(w, http.StatusOK, map[string]any{"day": today, "tokens": []any{}})
		return
	}
	type token struct {
		Evaluated string `json:"evaluated"`
		Proof     string `json:"proof"`
	}
	out := make([]token, 0, len(req.Blinded))
	blinded := make([][]byte, len(req.Blinded))
	for i, b := range req.Blinded {
		raw, err := base64.StdEncoding.DecodeString(b)
		if err != nil {
			httpError(w, http.StatusBadRequest, "invalid blinded element")
			return
		}
		blinded[i] = raw
	}
	if !issuedSendTokens.take(dev.AccountID, today, len(blinded)) {
		httpError(w, http.StatusTooManyRequests, "send token allowance used up for today")
		return
	}
	for _, b := range blinded {
		e, proof, err := s.sendTokens.Evaluate(b)
		if err != nil {
			httpError(w, http.StatusBadRequest, "invalid blinded element")
			return
		}
		out = append(out, token{base64.StdEncoding.EncodeToString(e), base64.StdEncoding.EncodeToString(proof)})
	}
	writeJSON(w, http.StatusOK, map[string]any{"day": today, "tokens": out})
}

// anonymousAllowed admits an anonymous capability request. With a Relay-Token
// it spends the token and never looks at the source address (viaToken). An
// old app without one falls back to ipLimiter, unless tokens are required.
// On false it has answered.
func (s *Server) anonymousAllowed(w http.ResponseWriter, r *http.Request, ipLimiter *slidingWindowLimiter, limited string) (ok, viaToken bool) {
	if v := r.Header.Get(sendTokenHeader); v != "" && s.sendTokens != nil {
		if err := s.sendTokens.Spend(v); err != nil {
			msg := "send token refused"
			if errors.Is(err, sendtoken.ErrSpent) {
				msg = "send token already used"
			}
			httpError(w, http.StatusUnauthorized, msg)
			return false, false
		}
		return true, true
	}
	if s.sendTokens != nil && s.requireSendTokens {
		httpError(w, http.StatusUpgradeRequired, errUpdateApp)
		return false, false
	}
	if !ipLimiter.allow(clientIP(r)) {
		httpError(w, http.StatusTooManyRequests, limited)
		return false, false
	}
	return true, false
}
