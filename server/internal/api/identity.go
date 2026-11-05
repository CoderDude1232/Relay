package api

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/relayapp/relay-server/internal/idtoken"
	"github.com/relayapp/relay-server/internal/mail"
	"github.com/relayapp/relay-server/internal/oprf"
	"github.com/relayapp/relay-server/internal/privlog"
	"github.com/relayapp/relay-server/internal/store"
)

// Sign-in identities relayd verifies itself, without a sign-in service: email
// codes it generates and sends (internal/mail), and Sign in with Apple and
// Google ID tokens it checks against the providers' keys (internal/idtoken).
// A verified identity becomes a short-lived ticket ("rit_…") that the account
// endpoints accept wherever they took a Supabase access token, so the account
// logic (registration lock, two-step, email adoption) is unchanged. Older apps
// still send Supabase tokens, which verifySignIn checks the old way.

const (
	identityTicketPrefix = "rit_"
	identityTicketTTL    = 15 * time.Minute
	emailCodeTTL         = 10 * time.Minute
	emailCodeAttempts    = 5
	maxEmailBytes        = 254
)

var (
	emailSendAddressLimiter = newSlidingWindowLimiter(5, time.Hour)
	emailSendIPLimiter      = newSlidingWindowLimiter(20, time.Hour)
	emailVerifyIPLimiter    = newSlidingWindowLimiter(60, time.Hour)
	identityTokenIPLimiter  = newSlidingWindowLimiter(60, time.Hour)
)

// signInIdentity is what the account endpoints trust about whoever is signing
// in.
type signInIdentity struct {
	Link           string // "apple:…" / "google:…"; "" for an email code
	SupabaseID     string // the Supabase user, for older apps
	Email          string
	EmailConfirmed bool
	// RecoveredAt is when a password-reset code was confirmed; zero otherwise.
	RecoveredAt time.Time
	// ForAccount binds an email-change ticket to the account that asked.
	ForAccount string
}

func (u signInIdentity) store() store.Identity {
	return store.Identity{Link: u.Link, SupabaseID: u.SupabaseID}
}

// errSignInUnavailable: the token isn't one this relay can check.
var errSignInUnavailable = errors.New("sign-in not configured")

// verifySignIn checks a relay ticket or, from an older app, a Supabase
// access token.
func (s *Server) verifySignIn(ctx context.Context, token string) (signInIdentity, error) {
	if strings.HasPrefix(token, identityTicketPrefix) {
		id, ok := s.identityTickets.lookup(token)
		if !ok {
			return signInIdentity{}, errors.New("invalid or expired ticket")
		}
		return id, nil
	}
	if s.supabaseURL == "" {
		return signInIdentity{}, errSignInUnavailable
	}
	user, err := s.verifySupabaseToken(ctx, token)
	if err != nil {
		return signInIdentity{}, err
	}
	link := ""
	if user.Provider != "" && user.ProviderSubject != "" {
		link = s.identityLink(user.Provider, user.ProviderSubject)
	}
	return signInIdentity{Link: link, SupabaseID: user.ID, Email: user.Email,
		EmailConfirmed: user.EmailConfirmed, RecoveredAt: user.RecoveredAt}, nil
}

// identityLink is the account link for a provider's subject: a keyed hash,
// so the database names no Apple or Google account. "" without the OPRF key.
func (s *Server) identityLink(provider, subject string) string {
	if s.oprf == nil || subject == "" {
		return ""
	}
	m := hmac.New(sha256.New, s.oprf.DeriveKey("identity-links"))
	m.Write([]byte(provider + "\n" + subject))
	return provider + ":" + hex.EncodeToString(m.Sum(nil))
}

// MARK: Tickets

type identityTickets struct {
	mu sync.Mutex
	m  map[[32]byte]identityTicketEntry
}

type identityTicketEntry struct {
	id      signInIdentity
	expires time.Time
}

func newIdentityTickets() *identityTickets {
	return &identityTickets{m: map[[32]byte]identityTicketEntry{}}
}

