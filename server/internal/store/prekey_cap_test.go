package store

import (
	"errors"
	"testing"
)

func otkBatch(from, n int) []OneTimePreKey {
	out := make([]OneTimePreKey, n)
	for i := range out {
		out[i] = OneTimePreKey{KeyID: uint32(from + i), PublicKey: []byte("otk")}
	}
	return out
}

// TestOneTimePreKeyPoolCap: a device's stored one-time pool can't exceed
// MaxOneTimePreKeysPerDevice; an upload that would is rejected whole, while
// re-uploading existing ids and replacing the pool still work.
func TestOneTimePreKeyPoolCap(t *testing.T) {
	s := openTestStore(t)
	acct, _, err := s.CreateAccount(uniqueName("otkcap"), nil, "", "device-pw-1", "")
	if err != nil {
		t.Fatal(err)
	}
	spk := SignedPreKey{KeyID: 1, PublicKey: []byte("spk"), Signature: []byte("sig")}
	kyber := SignedPreKey{KeyID: 1, PublicKey: []byte("kyber"), Signature: []byte("ksig")}
	set := func(otks []OneTimePreKey, replace bool) error {
		return s.SetKeys(acct, 1, 7, []byte("ik"), spk, kyber, otks, replace)
	}
	if err := set(otkBatch(1, MaxOneTimePreKeysPerDevice), false); err != nil {
		t.Fatal(err)
	}
	if err := set(otkBatch(1, 10), false); err != nil {
		t.Fatalf("re-uploading existing ids at the cap: %v", err)
	}
	if err := set(otkBatch(MaxOneTimePreKeysPerDevice+1, 1), false); !errors.Is(err, ErrPreKeyPoolFull) {
		t.Fatalf("upload past the cap: %v, want ErrPreKeyPoolFull", err)
	}
	if n, _ := s.OneTimePreKeyCount(acct, 1); n != MaxOneTimePreKeysPerDevice {
		t.Fatalf("pool holds %d after a rejected upload, want %d", n, MaxOneTimePreKeysPerDevice)
	}
	if err := set(otkBatch(5000, 100), true); err != nil {
		t.Fatalf("replacing the pool: %v", err)
	}
	if n, _ := s.OneTimePreKeyCount(acct, 1); n != 100 {
		t.Fatalf("pool after replace = %d, want 100", n)
	}
}
