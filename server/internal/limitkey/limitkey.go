// Package limitkey derives the keys the relay's in-memory abuse limiters are
// indexed by, without ever holding a raw identifier in those maps.
//
// Every limiter key (a source-IP bucket, an account id, an "A:B" requester /
// target pair) is replaced by a keyed hash under a random salt that lives only
// in memory and rotates daily. A heap dump or debugger attached to the process
// therefore yields opaque digests rather than a list of client IPs or a
// who-talks-to-whom graph, and digests from different days can't be linked.
// The trade-off: a rotation re-keys every limiter, so counters effectively
// restart at most once per day.
package limitkey

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"net"
	"strings"
	"sync"
	"time"
)

// RotationInterval is how long one salt is used before it is replaced.
const RotationInterval = 24 * time.Hour

var (
	mu        sync.Mutex
	salt      []byte
	prevSalt  []byte // the salt before the last rotation (nil until one happens)
	rotatedAt time.Time
	now       = time.Now // test hook
)

// salts returns the current salt (rotating it when due) and the previous one.
func salts() (cur, prev []byte) {
	mu.Lock()
	defer mu.Unlock()
	t := now()
	if salt == nil || t.Sub(rotatedAt) >= RotationInterval {
		s := make([]byte, 32)
		if _, err := rand.Read(s); err != nil {
			panic("limitkey: crypto/rand failed: " + err.Error())
		}
		prevSalt = salt
		salt, rotatedAt = s, t
	}
	return salt, prevSalt
}

func hashWith(key []byte, parts []string) string {
	m := hmac.New(sha256.New, key)
	for _, p := range parts {
		l := len(p)
		m.Write([]byte{byte(l >> 24), byte(l >> 16), byte(l >> 8), byte(l)})
		m.Write([]byte(p))
	}
	return string(m.Sum(nil)[:16])
}

// Hash returns an opaque 16-byte digest (as a string, usable as a map key) of
// the given parts under the current in-memory salt. Parts are length-delimited
// so ("ab","c") and ("a","bc") never collide.
func Hash(parts ...string) string {
	cur, _ := salts()
	return hashWith(cur, parts)
}

// HashCurrentAndPrevious returns Hash(parts...) under the current salt and
// under the salt it replaced ("" before the first rotation). A short-lived
// cache whose correctness depends on recognising an entry (the Relay-Sig
// replay cache) checks both, so a rotation can't make a just-stored entry
// unrecognisable.
func HashCurrentAndPrevious(parts ...string) (cur, prev string) {
	c, p := salts()
	cur = hashWith(c, parts)
	if p != nil {
		prev = hashWith(p, parts)
	}
	return cur, prev
}

// stableSalt keys Stable. It is random per process and never rotates.
var stableSalt = func() []byte {
	s := make([]byte, 32)
	if _, err := rand.Read(s); err != nil {
		panic("limitkey: crypto/rand failed: " + err.Error())
	}
	return s
}()

// Stable is Hash under a salt that lasts as long as the process. It is for
// in-memory bookkeeping that must still match its entries after a daily
// rotation (queue shares live for the 14-day queue TTL, a pending ceremony
// must be found again minutes later). Digests are linkable for the life of the
// process, so prefer Hash where a reset at rotation is harmless.
func Stable(parts ...string) string {
	return hashWith(stableSalt, parts)
}

// IPBucket maps a request's RemoteAddr ("host:port", or a bare host) to the
// unit an IP-based limiter should count: the full address for IPv4, and the
// /64 prefix for IPv6 (a single subscriber is routinely handed a whole /64, so
// keying on the full v6 address would let one client rotate through 2^64
// limiter keys). Unparseable input is returned unchanged.
func IPBucket(remoteAddr string) string {
	host := remoteAddr
	if h, _, err := net.SplitHostPort(remoteAddr); err == nil {
		host = h
	}
	// Strip an IPv6 zone ("fe80::1%en0").
	if i := strings.IndexByte(host, '%'); i >= 0 {
		host = host[:i]
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return host
	}
	if v4 := ip.To4(); v4 != nil {
		return v4.String()
	}
	return ip.Mask(net.CIDRMask(64, 128)).String() + "/64"
}
