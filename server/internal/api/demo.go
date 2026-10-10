package api

import (
	"net/http"
	"sync"
	"time"
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
