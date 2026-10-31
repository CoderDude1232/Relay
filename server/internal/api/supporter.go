package api

import (
	"encoding/base64"
	"errors"
	"log/slog"
	"net/http"
	"slices"
	"time"

	"github.com/relayapp/relay-server/internal/store"
	"github.com/relayapp/relay-server/internal/supporter"
)

// Relay Supporter: the app turns an App Store subscription into anonymous
// credentials (POST /v1/supporter/issue, unauthenticated), then redeems one
// per period on its account (POST /v1/supporter/redeem). The relay can't link
// the two, so it never learns which account paid. See internal/supporter.

type supporterConfig struct {
	issuer   *supporter.Issuer
	verifier *supporter.AppStoreVerifier
}

// SetSupporter enables Relay Supporter.
func (s *Server) SetSupporter(issuer *supporter.Issuer, verifier *supporter.AppStoreVerifier) {
	s.supporter = &supporterConfig{issuer: issuer, verifier: verifier}
}

const (
	// maxIssuancesPerTransaction lets a reinstall (lost credentials) issue
	// once more, while a subscription can't make supporters of many accounts.
	maxIssuancesPerTransaction = 2
	maxSupporterIssueBody      = 32 << 10
)

var (
	supporterIssueIPLimiter    = newSlidingWindowLimiter(20, time.Hour)
	supporterRedeemAcctLimiter = newSlidingWindowLimiter(20, time.Hour)
)

func (s *Server) supporterUnavailable(w http.ResponseWriter) bool {
	if s.supporter == nil {
		httpError(w, http.StatusServiceUnavailable, "Relay Supporter isn't available")
		return true
	}
	return false
}

// SetSupporterAttachmentMax lets supporter accounts upload attachments up
// to n bytes (the default is the blob store's limit).
func (s *Server) SetSupporterAttachmentMax(n int64) {
	s.attachSupporterMax = n
	if limit := n + 1<<20; limit > attachmentMaxRequestBodySize {
		attachmentMaxRequestBodySize = limit
	}
}

// IsSupporter reports whether the account has supporter perks now.
func (s *Server) IsSupporter(accountID string) bool {
	if s.supporter == nil {
		return false
	}
	until, err := s.store.SupporterUntil(accountID)
	return err == nil && until > time.Now().UnixMilli()
}

// GET /v1/supporter/keys → {keys: {period: publicKey}} for the current and
// next month (and hour, for sandbox purchases). Unauthenticated: the same for
// everyone, so the app can check its credentials weren't signed with a key
// meant to single it out.
func (s *Server) handleSupporterKeys(w http.ResponseWriter, r *http.Request) {
	if s.supporterUnavailable(w) {
		return
	}
	now := time.Now()
	keys := map[string]string{}
	for _, sandbox := range []bool{false, true} {
		p := supporter.PeriodAt(now, sandbox)
		_, end, _, _ := supporter.ParsePeriod(p)
		for _, period := range []string{p, supporter.PeriodAt(end, sandbox)} {
			keys[period] = base64.StdEncoding.EncodeToString(s.supporter.issuer.PublicKey(period))
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"keys": keys})
}

// POST /v1/supporter/issue {transaction, requests: [{period, blinded}]} →
// {credentials: [{period, evaluated, proof}]}. Unauthenticated by design.
// requests must name only periods the transaction covers.
func (s *Server) handleSupporterIssue(w http.ResponseWriter, r *http.Request) {
	if s.supporterUnavailable(w) {
		return
	}
	if !supporterIssueIPLimiter.allow(clientIP(r)) {
		httpError(w, http.StatusTooManyRequests, "too many requests")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxSupporterIssueBody)
	var req struct {
		Transaction string `json:"transaction"`
		Requests    []struct {
			Period  string `json:"period"`
			Blinded []byte `json:"blinded"`
		} `json:"requests"`
	}
	if err := decodeJSON(r, &req); err != nil || len(req.Requests) == 0 || len(req.Requests) > supporter.MaxPeriods {
		httpError(w, http.StatusBadRequest, "invalid request")
		return
	}
	now := time.Now()
	tx, err := s.supporter.verifier.Verify(req.Transaction, now)
	if err != nil {
		slog.Info("supporter: transaction refused", "err", err)
		httpError(w, http.StatusForbidden, "this purchase can't be used")
		return
	}
	covered := supporter.PeriodsFor(tx, now)
	seen := map[string]bool{}
	for _, q := range req.Requests {
		if !slices.Contains(covered, q.Period) || seen[q.Period] {
			httpError(w, http.StatusBadRequest, "period not covered by this purchase")
			return
		}
		seen[q.Period] = true
	}
	ok, err := s.store.ClaimSupporterIssuance(s.supporter.issuer.TransactionTag(tx.TransactionID),
		tx.Expires().UnixMilli(), maxIssuancesPerTransaction)
	if err != nil {
		internalError(w, err)
		return
	}
	if !ok {
		httpError(w, http.StatusConflict, "this purchase has already been used")
		return
	}
	type credential struct {
		Period    string `json:"period"`
		Evaluated []byte `json:"evaluated"`
		Proof     []byte `json:"proof"`
	}
	out := []credential{}
	for _, q := range req.Requests {
		e, proof, err := s.supporter.issuer.Evaluate(q.Period, q.Blinded)
		if err != nil {
			httpError(w, http.StatusBadRequest, "invalid blinded element")
			return
		}
		out = append(out, credential{Period: q.Period, Evaluated: e, Proof: proof})
	}
	writeJSON(w, http.StatusOK, map[string]any{"credentials": out})
}

// POST /v1/supporter/redeem {period, nonce, credential} → {supporterUntil}.
func (s *Server) handleSupporterRedeem(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if s.supporterUnavailable(w) || s.refuseIfDemo(w, dev.AccountID) {
		return
	}
	if !supporterRedeemAcctLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "too many requests")
		return
	}
	var req struct {
		Period     string `json:"period"`
		Nonce      []byte `json:"nonce"`
		Credential []byte `json:"credential"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "invalid request")
		return
	}
	start, end, _, err := supporter.ParsePeriod(req.Period)
	now := time.Now()
	if err != nil || now.Before(start) || !now.Before(end) {
		httpError(w, http.StatusUnprocessableEntity, "this credential isn't for the current period")
		return
	}
	if !s.supporter.issuer.Check(req.Period, req.Nonce, req.Credential) {
		httpError(w, http.StatusForbidden, "invalid credential")
		return
	}
	until, err := s.store.RedeemSupporterCredential(dev.AccountID,
		s.supporter.issuer.NonceTag(req.Period, req.Nonce), end.UnixMilli())
	if errors.Is(err, store.ErrCredentialSpent) {
		httpError(w, http.StatusConflict, "this credential has already been used")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"supporterUntil": until})
}

// GET /v1/accounts/me/supporter → {available, supporterUntil}.
func (s *Server) handleGetSupporter(w http.ResponseWriter, _ *http.Request, dev *store.Device) {
	until, err := s.store.SupporterUntil(dev.AccountID)
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"available": s.supporter != nil, "supporterUntil": until})
}
