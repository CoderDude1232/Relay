package api

import (
	"testing"
	"time"
)

func TestFailureLockoutBacksOff(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	l := newFailureLockout()
	l.now = func() time.Time { return now }

	for i := 0; i < lockoutFreeFailures; i++ {
		if !l.permit("k") {
			t.Fatalf("locked after %d failures, want %d free", i, lockoutFreeFailures)
		}
		l.fail("k")
	}
	if !l.permit("k") {
		t.Fatal("free failures should not lock")
	}
	l.fail("k") // first paid failure: lockoutBase
	if l.permit("k") {
		t.Fatal("not locked after exceeding the free allowance")
	}
	if !l.permit("other") {
		t.Fatal("lock leaked to another key")
	}
	now = now.Add(lockoutBase)
	if !l.permit("k") {
		t.Fatal("still locked after the backoff elapsed")
	}
	l.fail("k") // second paid failure: 2*lockoutBase
	now = now.Add(lockoutBase)
	if l.permit("k") {
		t.Fatal("backoff did not grow")
	}
	now = now.Add(lockoutBase)
	if !l.permit("k") {
		t.Fatal("doubled backoff did not elapse")
	}
	l.succeed("k")
	l.fail("k")
	if !l.permit("k") {
		t.Fatal("success should reset the failure count")
	}

	for i := 0; i < 64; i++ {
		l.fail("cap")
	}
	if e := l.entries["cap"]; e.lockedUntil.Sub(now) > lockoutMax {
		t.Fatalf("backoff exceeded cap: %v", e.lockedUntil.Sub(now))
	}
	now = now.Add(lockoutForget + time.Second)
	l.prune()
	if _, ok := l.entries["cap"]; ok {
		t.Fatal("idle key not pruned")
	}
}
