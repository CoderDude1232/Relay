package store

import (
	"crypto/rand"
	"errors"
	"testing"
	"time"
)

func TestSupporterBooks(t *testing.T) {
	s := openTestStore(t)
	acct, _, err := s.CreateAccount(uniqueName("supporter"), nil, "", "pw", AccountPassword{})
	if err != nil {
		t.Fatal(err)
	}
	if until, err := s.SupporterUntil(acct); err != nil || until != 0 {
		t.Fatalf("new account: %d %v", until, err)
	}

	tx := make([]byte, 32)
	rand.Read(tx)
	future := time.Now().Add(time.Hour).UnixMilli()
	for i, want := range []bool{true, true, false} {
		if ok, err := s.ClaimSupporterIssuance(tx, future, 2); err != nil || ok != want {
			t.Fatalf("issuance %d: %v %v", i, ok, err)
		}
	}

	nonce := make([]byte, 32)
	rand.Read(nonce)
	end1 := time.Now().Add(24 * time.Hour).UnixMilli()
	if until, err := s.RedeemSupporterCredential(acct, nonce, end1); err != nil || until != end1 {
		t.Fatalf("redeem: %d %v", until, err)
	}
	if _, err := s.RedeemSupporterCredential(acct, nonce, end1); !errors.Is(err, ErrCredentialSpent) {
		t.Fatalf("double spend: %v", err)
	}
	// An earlier period never shortens it.
	nonce2 := make([]byte, 32)
	rand.Read(nonce2)
	if until, err := s.RedeemSupporterCredential(acct, nonce2, end1-1000); err != nil || until != end1 {
		t.Fatalf("earlier period: %d %v", until, err)
	}
	// Unknown account: the credential isn't spent.
	nonce3 := make([]byte, 32)
	rand.Read(nonce3)
	if _, err := s.RedeemSupporterCredential("no-such-account", nonce3, end1); !errors.Is(err, ErrAccountNotFound) {
		t.Fatalf("unknown account: %v", err)
	}
	if n := s.countRows(t, `SELECT count(*) FROM supporter_spent WHERE nonce_tag = $1`, nonce3); n != 0 {
		t.Fatal("credential spent on a failed redeem")
	}
}
