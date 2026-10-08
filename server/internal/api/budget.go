package api

import (
	"strings"
	"sync"
	"time"

	"github.com/relayapp/relay-server/internal/limitkey"
)

// elementBudget is a keyed token bucket that meters work in units (e.g. OPRF
// elements evaluated) rather than requests. Each key prefix has its own
// capacity, refilled continuously over period. take(n, keys...) succeeds only
// if EVERY key has n tokens, and then debits all of them atomically.
type elementBudget struct {
	mu      sync.Mutex
	specs   map[string]budgetSpec // by key prefix
	buckets map[string]*budgetBucket
	now     func() time.Time
}

type budgetSpec struct {
	capacity float64
	period   time.Duration
}

type budgetBucket struct {
	tokens float64
	last   time.Time
	spec   budgetSpec
}

func newElementBudget(specs map[string]budgetSpec) *elementBudget {
	return &elementBudget{specs: specs, buckets: make(map[string]*budgetBucket), now: time.Now}
}

func (b *elementBudget) specFor(key string) (budgetSpec, bool) {
	for prefix, spec := range b.specs {
		if strings.HasPrefix(key, prefix) {
			return spec, true
		}
	}
	return budgetSpec{}, false
}

// bucket returns the bucket for raw key, refilled to now (callers hold mu).
// The map is indexed by limitkey.Hash(key) — never the raw account id or IP —
// and the spec is chosen from the raw key's prefix before hashing.
func (b *elementBudget) bucket(key string, now time.Time) *budgetBucket {
	hk := limitkey.Hash(key)
	bk := b.buckets[hk]
	if bk == nil {
		spec, ok := b.specFor(key)
		if !ok {
			return nil
		}
		bk = &budgetBucket{tokens: spec.capacity, last: now, spec: spec}
		b.buckets[hk] = bk
		return bk
	}
	bk.refill(now)
	return bk
}

// refill tops the bucket up for the time elapsed since it was last touched.
func (bk *budgetBucket) refill(now time.Time) {
	if elapsed := now.Sub(bk.last); elapsed > 0 {
		bk.tokens += bk.spec.capacity * float64(elapsed) / float64(bk.spec.period)
		if bk.tokens > bk.spec.capacity {
			bk.tokens = bk.spec.capacity
		}
		bk.last = now
	}
}

func (b *elementBudget) take(n int, keys ...string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	need := float64(n)
	var hit []*budgetBucket
	for _, k := range keys {
		bk := b.bucket(k, now)
		if bk == nil {
			continue
		}
		if bk.tokens < need {
			return false
		}
		hit = append(hit, bk)
	}
	for _, bk := range hit {
		bk.tokens -= need
	}
	return true
}

// prune drops buckets that have refilled completely (indistinguishable from new).
func (b *elementBudget) prune() {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	for hk, bk := range b.buckets {
		bk.refill(now)
		if bk.tokens >= bk.spec.capacity {
			delete(b.buckets, hk)
		}
	}
}
