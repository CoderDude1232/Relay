package hub

import (
	"errors"
	"sync"
	"time"
)

// ErrSenderQuota is returned by DeliverFrom when one sender already occupies
// its maximum share of the destination device's offline queue.
var ErrSenderQuota = errors.New("hub: sender's share of the destination queue is full")

// maxQueuedPerSender caps how many still-queued (unacked) envelopes a single
// sender (an authenticated account, or a source-IP bucket for sealed sends)
// may hold in one destination device's offline queue. The device queue itself
// holds at most 500 envelopes / 50 MB, so without this one hostile
// sender could fill a victim's queue and make everyone else's messages bounce.
const maxQueuedPerSender = 200

// queueShares tracks, in memory, how many queued envelopes each (sender,
// destination) pair currently holds. Share keys are salted hashes (limitkey),
// computed once at enqueue and stored with the envelope, so salt rotation never
// strands a count. The accounting is best-effort: it starts empty after a
// restart and entries older than the queue TTL are pruned (expired rows are
// deleted without an ack).
type queueShares struct {
	mu      sync.Mutex
	limit   int
	counts  map[string]int        // envelopes currently queued, by share key
	entries map[string]shareEntry // by envelope id
}

type shareEntry struct {
	share  string
	device string // shareDevice of the destination
	at     time.Time
}

func newQueueShares(limit int) *queueShares {
	return &queueShares{limit: limit, counts: map[string]int{}, entries: map[string]shareEntry{}}
}

// reserve records envelopeID as queued under share for device, or returns
// false if the share is already at its limit.
func (q *queueShares) reserve(share, device, envelopeID string) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.counts[share] >= q.limit {
		return false
	}
	q.counts[share]++
	q.entries[envelopeID] = shareEntry{share: share, device: device, at: time.Now()}
	return true
}

// release frees the share held by envelopeID if it was queued for device.
// Unknown ids (pre-restart envelopes, sealed retries, bogus acks) are a no-op.
func (q *queueShares) release(device, envelopeID string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	e, ok := q.entries[envelopeID]
	if !ok || e.device != device {
		return
	}
	q.drop(envelopeID, e)
}

// releaseWhere frees every share held in the queues of devices whose session
// key matches (the device was removed, or the account's queues purged).
func (q *queueShares) releaseWhere(match func(device string) bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for id, e := range q.entries {
		if match(e.device) {
			q.drop(id, e)
		}
	}
}

func (q *queueShares) drop(envelopeID string, e shareEntry) {
	delete(q.entries, envelopeID)
	if q.counts[e.share]--; q.counts[e.share] <= 0 {
		delete(q.counts, e.share)
	}
}

// prune forgets entries older than maxAge (their rows have expired).
func (q *queueShares) prune(maxAge time.Duration) {
	cutoff := time.Now().Add(-maxAge)
	q.mu.Lock()
	defer q.mu.Unlock()
	for id, e := range q.entries {
		if e.at.Before(cutoff) {
			q.drop(id, e)
		}
	}
}

// pushCoalesceWindow is the minimum spacing between alert pushes to one
// device. A burst of messages produces one push now and at most one trailing
// push at the end of the window (so the last message is never left without a
// wake), instead of one push per message.
const pushCoalesceWindow = 3 * time.Second

// pushCoalescer rate-limits push sends per device with a trailing edge.
type pushCoalescer struct {
	mu     sync.Mutex
	window time.Duration
	state  map[string]*coalesceState
}

type coalesceState struct {
	last    time.Time
	pending func() // non-nil while a trailing push is scheduled; latest wins
}

func newPushCoalescer(window time.Duration) *pushCoalescer {
	return &pushCoalescer{window: window, state: map[string]*coalesceState{}}
}

// submit runs fire now (in a new goroutine) if the device hasn't been pushed
// within the window; otherwise it schedules a single trailing push at the end
// of the window, replacing any earlier scheduled one with this newer fire.
func (c *pushCoalescer) submit(key string, fire func()) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := time.Now()
	st := c.state[key]
	if st == nil {
		st = &coalesceState{}
		c.state[key] = st
	}
	if st.pending == nil && now.Sub(st.last) >= c.window {
		st.last = now
		go fire()
		return
	}
	scheduled := st.pending != nil
	st.pending = fire
	if !scheduled {
		time.AfterFunc(st.last.Add(c.window).Sub(now), func() { c.flush(key) })
	}
}

func (c *pushCoalescer) flush(key string) {
	c.mu.Lock()
	st := c.state[key]
	var fire func()
	if st != nil {
		fire, st.pending = st.pending, nil
		st.last = time.Now()
	}
	c.mu.Unlock()
	if fire != nil {
		fire()
	}
}

// prune drops idle per-device state.
func (c *pushCoalescer) prune() {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := time.Now()
	for k, st := range c.state {
		if st.pending == nil && now.Sub(st.last) > c.window {
			delete(c.state, k)
		}
	}
}
