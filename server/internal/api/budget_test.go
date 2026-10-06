package api

import (
	"testing"
	"time"
)

func TestElementBudget(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	b := newElementBudget(map[string]budgetSpec{
		"acct:": {capacity: 100, period: 100 * time.Second},
		"ip:":   {capacity: 150, period: 100 * time.Second},
	})
	b.now = func() time.Time { return now }

	if !b.take(60, "acct:a", "ip:1") {
		t.Fatal("first take refused")
	}
	if b.take(60, "acct:a", "ip:1") {
		t.Fatal("over-budget take allowed (account has 40 left)")
	}
	// The refused take must not have debited the IP bucket.
	if !b.take(90, "acct:b", "ip:1") {
		t.Fatal("ip bucket wrongly debited by refused take")
	}
	if b.take(1, "acct:c", "ip:1") {
		t.Fatal("ip budget exhausted but take allowed")
	}
	now = now.Add(10 * time.Second) // +10 account tokens, +15 ip tokens
	if !b.take(15, "acct:c", "ip:1") {
		t.Fatal("refill not applied")
	}
	now = now.Add(time.Hour)
	b.prune()
	if len(b.buckets) != 0 {
		t.Fatalf("fully refilled buckets not pruned: %d", len(b.buckets))
	}
}
