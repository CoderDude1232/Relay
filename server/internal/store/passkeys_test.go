package store

import (
	"bytes"
	"errors"
	"fmt"
	"testing"
)

func TestPasskeyCRUD(t *testing.T) {
	s := openTestStore(t)
	acct, _, err := s.CreateAccount(uniqueName("pk"), nil, "", "device-pw-1", AccountPassword{})
	if err != nil {
		t.Fatal(err)
	}
	other, _, err := s.CreateAccount(uniqueName("pk-other"), nil, "", "device-pw-2", AccountPassword{})
	if err != nil {
		t.Fatal(err)
	}

	h1, name, err := s.PasskeyUserHandle(acct)
	if err != nil || len(h1) != 32 || name == "" {
		t.Fatalf("handle: %x %q %v", h1, name, err)
	}
	if h2, _, _ := s.PasskeyUserHandle(acct); !bytes.Equal(h1, h2) {
		t.Fatal("user handle changed between calls")
	}
	if hOther, _, _ := s.PasskeyUserHandle(other); bytes.Equal(h1, hOther) {
		t.Fatal("two accounts share a user handle")
	}
	if id, _, demo, err := s.PasskeyAccount(h1); err != nil || id != acct || demo {
		t.Fatalf("PasskeyAccount: %q %v %v", id, demo, err)
	}
	if _, _, _, err := s.PasskeyAccount([]byte("unknown")); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown handle: %v", err)
	}

	cred := func(i int) []byte { return []byte(fmt.Sprintf("cred-%s-%d", acct, i)) }
	for i := 0; i < MaxPasskeysPerAccount; i++ {
		if err := s.AddPasskey(acct, cred(i), []byte(`{"n":1}`), "key"); err != nil {
			t.Fatalf("add %d: %v", i, err)
		}
	}
	if err := s.AddPasskey(acct, cred(99), []byte(`{}`), ""); !errors.Is(err, ErrPasskeyLimit) {
		t.Fatalf("over the limit: %v", err)
	}
	if err := s.AddPasskey(other, cred(0), []byte(`{}`), ""); !errors.Is(err, ErrPasskeyExists) {
		t.Fatalf("duplicate credential id: %v", err)
	}
	list, err := s.ListPasskeys(acct)
	if err != nil || len(list) != MaxPasskeysPerAccount {
		t.Fatalf("list: %d %v", len(list), err)
	}
	if list[0].CreatedAt%86400000 != 0 || list[0].Name != "key" {
		t.Fatalf("created_at not day-rounded or name lost: %+v", list[0])
	}

	if err := s.DeletePasskey(other, cred(0)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("deleting another account's passkey: %v", err)
	}
	if err := s.DeletePasskey(acct, cred(0)); err != nil {
		t.Fatal(err)
	}
	if err := s.DeletePasskey(acct, cred(0)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("second delete: %v", err)
	}

	if err := s.DeleteAccount(acct); err != nil {
		t.Fatalf("delete account with passkeys: %v", err)
	}
	if n := s.countRows(t, `SELECT count(*) FROM passkeys WHERE account_id = $1`, acct); n != 0 {
		t.Fatalf("%d passkeys survived account deletion", n)
	}
}

func TestProvisionPasskeyDevice(t *testing.T) {
	s := openTestStore(t)
	// A registration lock doesn't apply: the verified passkey stands in for it.
	acct, oldDevice, err := s.CreateAccount(uniqueName("pk-prov"), nil, "", "device-pw-1", LegacyPassword("account-pw-1"))
	if err != nil {
		t.Fatal(err)
	}
	credID := []byte("prov-" + acct)
	if err := s.AddPasskey(acct, credID, []byte(`{"signCount":0}`), ""); err != nil {
		t.Fatal(err)
	}

	if _, err := s.ProvisionPasskeyDevice(acct, []byte("missing"), []byte(`{}`), "new-device-pw"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown credential: %v", err)
	}
	dev, err := s.ProvisionPasskeyDevice(acct, credID, []byte(`{"signCount":5}`), "new-device-pw")
	if err != nil {
		t.Fatal(err)
	}
	if dev.AccountID != acct || dev.Username == "" || dev.MailboxID == "" || dev.DeviceID == oldDevice {
		t.Fatalf("added device: %+v", dev)
	}
	if len(dev.ReplacedDevices) != 1 || dev.ReplacedDevices[0] != oldDevice {
		t.Fatalf("replaced devices: %v", dev.ReplacedDevices)
	}
	if _, err := s.Authenticate(acct, oldDevice, "device-pw-1"); err == nil {
		t.Fatal("old device still authenticates")
	}
	if _, err := s.Authenticate(acct, dev.DeviceID, "new-device-pw"); err != nil {
		t.Fatalf("new device: %v", err)
	}
	list, err := s.ListPasskeys(acct)
	if err != nil || len(list) != 1 || !bytes.Contains(list[0].Credential, []byte("5")) {
		t.Fatalf("credential not updated: %+v %v", list, err)
	}
}
