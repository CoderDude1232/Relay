package hub

import (
	"sync"
	"testing"
	"time"
)

// TestRegisterReplacesPreviousSession: a second connection for the same device
// closes the first, and the stale session's Unregister doesn't evict the new one.
func TestRegisterReplacesPreviousSession(t *testing.T) {
	h := New(nil)
	old, cur := &fakeSession{}, &fakeSession{}
	h.Register("acct", 1, old)
	h.Register("acct", 1, cur)
	if old.closed == "" {
		t.Fatal("previous session was not closed")
	}
	if cur.closed != "" {
		t.Fatal("new session was closed")
	}
	h.Unregister("acct", 1, old)
	if h.sessions[key("acct", 1)] != cur {
		t.Fatal("stale Unregister evicted the new session")
	}
}

func TestDisconnectDevice(t *testing.T) {
	h := New(nil)
	d2, d12 := &fakeSession{}, &fakeSession{}
	h.sessions[key("acct", 2)] = d2
	h.sessions[key("acct", 12)] = d12
	if !h.DisconnectDevice("acct", 2, "device removed") {
		t.Fatal("no session reported closed")
	}
	if d2.closed != "device removed" || d12.closed != "" {
		t.Fatalf("closed d2=%q d12=%q", d2.closed, d12.closed)
	}
	if _, ok := h.sessions[key("acct", 12)]; !ok {
		t.Fatal("sibling device 12 was detached")
	}
	if h.DisconnectDevice("acct", 2, "again") {
		t.Fatal("second disconnect reported a session")
	}
}

func TestQueueSharesCapPerSender(t *testing.T) {
	q := newQueueShares(2)
	if !q.reserve("s1", "acct/1", "e1") || !q.reserve("s1", "acct/1", "e2") {
		t.Fatal("reserve within limit failed")
	}
	if q.reserve("s1", "acct/1", "e3") {
		t.Fatal("reserve beyond the per-sender share succeeded")
	}
	if !q.reserve("s2", "acct/1", "e4") {
		t.Fatal("another sender was blocked by s1's share")
	}
	// An ack from the wrong device must not free the share.
	q.release("acct/9", "e1")
	if q.reserve("s1", "acct/1", "e5") {
		t.Fatal("foreign ack released a share")
	}
	q.release("acct/1", "e1")
	if !q.reserve("s1", "acct/1", "e6") {
		t.Fatal("ack did not release the share")
	}
	q.releaseWhere(func(d string) bool { return d == "acct/1" })
	if len(q.entries) != 0 || len(q.counts) != 0 {
		t.Fatalf("releaseWhere left %d entries / %d counts", len(q.entries), len(q.counts))
	}
}

func TestPushCoalescer(t *testing.T) {
	c := newPushCoalescer(80 * time.Millisecond)
	var mu sync.Mutex
	var fired []int
	fire := func(n int) func() {
		return func() { mu.Lock(); fired = append(fired, n); mu.Unlock() }
	}
	c.submit("dev", fire(1)) // immediate
	c.submit("dev", fire(2)) // coalesced...
	c.submit("dev", fire(3)) // ...latest wins as the single trailing push
	c.submit("other", fire(9))
	time.Sleep(250 * time.Millisecond)
	mu.Lock()
	defer mu.Unlock()
	got := map[int]bool{}
	for _, n := range fired {
		got[n] = true
	}
	if len(fired) != 3 || !got[1] || !got[3] || !got[9] || got[2] {
		t.Fatalf("fired %v, want {1,3,9}", fired)
	}
}
