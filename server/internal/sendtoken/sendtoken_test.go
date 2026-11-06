package sendtoken

import (
	"bytes"
	"encoding/hex"
	"errors"
	"testing"
	"time"

	"github.com/gtank/ristretto255"
)

func scalar(b byte) *ristretto255.Scalar {
	var rb [64]byte
	rb[0] = b
	return ristretto255.NewScalar().FromUniformBytes(rb[:])
}

func issue(t *testing.T, is *Issuer, day int64, nonce []byte) string {
	t.Helper()
	r := scalar(3)
	b := Blind(day, nonce, r)
	e, proof, err := is.Evaluate(b)
	if err != nil {
		t.Fatal(err)
	}
	n, ok := Finish(is.PublicKey(), b, e, proof, r)
	if !ok {
		t.Fatal("proof didn't verify")
	}
	return Format(day, nonce, n)
}

func TestSpend(t *testing.T) {
	is := NewIssuer(bytes.Repeat([]byte{9}, 32))
	now := time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)
	is.now = func() time.Time { return now }
	today := is.Today()

	tok := issue(t, is, today, bytes.Repeat([]byte{1}, NonceLength))
	if err := is.Spend(tok); err != nil {
		t.Fatal(err)
	}
	if err := is.Spend(tok); !errors.Is(err, ErrSpent) {
		t.Fatalf("second spend: %v", err)
	}
	// Yesterday's still works; older doesn't.
	if err := is.Spend(issue(t, is, today-1, bytes.Repeat([]byte{2}, NonceLength))); err != nil {
		t.Fatalf("yesterday: %v", err)
	}
	if err := is.Spend(issue(t, is, today-2, bytes.Repeat([]byte{3}, NonceLength))); !errors.Is(err, ErrExpired) {
		t.Fatalf("two days old: %v", err)
	}
	// Another key's token, a changed day, garbage.
	other := NewIssuer(bytes.Repeat([]byte{8}, 32))
	other.now = is.now
	if err := is.Spend(issue(t, other, today, bytes.Repeat([]byte{4}, NonceLength))); !errors.Is(err, ErrInvalid) {
		t.Fatalf("other key: %v", err)
	}
	moved := issue(t, is, today-1, bytes.Repeat([]byte{5}, NonceLength))
	_, nonce, point, _ := Parse(moved)
	if err := is.Spend(Format(today, nonce, point)); !errors.Is(err, ErrInvalid) {
		t.Fatalf("relabelled day: %v", err)
	}
	for _, bad := range []string{"", "x", "1.abc", "20398"} {
		if err := is.Spend(bad); !errors.Is(err, ErrMalformed) {
			t.Errorf("%q: %v", bad, err)
		}
	}
	// A proof against another key doesn't verify.
	r := scalar(3)
	b := Blind(today, bytes.Repeat([]byte{6}, NonceLength), r)
	e, proof, _ := is.Evaluate(b)
	if _, ok := Finish(other.PublicKey(), b, e, proof, r); ok {
		t.Fatal("proof verified against the wrong key")
	}
	// Spent entries go once they can't be spent anyway.
	now = now.Add(72 * time.Hour)
	_ = is.Spend(issue(t, is, is.Today(), bytes.Repeat([]byte{7}, NonceLength)))
	if len(is.spent) != 1 {
		t.Fatalf("spent set holds %d", len(is.spent))
	}
}

// Fixed values the app's SendTokens interop check uses.
func TestInteropVector(t *testing.T) {
	is := NewIssuer(bytes.Repeat([]byte{7}, 32))
	nonce := bytes.Repeat([]byte{1}, NonceLength)
	r := scalar(3)
	b := Blind(20398, nonce, r)
	e, proof, _ := is.Evaluate(b)
	n, ok := Finish(is.PublicKey(), b, e, proof, r)
	if !ok {
		t.Fatal("proof")
	}
	got := map[string]string{
		"publicKey": hex.EncodeToString(is.PublicKey()),
		"blinded":   hex.EncodeToString(b),
		"evaluated": hex.EncodeToString(e),
		"unblinded": hex.EncodeToString(n),
	}
	want := map[string]string{
		"publicKey": "5ef6d5ebd3e4e3a03d8bc7819abb2a107a3fc3b9d8b1d35080fced4a891bce42",
		"blinded":   "2284095a7030e7f01374d290b43d88c1e64af50c498c76d66c554c25461f733f",
		"evaluated": "38d466f98f1a7820de0bedcafff94c57771cedf62a66612f055edbf371c0f67f",
		"unblinded": "eefc221a983fe1f93aa2667e2ba092b1de6874af188196da22e921fc2e2d1054",
	}
	for k, v := range got {
		if want[k] != v {
			t.Errorf("%s = %s, want %s", k, v, want[k])
		}
	}
}
