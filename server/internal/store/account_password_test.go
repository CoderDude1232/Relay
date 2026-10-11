package store

import (
	"errors"
	"testing"
)

func TestAccountPasswordKeysAndUpgrade(t *testing.T) {
	const key = "k-0123456789abcdef0123456789abcdef0123456789"

	// A key-era hash accepts only the key.
	keyed, err := AccountPassword{Key: key}.hash()
	if err != nil {
		t.Fatal(err)
	}
	if ok, _, err := (AccountPassword{Key: key}).verify(keyed); !ok || err != nil {
		t.Fatalf("key rejected: %v %v", ok, err)
	}
	if ok, _, _ := (AccountPassword{Key: key + "x"}).verify(keyed); ok {
		t.Fatal("wrong key accepted")
	}
	if ok, _, _ := LegacyPassword(key).verify(keyed); ok {
		t.Fatal("raw value accepted against a keyed hash")
	}

	// A raw-password hash asks for the one-time upgrade, then upgrades.
	legacy, err := LegacyPassword("old-password").hash()
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := (AccountPassword{Key: key}).verify(legacy); !errors.Is(err, ErrAccountPasswordUpgradeRequired) {
		t.Fatalf("key against a raw hash: err = %v, want upgrade required", err)
	}
	if ok, up, _ := (AccountPassword{Key: key, Legacy: "wrong"}).verify(legacy); ok || up != nil {
		t.Fatal("wrong raw password upgraded")
	}
	ok, upgraded, err := AccountPassword{Key: key, Legacy: "old-password"}.verify(legacy)
	if !ok || err != nil || upgraded == nil {
		t.Fatalf("upgrade: ok=%v err=%v upgraded=%v", ok, err, upgraded != nil)
	}
	if ok, _, _ := (AccountPassword{Key: key}).verify(upgraded); !ok {
		t.Fatal("upgraded hash rejects the key")
	}
	// Older clients still work against a raw hash.
	if ok, up, _ := LegacyPassword("old-password").verify(legacy); !ok || up != nil {
		t.Fatal("older client rejected")
	}
}
