package api

import (
	"sync"
	"time"

	"github.com/relayapp/relay-server/internal/limitkey"
)

// failureLockout is a per-key exponential backoff for password guessing (used
// per account for recovery, keyed on the email token so it applies identically
// to registered and unregistered emails). The first lockoutFreeFailures
// failures are free; each one after that locks the key for
// lockoutBase·2^(n-free-1), capped at lockoutMax. A success clears the key;
// keys with no failure for lockoutForget are dropped.
type failureLockout struct {
	mu      sync.Mutex
	entries map[string]*lockoutEntry
	now     func() time.Time
}

type lockoutEntry struct {
	failures    int
	lockedUntil time.Time
	lastFailure time.Time
}

const (
	lockoutFreeFailures = 5
	lockoutBase         = time.Minute
	lockoutMax          = 24 * time.Hour
	lockoutForget       = 24 * time.Hour
)

func newFailureLockout() *failureLockout {
	return &failureLockout{entries: make(map[string]*lockoutEntry), now: time.Now}
}

// permit reports whether an attempt for key may proceed now.
func (l *failureLockout) permit(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	e := l.entries[key]
	if e == nil {
		return true
	}
	now := l.now()
	if now.Sub(e.lastFailure) > lockoutForget {
		delete(l.entries, key)
		return true
	}
	return !now.Before(e.lockedUntil)
}

// fail records a failed attempt and (past the free allowance) extends the lock.
func (l *failureLockout) fail(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	e := l.entries[key]
	if e == nil || now.Sub(e.lastFailure) > lockoutForget {
		e = &lockoutEntry{}
		l.entries[key] = e
	}
	e.failures++
	e.lastFailure = now
	if over := e.failures - lockoutFreeFailures; over > 0 {
		d := lockoutBase
		for i := 1; i < over && d < lockoutMax; i++ {
			d *= 2
		}
		if d > lockoutMax {
			d = lockoutMax
		}
		e.lockedUntil = now.Add(d)
	}
}

// succeed clears a key after a successful attempt.
func (l *failureLockout) succeed(key string) {
	l.mu.Lock()
	delete(l.entries, key)
	l.mu.Unlock()
}

// prune drops keys idle longer than lockoutForget.
func (l *failureLockout) prune() {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	for k, e := range l.entries {
		if now.Sub(e.lastFailure) > lockoutForget {
			delete(l.entries, k)
		}
	}
}

// recoveryLockout backs off account-password guessing: account recovery per
// email token, and the sign-in registration lock per account
// (registrationLockKey).
var recoveryLockout = newFailureLockout()

// registrationLockKey is the recoveryLockout key for an account's sign-in
// registration lock: a salted hash (limitkey), never the raw account id. The
// salt rotates daily, which also forgets the backoff — bounded anyway by
// lockoutMax (24 h).
func registrationLockKey(accountID string) string {
	return "reglock:" + limitkey.Hash("reglock", accountID)
}
