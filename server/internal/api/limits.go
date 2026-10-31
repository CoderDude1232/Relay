package api

import (
	"fmt"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"time"

	"github.com/relayapp/relay-server/internal/limitkey"
)

// clientIP returns the rate-limiting bucket for the request's source address:
// the full IPv4 address, or the /64 prefix of an IPv6 address. It is only ever
// used as limiter input (which hashes it); it is never logged or stored.
func clientIP(r *http.Request) string {
	return limitkey.IPBucket(sourceAddr(r))
}

// trustedProxies are the networks whose forwarded client address we accept
// (Cloudflare, when the relay sits behind it). Set once at startup, before
// serving; empty means proxy headers are never trusted.
var trustedProxies []netip.Prefix

// sourceAddr is the address limits should key on. Behind a trusted proxy every
// connection comes from the proxy, so per-IP limits (and the failed-auth
// lockout) would lump all users together; the proxy's CF-Connecting-IP header
// carries the real client. The header is honoured only when the TCP peer is a
// trusted proxy; anyone else could set it to dodge or poison rate limits.
func sourceAddr(r *http.Request) string {
	if addr, ok := r.Context().Value(sourceAddrKey{}).(string); ok {
		return addr
	}
	return forwardedSourceAddr(r)
}

func forwardedSourceAddr(r *http.Request) string {
	if len(trustedProxies) == 0 {
		return r.RemoteAddr
	}
	peer, err := netip.ParseAddrPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	from := peer.Addr().Unmap()
	trusted := false
	for _, p := range trustedProxies {
		if p.Contains(from) {
			trusted = true
			break
		}
	}
	if !trusted {
		return r.RemoteAddr
	}
	client, err := netip.ParseAddr(strings.TrimSpace(r.Header.Get("CF-Connecting-IP")))
	if err != nil {
		return r.RemoteAddr
	}
	return client.Unmap().String()
}

// cloudflareRanges are Cloudflare's published edge ranges
// (https://www.cloudflare.com/ips/).
var cloudflareRanges = []string{
	"173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
	"141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
	"197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
	"104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
	"2400:cb00::/32", "2606:4700::/32", "2803:f800::/32", "2405:b500::/32",
	"2405:8100::/32", "2a06:98c0::/29", "2c0f:f248::/32",
}

// SetTrustedProxies configures whose CF-Connecting-IP header is honoured:
// "" (none), "cloudflare" (the built-in Cloudflare ranges), or a
// comma-separated CIDR list.
func SetTrustedProxies(spec string) error {
	spec = strings.TrimSpace(spec)
	if spec == "" {
		trustedProxies = nil
		return nil
	}
	cidrs := strings.Split(spec, ",")
	if spec == "cloudflare" {
		cidrs = cloudflareRanges
	}
	var out []netip.Prefix
	for _, c := range cidrs {
		p, err := netip.ParsePrefix(strings.TrimSpace(c))
		if err != nil {
			return fmt.Errorf("trusted proxy %q: %w", c, err)
		}
		out = append(out, p.Masked())
	}
	trustedProxies = out
	return nil
}

// tokenBucketLimiter is a keyed token bucket. Unlike slidingWindowLimiter it
// costs O(1) memory per key regardless of the limit, so it is used for the
// high-rate limits (message sends) and for byte budgets. Keys are hashed with
// limitkey.Hash before they touch the map.
type tokenBucketLimiter struct {
	mu      sync.Mutex
	buckets map[string]*tokenBucket
	burst   float64 // bucket capacity
	rate    float64 // tokens refilled per second
}

type tokenBucket struct {
	tokens float64
	last   time.Time
}

// newTokenBucketLimiter allows burst events at once, refilled at burst per
// per.
func newTokenBucketLimiter(burst float64, per time.Duration) *tokenBucketLimiter {
	l := &tokenBucketLimiter{
		buckets: make(map[string]*tokenBucket),
		burst:   burst,
		rate:    burst / per.Seconds(),
	}
	allLimiters = append(allLimiters, l)
	return l
}

func (l *tokenBucketLimiter) reset() {
	l.mu.Lock()
	l.buckets = make(map[string]*tokenBucket)
	l.mu.Unlock()
}

// allLimiters holds every package limiter so tests, which all share one
// process and source IP, can start each case from empty buckets.
var allLimiters []interface {
	reset()
	prune()
}

// refill returns the (refilled) bucket for an already-hashed key. Caller holds mu.
func (l *tokenBucketLimiter) refill(hk string, now time.Time) *tokenBucket {
	b := l.buckets[hk]
	if b == nil {
		b = &tokenBucket{tokens: l.burst, last: now}
		l.buckets[hk] = b
		return b
	}
	b.tokens += now.Sub(b.last).Seconds() * l.rate
	if b.tokens > l.burst {
		b.tokens = l.burst
	}
	b.last = now
	return b
}