// issue mints a ticket; it can be used until it expires (a sign-in may be
// retried after picking a username or answering two-step).
func (t *identityTickets) issue(id signInIdentity) (string, error) {
	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	token := identityTicketPrefix + base64.RawURLEncoding.EncodeToString(raw[:])
	now := time.Now()
	t.mu.Lock()
	defer t.mu.Unlock()
	for k, e := range t.m {
		if now.After(e.expires) {
			delete(t.m, k)
		}
	}
	t.m[sha256.Sum256([]byte(token))] = identityTicketEntry{id: id, expires: now.Add(identityTicketTTL)}
	return token, nil
}

func (t *identityTickets) lookup(token string) (signInIdentity, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	e, ok := t.m[sha256.Sum256([]byte(token))]
	if !ok || time.Now().After(e.expires) {
		return signInIdentity{}, false
	}
	return e.id, true
}

// MARK: Email codes

type emailCodes struct {
	mu      sync.Mutex
	salt    [32]byte
	pending map[[32]byte]*emailCode
	day     int64
	sent    int
}

type emailCode struct {
	hash     [32]byte
	purpose  mail.Purpose
	account  string
	expires  time.Time
	attempts int
}

func newEmailCodes() *emailCodes {
	c := &emailCodes{pending: map[[32]byte]*emailCode{}}
	if _, err := rand.Read(c.salt[:]); err != nil {
		panic("api: crypto/rand failed: " + err.Error())
	}
	return c
}

// key names an address's pending code without keeping the address as a key.
func (c *emailCodes) key(email string) [32]byte {
	m := hmac.New(sha256.New, c.salt[:])
	m.Write([]byte(email))
	var k [32]byte
	copy(k[:], m.Sum(nil))
	return k
}

func codeHash(code string) [32]byte { return sha256.Sum256([]byte("relay-email-code\n" + code)) }

// SetEmailCodes enables email codes, sent by sender, at most dailyCap a day.
func (s *Server) SetEmailCodes(sender mail.Sender, dailyCap int) {
	s.mailer = sender
	s.emailDailyCap = dailyCap
}

// SetIdentityProviders enables Sign in with Apple and Google (nil = off).
func (s *Server) SetIdentityProviders(apple, google *idtoken.Verifier) {
	s.appleIDs, s.googleIDs = apple, google
}

// normalizeEmail lower-cases and trims, and refuses anything that can't be an
// address.
func normalizeEmail(raw string) (string, bool) {
	email := oprf.Normalize(raw)
	at := strings.LastIndexByte(email, '@')
	if len(email) > maxEmailBytes || at < 1 || at == len(email)-1 || !strings.Contains(email[at:], ".") ||
		strings.ContainsAny(email, " \t\r\n<>,;\"") {
		return "", false
	}
	return email, true
}

func randomCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

// sendEmailCode generates, stores and sends a code; false once it has
// answered with an error.
func (s *Server) sendEmailCode(w http.ResponseWriter, r *http.Request, rawEmail string, purpose mail.Purpose, accountID string) bool {
	if s.mailer == nil {
		httpError(w, http.StatusServiceUnavailable, "email codes unavailable")
		return false
	}
	email, ok := normalizeEmail(rawEmail)
	if !ok {
		httpError(w, http.StatusBadRequest, "enter a valid email address")
		return false
	}
	if !emailSendIPLimiter.allow(clientIP(r)) || !emailSendAddressLimiter.allow("email:"+email) {
		httpError(w, http.StatusTooManyRequests, "too many codes; try again later")
		return false
	}
	code, err := randomCode()
	if err != nil {
		internalError(w, err)
		return false
	}
	c := s.emailCodes
	c.mu.Lock()
	today := time.Now().Unix() / 86400
	if c.day != today {
		c.day, c.sent = today, 0
	}
	if s.emailDailyCap > 0 && c.sent >= s.emailDailyCap {
		c.mu.Unlock()
		slog.Warn("email codes: daily cap reached")
		httpError(w, http.StatusServiceUnavailable, "email codes are busy; try again later")
		return false
	}
	c.sent++
	now := time.Now()
	for k, p := range c.pending {
		if now.After(p.expires) {
			delete(c.pending, k)
		}
	}
	c.pending[c.key(email)] = &emailCode{hash: codeHash(code), purpose: purpose, account: accountID,
		expires: now.Add(emailCodeTTL), attempts: emailCodeAttempts}
	c.mu.Unlock()

	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	if err := s.mailer.SendCode(ctx, email, purpose, code); err != nil {
		slog.Warn("email code not sent", "err", privlog.Error(err))
		httpError(w, http.StatusBadGateway, "couldn't send the email; try again")
		return false
	}
	return true
}

