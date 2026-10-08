package store

import (
	"errors"
	"fmt"
	"sync"
	"testing"
)

// TestEnqueueCapIsAtomic: concurrent senders racing for the last free slots of
// a device queue can't overshoot maxQueuedPerDevice (the count-then-insert runs
// under the device row lock), and a vanished device gets ErrNotFound.
func TestEnqueueCapIsAtomic(t *testing.T) {
	s := openTestStore(t)
	acct, _, err := s.CreateAccount(uniqueName("qcap"), nil, "", "device-pw-1", "")
	if err != nil {
		t.Fatal(err)
	}
	const prefill = maxQueuedPerDevice - 10
	for i := 0; i < prefill; i++ {
		if err := s.Enqueue(fmt.Sprintf("pre-%s-%d", acct, i), acct, 1, []byte("ct")); err != nil {
			t.Fatal(err)
		}
	}
	const racers = 40
	var wg sync.WaitGroup
	var mu sync.Mutex
	ok, full := 0, 0
	for i := 0; i < racers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			err := s.Enqueue(fmt.Sprintf("race-%s-%d", acct, i), acct, 1, []byte("ct"))
			mu.Lock()
			defer mu.Unlock()
			switch {
			case err == nil:
				ok++
			case errors.Is(err, ErrQueueFull):
				full++
			default:
				t.Errorf("enqueue %d: %v", i, err)
			}
		}(i)
	}
	wg.Wait()
	if ok != 10 || full != racers-10 {
		t.Fatalf("racing enqueues: %d accepted, %d full; want 10 / %d", ok, full, racers-10)
	}
	if n := s.countRows(t, `SELECT COUNT(*) FROM message_queue WHERE account_id = $1 AND device_id = 1`, acct); n != maxQueuedPerDevice {
		t.Fatalf("queue holds %d envelopes, cap is %d", n, maxQueuedPerDevice)
	}

	if err := s.Enqueue("env-ghost", acct, 99, []byte("ct")); !errors.Is(err, ErrNotFound) {
		t.Fatalf("enqueue to a nonexistent device: %v, want ErrNotFound", err)
	}
}
