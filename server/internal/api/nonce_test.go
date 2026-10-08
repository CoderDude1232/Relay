package api

import (
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestNonceCache(t *testing.T) {
	c := newNonceCache()
	now := time.Now().UnixMilli()
	exp := now + sigAuthSkew.Milliseconds()
	n1, n2 := []byte("nonce-0000000001"), []byte("nonce-0000000002")

	if err := c.checkAndStore("acct-a", 1, n1, now, exp); err != nil {
		t.Fatal(err)
	}
	if err := c.checkAndStore("acct-a", 1, n1, now, exp); err != errReplayedNonce {
		t.Fatalf("replay: got %v, want errReplayedNonce", err)
	}
	// Same nonce, different device or account: independent.
	if err := c.checkAndStore("acct-a", 2, n1, now, exp); err != nil {
		t.Fatal(err)
	}
	if err := c.checkAndStore("acct-b", 1, n1, now, exp); err != nil {
		t.Fatal(err)
	}
	// A replay is caught even when it would land in another expiry slot than
	// the first use.
	if err := c.checkAndStore("acct-a", 1, n1, now, exp+2*nonceSlotWidth.Milliseconds()); err != errReplayedNonce {
		t.Fatalf("cross-slot replay: got %v", err)
	}

	// Nothing raw is held: every key is a 16-byte salted digest.
	for i := range c.shards {
		for _, slot := range c.shards[i].slots {
			for k := range slot.nonces {
				if strings.Contains(k, "acct-") || len(k) != 16 {
					t.Fatalf("raw nonce key %q", k)
				}
			}
			for k := range slot.perDevice {
				if strings.Contains(k, "acct-") || len(k) != 16 {
					t.Fatalf("raw device key %q", k)
				}
			}
		}
	}

	// Once its slot has expired the whole slot is dropped and the nonce is
	// forgotten (a request that old fails the timestamp check anyway).
	later := exp + 2*nonceSlotWidth.Milliseconds()
	if err := c.checkAndStore("acct-a", 1, n2, later, later+sigAuthSkew.Milliseconds()); err != nil {
		t.Fatal(err)
	}
	if err := c.checkAndStore("acct-a", 1, n1, later, later+sigAuthSkew.Milliseconds()); err != nil {
		t.Fatalf("expired entry not pruned: %v", err)
	}

	// Per-device cap per slot.
	d := newNonceCache()
	for i := 0; i < maxNoncesPerSlot; i++ {
		if err := d.checkAndStore("acct-c", 1, []byte(strconv.Itoa(i)), now, exp); err != nil {
			t.Fatalf("entry %d: %v", i, err)
		}
	}
	if err := d.checkAndStore("acct-c", 1, []byte("one-too-many"), now, exp); err != errNonceBudget {
		t.Fatalf("over cap: got %v, want errNonceBudget", err)
	}
	if err := d.checkAndStore("acct-c", 2, []byte("one-too-many"), now, exp); err != nil {
		t.Fatalf("cap is not per device: %v", err)
	}
}
