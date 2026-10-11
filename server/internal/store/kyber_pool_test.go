package store

import (
	"errors"
	"testing"
)

// TestOneTimeKyberPool: bundles take one-time Kyber prekeys while the pool
// lasts, then fall back to the last-resort key; replacing the pool clears it.
func TestOneTimeKyberPool(t *testing.T) {
	s := openTestStore(t)
	acct, _, err := s.CreateAccount(uniqueName("kyberpool"), nil, "", "device-pw-1", AccountPassword{})
	if err != nil {
		t.Fatal(err)
	}
	spk := SignedPreKey{KeyID: 1, PublicKey: []byte("spk"), Signature: []byte("sig")}
	lastResort := SignedPreKey{KeyID: 5, PublicKey: []byte("kyber-lr"), Signature: []byte("ksig")}
	pool := []SignedPreKey{
		{KeyID: 0x800001, PublicKey: []byte("kyber-1"), Signature: []byte("s1")},
		{KeyID: 0x800002, PublicKey: []byte("kyber-2"), Signature: []byte("s2")},
	}
	if err := s.SetKeysWithKyberPool(acct, 1, 7, []byte("ik"), spk, lastResort, nil, pool, false); err != nil {
		t.Fatal(err)
	}
	if n, _ := s.OneTimeKyberPreKeyCount(acct, 1); n != 2 {
		t.Fatalf("kyber pool = %d, want 2", n)
	}
	want := []uint32{0x800001, 0x800002, 5, 5}
	for i, id := range want {
		b, err := s.TakePreKeyBundles(acct, []uint32{1}, nil)
		if err != nil {
			t.Fatal(err)
		}
		if got := b[0].KyberPreKey.KeyID; got != id {
			t.Fatalf("fetch %d: kyber key %d, want %d", i, got, id)
		}
	}
	if n, _ := s.OneTimeKyberPreKeyCount(acct, 1); n != 0 {
		t.Fatalf("kyber pool = %d after use, want 0", n)
	}

	// A spent hand-out budget keeps the one-time Kyber key in the pool.
	if err := s.SetKeysWithKyberPool(acct, 1, 7, []byte("ik"), spk, lastResort, nil, pool[:1], false); err != nil {
		t.Fatal(err)
	}
	b, err := s.TakePreKeyBundles(acct, []uint32{1}, func(uint32) bool { return false })
	if err != nil {
		t.Fatal(err)
	}
	if b[0].KyberPreKey.KeyID != 5 {
		t.Fatalf("budget spent: got kyber %d, want last-resort 5", b[0].KyberPreKey.KeyID)
	}
	if n, _ := s.OneTimeKyberPreKeyCount(acct, 1); n != 1 {
		t.Fatalf("budget spent: pool = %d, want 1 (not consumed)", n)
	}

	// Replace clears it; the cap rejects an oversized pool.
	if err := s.SetKeysWithKyberPool(acct, 1, 7, []byte("ik"), spk, lastResort, nil, nil, true); err != nil {
		t.Fatal(err)
	}
	if n, _ := s.OneTimeKyberPreKeyCount(acct, 1); n != 0 {
		t.Fatalf("after replace: pool = %d, want 0", n)
	}
	big := make([]SignedPreKey, MaxOneTimeKyberPreKeysPerDevice+1)
	for i := range big {
		big[i] = SignedPreKey{KeyID: uint32(0x810000 + i), PublicKey: []byte("k"), Signature: []byte("s")}
	}
	if err := s.SetKeysWithKyberPool(acct, 1, 7, []byte("ik"), spk, lastResort, nil, big, false); !errors.Is(err, ErrPreKeyPoolFull) {
		t.Fatalf("oversized pool: %v, want ErrPreKeyPoolFull", err)
	}
}
