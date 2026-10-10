package api

import (
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/relayapp/relay-server/internal/store"
)

// Demo accounts (store/demo.go) are an island: they only find, fetch keys for
// and message other demo accounts, and everyone else can't find or reach them.
// Their username, email and account password are locked, they can't turn on
// email discovery, and "delete account" resets them instead.

const demoForbiddenMessage = "This is a demo account, so this is turned off."

// demoCache memoises IsDemoAccount; the flag is set by an operator and rarely
// changes, so a short TTL is plenty.
type demoCache struct {
	mu      sync.Mutex
	entries map[string]demoCacheEntry
}

type demoCacheEntry struct {
	demo bool
	at   time.Time
}

const demoCacheTTL = time.Minute

var demoFlags = demoCache{entries: map[string]demoCacheEntry{}}

func (s *Server) isDemo(accountID string) bool {
	if accountID == "" {
		return false
	}
	demoFlags.mu.Lock()
	if e, ok := demoFlags.entries[accountID]; ok && time.Since(e.at) < demoCacheTTL {
		demoFlags.mu.Unlock()
		return e.demo
	}
	demoFlags.mu.Unlock()
	demo, err := s.store.IsDemoAccount(accountID)
	if err != nil {
		return false // fail open on DB hiccups; the DB-backed checks still run
	}
	demoFlags.mu.Lock()
	if len(demoFlags.entries) > 50_000 {
		demoFlags.entries = map[string]demoCacheEntry{}
	}
	demoFlags.entries[accountID] = demoCacheEntry{demo: demo, at: time.Now()}
	demoFlags.mu.Unlock()
	return demo
}

// crossesDemoLine reports whether a and b are on different sides (one demo,
// one not). An account is never on a different side from itself.
func (s *Server) crossesDemoLine(a, b string) bool {
	return a != b && s.isDemo(a) != s.isDemo(b)
}

// refuseIfDemo writes 403 and returns true for a demo account.
func (s *Server) refuseIfDemo(w http.ResponseWriter, accountID string) bool {
	if s.isDemo(accountID) {
		httpError(w, http.StatusForbidden, demoForbiddenMessage)
		return true
	}
	return false
}

// SetDemoCode enables the review-code sign-in (POST /v1/accounts/demo-signin).
// Empty disables it.
func (s *Server) SetDemoCode(code string) {
	code = strings.TrimSpace(code)
	if code == "" {
		s.demoCodeHash = nil
		return
	}
	h := sha256.Sum256([]byte(strings.ToUpper(code)))
	s.demoCodeHash = h[:]
}

// handleDemoSignIn is the App Review sign-in: a short code signs this device
// in to a demo account without email or password. The code only ever unlocks
// the isolated demo accounts.
func (s *Server) handleDemoSignIn(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !accountCreationLimiter.allow("demo:" + ip) {
		httpError(w, http.StatusTooManyRequests, "too many attempts; try again later")
		return
	}
	var req struct {
		Code string `json:"code"`
	}
	if err := decodeJSON(r, &req); err != nil || len(req.Code) > 128 {
		httpError(w, http.StatusBadRequest, "code required")
		return
	}
	given := sha256.Sum256([]byte(strings.ToUpper(strings.TrimSpace(req.Code))))
	if len(s.demoCodeHash) == 0 || subtle.ConstantTimeCompare(given[:], s.demoCodeHash) != 1 {
		httpError(w, http.StatusUnauthorized, "that review code isn't valid")
		return
	}
	dev, devicePassword, err := s.store.DemoSignIn()
	if errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusNotFound, "no demo account is set up")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"accountId":      dev.AccountID,
		"username":       dev.Username,
		"deviceId":       dev.DeviceID,
		"devicePassword": devicePassword,
		"mailboxId":      dev.MailboxID,
	})
	s.retireReplacedDevices(dev)
}

// handleDemoStatus tells the app whether it's signed in to a demo account (so
// it can hide what's switched off) and which other demo accounts to show in
// its chat list.
func (s *Server) handleDemoStatus(w http.ResponseWriter, _ *http.Request, dev *store.Device) {
	if !s.isDemo(dev.AccountID) {
		writeJSON(w, http.StatusOK, map[string]any{"demo": false, "peers": []string{}})
		return
	}
	peers, err := s.store.DemoPeers(dev.AccountID)
	if err != nil {
		internalError(w, err)
		return
	}
	if peers == nil {
		peers = []string{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"demo": true, "peers": peers})
}
