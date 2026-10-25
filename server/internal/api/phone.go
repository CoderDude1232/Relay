package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/relayapp/relay-server/internal/limitkey"
	"github.com/relayapp/relay-server/internal/store"
)

// Optional phone numbers, for discovery only. A signed-in device asks for a
// code (POST .../phone/start), the relay has Twilio Verify text it, and the
// device sends it back (POST .../phone/verify). The relay keeps only the
// number's OPRF token. Every send is behind Relay-Sig and several limits,
// because each SMS costs money and SMS pumping is a common attack.

// smsVerifier sends and checks one-time codes (Twilio Verify in production).
type smsVerifier interface {
	Start(ctx context.Context, phone string) error
	Check(ctx context.Context, phone, code string) (bool, error)
}

type phoneVerification struct {
	verifier smsVerifier
	// allowedPrefixes are the calling codes numbers may have (e.g. "+61").
	allowedPrefixes []string
	dailyCap        int

	mu        sync.Mutex
	day       int64
	sentToday int
}

// SetPhoneVerification enables optional phone numbers. allowedPrefixes are
// E.164 calling-code prefixes ("+61"); dailyCap bounds texts sent per day
// across everyone.
func (s *Server) SetPhoneVerification(v smsVerifier, allowedPrefixes []string, dailyCap int) {
	s.phone = &phoneVerification{verifier: v, allowedPrefixes: allowedPrefixes, dailyCap: dailyCap}
}

// takeDailySlot counts one text against the global daily cap.
func (p *phoneVerification) takeDailySlot(now time.Time) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if d := now.Unix() / 86400; d != p.day {
		p.day, p.sentToday = d, 0
	}
	if p.sentToday >= p.dailyCap {
		return false
	}
	p.sentToday++
	return true
}

func (p *phoneVerification) refundDailySlot() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.sentToday > 0 {
		p.sentToday--
	}
}

var e164 = regexp.MustCompile(`^\+[1-9][0-9]{6,14}$`)

// allowedNumber reports whether phone is E.164 and in an allowed country.
func (p *phoneVerification) allowedNumber(phone string) bool {
	if !e164.MatchString(phone) {
		return false
	}
	for _, prefix := range p.allowedPrefixes {
		if strings.HasPrefix(phone, prefix) {
			return true
		}
	}
	return false
}

// Code sends: per account 3 a day, per number 3 a day, per source address 5
// a day; checks: per account 10 an hour (Twilio also stops a code after 5
// wrong tries).
var (
	phoneStartAccountLimiter = newSlidingWindowLimiter(3, 24*time.Hour)
	phoneStartNumberLimiter  = newSlidingWindowLimiter(3, 24*time.Hour)
	phoneStartIPLimiter      = newSlidingWindowLimiter(5, 24*time.Hour)
	phoneCheckLimiter        = newSlidingWindowLimiter(10, time.Hour)
)

const errPhoneUnavailable = "phone numbers aren't available yet"

func (s *Server) phoneUnavailable(w http.ResponseWriter, accountID string) bool {
	if s.phone == nil || s.oprf == nil {
		httpError(w, http.StatusServiceUnavailable, errPhoneUnavailable)
		return true
	}
	return s.refuseIfDemo(w, accountID)
}

// GET /v1/accounts/me/phone → {hasPhone, discoverable, available}.
func (s *Server) handleGetPhone(w http.ResponseWriter, _ *http.Request, dev *store.Device) {
	has, discoverable, err := s.store.AccountPhone(dev.AccountID)
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"hasPhone": has, "discoverable": discoverable, "available": s.phone != nil && s.oprf != nil,
	})
}