// POST /v1/email/code {email, purpose?} → 204 once a code is on its way.
// purpose is "signin" (the default; also creates accounts) or "reset". The
// answer is the same whether or not an account uses the address.
func (s *Server) handleEmailCode(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email   string `json:"email"`
		Purpose string `json:"purpose"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "email required")
		return
	}
	purpose := mail.SignIn
	switch req.Purpose {
	case "", string(mail.SignIn):
	case string(mail.Reset):
		purpose = mail.Reset
	default:
		httpError(w, http.StatusBadRequest, "purpose must be signin or reset")
		return
	}
	if s.sendEmailCode(w, r, req.Email, purpose, "") {
		w.WriteHeader(http.StatusNoContent)
	}
}

// POST /v1/accounts/me/email/code {email} → 204: a code to confirm a new
// address for this account (then PUT /v1/accounts/me/email with the ticket).
func (s *Server) handleAccountEmailCode(w http.ResponseWriter, r *http.Request, dev *store.Device) {
	var req struct {
		Email string `json:"email"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "email required")
		return
	}
	if s.sendEmailCode(w, r, req.Email, mail.Change, dev.AccountID) {
		w.WriteHeader(http.StatusNoContent)
	}
}

// POST /v1/email/verify {email, code} → 200 {token, email}: a ticket for the
// account endpoints. 401 for a wrong or expired code; each code allows five
// tries.
func (s *Server) handleEmailVerify(w http.ResponseWriter, r *http.Request) {
	if !emailVerifyIPLimiter.allow(clientIP(r)) {
		httpError(w, http.StatusTooManyRequests, "too many attempts; try again later")
		return
	}
	var req struct {
		Email string `json:"email"`
		Code  string `json:"code"`
	}
	if err := decodeJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "email and code required")
		return
	}
	email, ok := normalizeEmail(req.Email)
	code := strings.TrimSpace(req.Code)
	if !ok || len(code) != 6 {
		httpError(w, http.StatusUnauthorized, "that code didn't work")
		return
	}
	c := s.emailCodes
	c.mu.Lock()
	k := c.key(email)
	p, found := c.pending[k]
	var matched bool
	if found && time.Now().Before(p.expires) && p.attempts > 0 {
		got := codeHash(code)
		matched = subtle.ConstantTimeCompare(got[:], p.hash[:]) == 1
		if matched {
			delete(c.pending, k)
		} else if p.attempts--; p.attempts == 0 {
			delete(c.pending, k)
		}
	}
	c.mu.Unlock()
	if !matched {
		httpError(w, http.StatusUnauthorized, "that code didn't work")
		return
	}
	id := signInIdentity{Email: email, EmailConfirmed: true, ForAccount: p.account}
	if p.purpose == mail.Reset {
		id.RecoveredAt = time.Now()
	}
	s.writeIdentityTicket(w, id)
}

func (s *Server) writeIdentityTicket(w http.ResponseWriter, id signInIdentity) {
	token, err := s.identityTickets.issue(id)
	if err != nil {
		internalError(w, err)
		return
	}
	email := ""
	if id.EmailConfirmed {
		email = id.Email
	}
	writeJSON(w, http.StatusOK, map[string]any{"token": token, "email": email})
}

// POST /v1/identity/apple {identityToken, nonce} → 200 {token, email}: the
// app's Sign in with Apple token, checked against Apple's keys (audience the
// bundle id, nonce the one the app asked Apple to include).
func (s *Server) handleAppleIdentity(w http.ResponseWriter, r *http.Request) {
	var req struct {
		IdentityToken string `json:"identityToken"`
		Nonce         string `json:"nonce"`
	}
	if err := decodeJSON(r, &req); err != nil || req.IdentityToken == "" || req.Nonce == "" {
		httpError(w, http.StatusBadRequest, "identityToken and nonce required")
		return
	}
	s.verifyProviderToken(w, r, s.appleIDs, req.IdentityToken, req.Nonce)
}