// allow consumes one token if available.
func (l *tokenBucketLimiter) allow(key string) bool { return l.allowN(key, 1) }

// allowN consumes n tokens if at least n are available.
func (l *tokenBucketLimiter) allowN(key string, n float64) bool {
	hk := limitkey.Hash(key)
	l.mu.Lock()
	defer l.mu.Unlock()
	b := l.refill(hk, time.Now())
	if b.tokens < n {
		return false
	}
	b.tokens -= n
	return true
}

// exhausted reports whether the key has less than one token left, without
// consuming anything.
func (l *tokenBucketLimiter) exhausted(key string) bool {
	hk := limitkey.Hash(key)
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.buckets[hk] == nil {
		return false // never spent anything: full; don't allocate an entry
	}
	return l.refill(hk, time.Now()).tokens < 1
}

// consume unconditionally removes n tokens; the balance may go negative (debt
// that is repaid by refill before the key is allowed again). Used for byte
// budgets where the size is only known after the work is done.
func (l *tokenBucketLimiter) consume(key string, n float64) {
	hk := limitkey.Hash(key)
	l.mu.Lock()
	defer l.mu.Unlock()
	l.refill(hk, time.Now()).tokens -= n
}

// refund returns n tokens to the key, capped at the bucket capacity. Used to
// give back the unused part of a reservation taken with allowN.
func (l *tokenBucketLimiter) refund(key string, n float64) {
	hk := limitkey.Hash(key)
	l.mu.Lock()
	defer l.mu.Unlock()
	b := l.refill(hk, time.Now())
	b.tokens += n
	if b.tokens > l.burst {
		b.tokens = l.burst
	}
}

// prune drops buckets that have refilled to capacity (indistinguishable from a
// fresh key), bounding memory for one-off keys.
func (l *tokenBucketLimiter) prune() {
	now := time.Now()
	l.mu.Lock()
	defer l.mu.Unlock()
	for k, b := range l.buckets {
		if b.tokens+now.Sub(b.last).Seconds()*l.rate >= l.burst {
			delete(l.buckets, k)
		}
	}
}

// Failed authentications (bcrypt is deliberately slow, so unbounded guessing is
// both a credential-guessing and a CPU-exhaustion vector). Only failures spend
// tokens; once a bucket is empty further attempts get 429 before any password
// hashing or signature verification runs.
//
// Per source IP bucket (IPv4 address / IPv6 /64): 50 failures per 10 minutes,
// on the HTTP Basic (password) path only.
var authFailIPLimiter = newTokenBucketLimiter(50, 10*time.Minute)

// Failed Relay-Sig verifications per source IP before that address is refused
// up front: 1000 per 10 minutes. Far above anything real; it exists so a flood
// of bad signatures can't keep the database busy. A valid signature from a busy
// shared address is never refused below this.
var sigFailFloodLimiter = newTokenBucketLimiter(1000, 10*time.Minute)

// Per target device: 20 failed HTTP Basic attempts per 10 minutes. Applied to
// the Basic (password) path only. Relay-Sig has nothing guessable and must not
// be lockable by a third party who knows a device's account id.
var authFailDeviceLimiter = newTokenBucketLimiter(20, 10*time.Minute)

// Authenticated WebSocket sends per sender account: bursts of 1000 frames
// (a large-group fan-out is one frame per member device), refilled at 1200/min.
var wsSendLimiter = newTokenBucketLimiter(1000, 50*time.Second)

// One-time prekey hand-outs. Draining a target's OTK pool degrades its future
// sessions to signed-prekey-only PQXDH, so OTKs are budgeted separately from
// bundle fetches: once a budget is spent the bundle is still served without an
// OTK (signed prekey and last-resort Kyber prekey only), so honest session
// setup keeps working while the pool is protected.
//
// Per target device (across all requesters): 60 OTKs per hour.
var preKeyTargetOTKLimiter = newTokenBucketLimiter(60, time.Hour)

// Per requesting account (across all targets): 300 OTKs per hour.
var preKeyRequesterOTKLimiter = newTokenBucketLimiter(300, time.Hour)

// Per (requester, target device): 6 one-time hand-outs per hour.
var preKeyPairOTKLimiter = newTokenBucketLimiter(6, time.Hour)

// Unauthenticated provisioning-session polls (GET /v1/provisioning-sessions/{id})
// per source IP bucket: bursts of 120, refilled at 1/s. Comfortably above a
// new device polling once a second for the session's 10-minute life, far
// below what enumerating session ids would need.
var provisioningPollIPLimiter = newTokenBucketLimiter(120, 2*time.Minute)