// POST /v1/accounts/me/phone/start {phone} → 204 once a code is on its way.
func (s *Server) handleStartPhone(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if s.phoneUnavailable(w, dev.AccountID) {
		return
	}
	var req struct {
		Phone string `json:"phone"`
	}
	if err := decodeJSON(r, &req); err != nil || !e164.MatchString(req.Phone) {
		httpError(w, http.StatusBadRequest, "phone must be in international format, like +61412345678")
		return
	}
	if !s.phone.allowedNumber(req.Phone) {
		httpError(w, http.StatusUnprocessableEntity, "phone numbers from this country aren't supported yet")
		return
	}
	numberKey := limitkey.Hash("phone-start", req.Phone)
	if !phoneStartAccountLimiter.allow(dev.AccountID) || !phoneStartNumberLimiter.allow(numberKey) ||
		!phoneStartIPLimiter.allow(clientIP(r)) {
		httpError(w, http.StatusTooManyRequests, "too many codes requested; try again tomorrow")
		return
	}
	if !s.phone.takeDailySlot(time.Now()) {
		httpError(w, http.StatusTooManyRequests, "codes are paused for today; try again tomorrow")
		return
	}
	if err := s.phone.verifier.Start(r.Context(), req.Phone); err != nil {
		s.phone.refundDailySlot()
		var invalid *invalidPhoneError
		if errors.As(err, &invalid) {
			httpError(w, http.StatusBadRequest, "that phone number can't receive codes")
			return
		}
		httpError(w, http.StatusBadGateway, "couldn't send the code; try again later")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// POST /v1/accounts/me/phone/verify {phone, code, discoverable} → 204, and
// the number is the account's.
func (s *Server) handleVerifyPhone(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	if s.phoneUnavailable(w, dev.AccountID) {
		return
	}
	var req struct {
		Phone        string `json:"phone"`
		Code         string `json:"code"`
		Discoverable bool   `json:"discoverable"`
	}
	if err := decodeJSON(r, &req); err != nil || !e164.MatchString(req.Phone) ||
		len(req.Code) < 4 || len(req.Code) > 10 {
		httpError(w, http.StatusBadRequest, "phone and code required")
		return
	}
	if !phoneCheckLimiter.allow(dev.AccountID) {
		httpError(w, http.StatusTooManyRequests, "too many tries; try again later")
		return
	}
	ok, err := s.phone.verifier.Check(r.Context(), req.Phone, req.Code)
	if err != nil {
		httpError(w, http.StatusBadGateway, "couldn't check the code; try again")
		return
	}
	if !ok {
		httpError(w, http.StatusUnauthorized, "that code isn't right or has expired")
		return
	}
	previous, err := s.store.SetAccountPhone(dev.AccountID, s.oprf.Token(req.Phone), req.Discoverable)
	if err != nil {
		internalError(w, err)
		return
	}
	if previous != "" {
		s.reindexAccount(previous)
	}
	s.reindexAccount(dev.AccountID)
	s.noticeAccountChange(dev, store.NoticePhoneAdded)
	w.WriteHeader(http.StatusNoContent)
}

// PUT /v1/accounts/me/phone/discoverability {discoverable} → 204.
func (s *Server) handleSetPhoneDiscoverability(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Discoverable *bool `json:"discoverable"`
	}
	if err := decodeJSON(r, &req); err != nil || req.Discoverable == nil {
		httpError(w, http.StatusBadRequest, "discoverable (bool) required")
		return
	}
	if err := s.store.SetPhoneDiscoverable(dev.AccountID, *req.Discoverable); errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusNotFound, "no phone number on this account")
		return
	} else if err != nil {
		internalError(w, err)
		return
	}
	s.reindexAccount(dev.AccountID)
	w.WriteHeader(http.StatusNoContent)
}

// DELETE /v1/accounts/me/phone → 204.
func (s *Server) handleDeletePhone(w http.ResponseWriter, _ *http.Request, dev *store.Device) {
	if err := s.store.ClearAccountPhone(dev.AccountID); err != nil {
		internalError(w, err)
		return
	}
	s.reindexAccount(dev.AccountID)
	s.noticeAccountChange(dev, store.NoticePhoneRemoved)
	w.WriteHeader(http.StatusNoContent)
}

// MARK: Twilio Verify

// TwilioVerify sends codes through a Twilio Verify service. The service
// should have Fraud Guard on and geo permissions limited to the allowed
// countries; the relay's own limits apply first.
type TwilioVerify struct {
	AccountSID string
	AuthToken  string
	ServiceSID string
	client     *http.Client
}

func NewTwilioVerify(accountSID, authToken, serviceSID string) *TwilioVerify {
	return &TwilioVerify{AccountSID: accountSID, AuthToken: authToken, ServiceSID: serviceSID,
		client: &http.Client{Timeout: 15 * time.Second}}
}

type invalidPhoneError struct{ message string }

func (e *invalidPhoneError) Error() string { return e.message }

func (t *TwilioVerify) post(ctx context.Context, path string, form url.Values) (int, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		"https://verify.twilio.com/v2/Services/"+url.PathEscape(t.ServiceSID)+path, strings.NewReader(form.Encode()))
	if err != nil {
		return 0, nil, err
	}
	req.SetBasicAuth(t.AccountSID, t.AuthToken)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := t.client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	return resp.StatusCode, body, nil
}

func (t *TwilioVerify) Start(ctx context.Context, phone string) error {
	status, body, err := t.post(ctx, "/Verifications", url.Values{"To": {phone}, "Channel": {"sms"}})
	if err != nil {
		return err
	}
	if status == http.StatusBadRequest {
		// Invalid or unreachable number, or a country the service blocks.
		return &invalidPhoneError{message: "twilio rejected the number"}
	}
	if status/100 != 2 {
		return fmt.Errorf("twilio verify start: HTTP %d: %.200s", status, body)
	}
	return nil
}

func (t *TwilioVerify) Check(ctx context.Context, phone, code string) (bool, error) {
	status, body, err := t.post(ctx, "/VerificationCheck", url.Values{"To": {phone}, "Code": {code}})
	if err != nil {
		return false, err
	}
	if status == http.StatusNotFound {
		return false, nil // expired, already used or never started
	}
	if status/100 != 2 {
		return false, fmt.Errorf("twilio verify check: HTTP %d: %.200s", status, body)
	}
	var out struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return false, err
	}
	return out.Status == "approved", nil
}