// POST /v1/identity/google {idToken} → 200 {token, email}: a Google ID token
// issued to the app's OAuth client.
func (s *Server) handleGoogleIdentity(w http.ResponseWriter, r *http.Request) {
	var req struct {
		IDToken string `json:"idToken"`
	}
	if err := decodeJSON(r, &req); err != nil || req.IDToken == "" {
		httpError(w, http.StatusBadRequest, "idToken required")
		return
	}
	s.verifyProviderToken(w, r, s.googleIDs, req.IDToken, "")
}

func (s *Server) verifyProviderToken(w http.ResponseWriter, r *http.Request, v *idtoken.Verifier, token, nonce string) {
	if v == nil {
		httpError(w, http.StatusServiceUnavailable, "this sign-in method isn't available")
		return
	}
	if !identityTokenIPLimiter.allow(clientIP(r)) {
		httpError(w, http.StatusTooManyRequests, "too many attempts; try again later")
		return
	}
	claims, err := v.Verify(r.Context(), token, nonce)
	if err != nil {
		httpError(w, http.StatusUnauthorized, "sign-in didn't verify; try again")
		return
	}
	link := s.identityLink(v.Name(), claims.Subject)
	if link == "" {
		httpError(w, http.StatusServiceUnavailable, "this sign-in method isn't available")
		return
	}
	s.writeIdentityTicket(w, signInIdentity{Link: link, Email: claims.Email, EmailConfirmed: claims.EmailVerified})
}

// MigrateSupabaseIdentities gives every account still linked to a Supabase
// user the relay's own links, so it keeps signing in once the app stops using
// Supabase: the Apple or Google account behind it (identity_link) and, if the
// account has none, its confirmed email's token. Run once with the Supabase
// service key (relayd -migrate-supabase); safe to run again.
func (s *Server) MigrateSupabaseIdentities(ctx context.Context) (linked, emails, skipped int, err error) {
	if s.supabaseURL == "" || s.supabaseServiceKey == "" || s.oprf == nil {
		return 0, 0, 0, errors.New("needs -supabase-url, -supabase-service-key-file and -oprf-key")
	}
	accounts, err := s.store.SupabaseLinkedAccounts()
	if err != nil {
		return 0, 0, 0, err
	}
	for accountID, userID := range accounts {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.supabaseURL+"/auth/v1/admin/users/"+userID, nil)
		if err != nil {
			return linked, emails, skipped, err
		}
		req.Header.Set("apikey", s.supabaseServiceKey)
		req.Header.Set("Authorization", "Bearer "+s.supabaseServiceKey)
		resp, err := supabaseHTTPClient.Do(req)
		if err != nil {
			return linked, emails, skipped, err
		}
		var user struct {
			Email            string             `json:"email"`
			EmailConfirmedAt *string            `json:"email_confirmed_at"`
			Identities       []supabaseIdentity `json:"identities"`
		}
		decodeErr := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&user)
		resp.Body.Close()
		if resp.StatusCode == http.StatusNotFound {
			skipped++
			continue
		}
		if resp.StatusCode != http.StatusOK || decodeErr != nil {
			return linked, emails, skipped, fmt.Errorf("supabase user lookup: HTTP %d", resp.StatusCode)
		}
		if provider, subject := providerIdentity(user.Identities); provider != "" {
			if err := s.store.SetIdentityLink(accountID, s.identityLink(provider, subject)); err != nil {
				return linked, emails, skipped, err
			}
			linked++
		}
		if user.Email != "" && user.EmailConfirmedAt != nil && *user.EmailConfirmedAt != "" {
			ok, err := s.store.SetAccountEmailTokenIfEmpty(accountID, s.emailToken(user.Email))
			if err != nil {
				return linked, emails, skipped, err
			}
			if ok {
				emails++
				s.reindexAccount(accountID)
			}
		}
	}
	return linked, emails, skipped, nil
}