// Contact invites minted per account: 50 per rolling day (each is a DB row).
var contactInviteLimiter = newTokenBucketLimiter(50, 24*time.Hour)

// Successful username changes per account: 5 per rolling day. Only completed
// changes spend budget (a "taken" answer is free), and every change releases
// the old name into the reuse cooldown, so unbounded renames would let one
// account churn through names.
var usernameChangeLimiter = newTokenBucketLimiter(5, 24*time.Hour)

// Default per-account attachment upload quotas (overridable with
// SetAttachmentQuota or the -attachment-daily-* flags).
const (
	defaultAttachmentDailyBytes = 2 << 30 // 2 GiB
	defaultAttachmentDailyCount = 1000
)

// attachmentQuota tracks per-account upload budgets. Allocation (POST
// /v1/attachments) spends one unit of the count budget and remembers which
// (hashed) account owns the id, so the byte budget can be charged when the
// ciphertext is uploaded, even on an upload path that carries no credentials.
type attachmentQuota struct {
	count *tokenBucketLimiter
	bytes *tokenBucketLimiter

	mu     sync.Mutex
	owners map[string]attachmentOwner // by blob id
}

type attachmentOwner struct {
	key string // limitkey.Hash of the account id
	at  time.Time
	max int64 // size limit for this upload; 0 = the default
}

// attachmentOwnerTTL bounds how long an allocation is remembered (uploads are
// expected right after allocation).
const attachmentOwnerTTL = 24 * time.Hour

func newAttachmentQuota(dailyBytes int64, dailyCount int) *attachmentQuota {
	return &attachmentQuota{
		count:  newTokenBucketLimiter(float64(dailyCount), 24*time.Hour),
		bytes:  newTokenBucketLimiter(float64(dailyBytes), 24*time.Hour),
		owners: make(map[string]attachmentOwner),
	}
}

// allocate charges one allocation to accountID and records it as the owner of
// id. Returns false when the account's daily count or byte budget is spent.
func (q *attachmentQuota) allocate(accountID, id string) bool {
	owner := limitkey.Hash("attach", accountID)
	if q.bytes.exhausted(owner) || !q.count.allow(owner) {
		return false
	}
	q.mu.Lock()
	q.owners[id] = attachmentOwner{key: owner, at: time.Now()}
	q.mu.Unlock()
	return true
}

// setMax records a larger size limit for an allocated id (Relay Supporter).
func (q *attachmentQuota) setMax(id string, max int64) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if o, ok := q.owners[id]; ok {
		o.max = max
		q.owners[id] = o
	}
}

// maxFor is the size limit recorded for id (0 = the default).
func (q *attachmentQuota) maxFor(id string) int64 {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.owners[id].max
}

// ownerKey returns the budget key for an upload to id: its recorded allocator,
// else the fallback account (e.g. the authenticated uploader after a restart
// lost the in-memory allocation record). ok is false when neither is known.
func (q *attachmentQuota) ownerKey(id, fallbackAccount string) (key string, ok bool) {
	q.mu.Lock()
	o, found := q.owners[id]
	q.mu.Unlock()
	if found {
		return o.key, true
	}
	if fallbackAccount != "" {
		return limitkey.Hash("attach", fallbackAccount), true
	}
	return "", false
}

// unknownAttachmentOwner is the budget key for uploads to ids whose allocation
// record was lost (allocated before a restart). All such uploads share one
// account-sized daily byte budget.
var unknownAttachmentOwner = limitkey.Hash("attach-unknown")

// reserveUpload takes n bytes from the owner's daily budget before an upload
// starts, so parallel uploads can't overrun it. Returns false (taking
// nothing) when fewer than n bytes are left.
func (q *attachmentQuota) reserveUpload(ownerKey string, n int64) bool {
	return q.bytes.allowN(ownerKey, float64(n))
}

// settleUpload refunds the unused part of a reservation (all of it when
// nothing was stored) and forgets the allocation (a blob id is uploaded once).
func (q *attachmentQuota) settleUpload(id, ownerKey string, reserved, used int64) {
	if used < reserved {
		q.bytes.refund(ownerKey, float64(reserved-used))
	}
	q.mu.Lock()
	delete(q.owners, id)
	q.mu.Unlock()
}

func (q *attachmentQuota) prune() {
	q.count.prune()
	q.bytes.prune()
	cutoff := time.Now().Add(-attachmentOwnerTTL)
	q.mu.Lock()
	for id, o := range q.owners {
		if o.at.Before(cutoff) {
			delete(q.owners, id)
		}
	}
	q.mu.Unlock()
}
