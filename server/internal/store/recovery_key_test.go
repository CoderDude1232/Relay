package store

import (
	"bytes"
	"crypto/rand"
	"errors"
	"strings"
	"testing"
)

func TestCreatePasskeyAccount(t *testing.T) {
	s := openTestStore(t)
	name := uniqueName("pk-signup")
	handle := make([]byte, 32)
	rand.Read(handle)
	credID := []byte("signup-" + name)
	dev, err := s.CreatePasskeyAccount(name, handle, credID, []byte(`{"signCount":0}`), "iPhone", "device-pw-1")
	if err != nil {
		t.Fatal(err)
	}
	if dev.AccountID == "" || dev.DeviceID != 1 || dev.Username != name || dev.MailboxID == "" || len(dev.ReplacedDevices) != 0 {
		t.Fatalf("added device: %+v", dev)
	}
	if _, err := s.Authenticate(dev.AccountID, 1, "device-pw-1"); err != nil {
		t.Fatalf("device 1: %v", err)
	}
	if n := s.countRows(t, `SELECT count(*) FROM accounts WHERE id = $1 AND email_token IS NULL AND supabase_user_id IS NULL
		AND account_password_hash IS NULL AND recovery_key_hash IS NULL AND created_at % 86400000 = 0`, dev.AccountID); n != 1 {
		t.Fatal("account row has an email, link, password or exact created_at")
	}
	if id, username, demo, err := s.PasskeyAccount(handle); err != nil || id != dev.AccountID || username != name || demo {
		t.Fatalf("PasskeyAccount: %q %q %v %v", id, username, demo, err)
	}
	if h, _, err := s.PasskeyUserHandle(dev.AccountID); err != nil || !bytes.Equal(h, handle) {
		t.Fatalf("handle replaced: %x %v", h, err)
	}
	list, err := s.ListPasskeys(dev.AccountID)
	if err != nil || len(list) != 1 || !bytes.Equal(list[0].CredentialID, credID) || list[0].Name != "iPhone" || list[0].CreatedAt%86400000 != 0 {
		t.Fatalf("passkeys: %+v %v", list, err)
	}
	m, err := s.AccountSignInMethods(dev.AccountID)
	if err != nil || m != (SignInMethods{Passkeys: 1}) {
		t.Fatalf("sign-in methods: %+v %v", m, err)
	}

	other := make([]byte, 32)
	rand.Read(other)
	if _, err := s.CreatePasskeyAccount(strings.ToUpper(name), other, []byte("x-"+name), []byte(`{}`), "", "device-pw-2"); !errors.Is(err, ErrUsernameTaken) {
		t.Fatalf("taken username: %v", err)
	}
	name2 := uniqueName("pk-signup2")
	if _, err := s.CreatePasskeyAccount(name2, other, credID, []byte(`{}`), "", "device-pw-2"); !errors.Is(err, ErrPasskeyExists) {
		t.Fatalf("duplicate credential: %v", err)
	}
	if n := s.countRows(t, `SELECT count(*) FROM accounts WHERE username = $1`, name2); n != 0 {
		t.Fatal("account created despite the failed passkey insert")
	}
}

func TestSignInMethodsAndRemoveEmail(t *testing.T) {
	s := openTestStore(t)
	token := []byte(uniqueName("email-token"))
	acct, _, err := s.CreateAccount(uniqueName("rm-email"), token, uniqueName("supa"), "device-pw-1", LegacyPassword("account-pw-1"))
	if err != nil {
		t.Fatal(err)
	}
	if err := s.SetEmailDiscoverable(acct, true); err != nil {
		t.Fatal(err)
	}
	if err := s.SetDirectoryForAccount(acct, []DirectoryEntry{
		{Token: []byte(uniqueName("dir-user")), AccountID: acct, Kind: DirectoryKindUsername},
		{Token: token, AccountID: acct, Kind: DirectoryKindEmail},
	}); err != nil {
		t.Fatal(err)
	}
	m, err := s.AccountSignInMethods(acct)
	if err != nil || m != (SignInMethods{Email: true, AccountPassword: true}) {
		t.Fatalf("before: %+v %v", m, err)
	}

	if err := s.RemoveAccountEmail(acct); err != nil {
		t.Fatal(err)
	}
	if n := s.countRows(t, `SELECT count(*) FROM accounts WHERE id = $1 AND email_token IS NULL AND supabase_user_id IS NULL
		AND NOT email_discoverable AND account_password_hash IS NOT NULL`, acct); n != 1 {
		t.Fatal("email fields not cleared")
	}
	if n := s.countRows(t, `SELECT count(*) FROM directory WHERE account_id = $1 AND kind = 1`, acct); n != 0 {
		t.Fatalf("%d email directory rows left", n)
	}
	if n := s.countRows(t, `SELECT count(*) FROM directory WHERE account_id = $1 AND kind = 0`, acct); n != 1 {
		t.Fatalf("username directory row lost (%d)", n)
	}
	if m, err := s.AccountSignInMethods(acct); err != nil || m.Email {
		t.Fatalf("after: %+v %v", m, err)
	}
	if err := s.RemoveAccountEmail("no-such-account"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown account: %v", err)
	}
	if _, err := s.AccountSignInMethods("no-such-account"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown account methods: %v", err)
	}

	// A Supabase link alone counts as an email.
	linked, _, err := s.CreateAccount(uniqueName("rm-email-link"), nil, uniqueName("supa"), "device-pw-1", AccountPassword{})
	if err != nil {
		t.Fatal(err)
	}
	if m, err := s.AccountSignInMethods(linked); err != nil || !m.Email || m.AccountPassword {
		t.Fatalf("link only: %+v %v", m, err)
	}
}

func TestRecoveryKeyHash(t *testing.T) {
	s := openTestStore(t)
	acct, _, err := s.CreateAccount(uniqueName("rk"), nil, "", "device-pw-1", AccountPassword{})
	if err != nil {
		t.Fatal(err)
	}
	other, _, err := s.CreateAccount(uniqueName("rk-other"), nil, "", "device-pw-2", AccountPassword{})
	if err != nil {
		t.Fatal(err)
	}
	h1, h2 := make([]byte, 32), make([]byte, 32)
	rand.Read(h1)
	rand.Read(h2)

	if _, _, err := s.RecoveryKeyAccount(h1); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unset: %v", err)
	}
	if err := s.SetRecoveryKeyHash(acct, h1); err != nil {
		t.Fatal(err)
	}
	if id, demo, err := s.RecoveryKeyAccount(h1); err != nil || id != acct || demo {
		t.Fatalf("lookup: %q %v %v", id, demo, err)
	}
	if m, _ := s.AccountSignInMethods(acct); !m.RecoveryKey {
		t.Fatal("sign-in methods missing the recovery key")
	}
	if err := s.SetRecoveryKeyHash(acct, h2); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.RecoveryKeyAccount(h1); !errors.Is(err, ErrNotFound) {
		t.Fatalf("replaced key still resolves: %v", err)
	}
	if id, _, err := s.RecoveryKeyAccount(h2); err != nil || id != acct {
		t.Fatalf("new key: %q %v", id, err)
	}
	if err := s.SetRecoveryKeyHash(other, h2); !errors.Is(err, ErrRecoveryKeyInUse) {
		t.Fatalf("shared hash: %v", err)
	}
	if err := s.SetRecoveryKeyHash("no-such-account", h1); !errors.Is(err, ErrAccountNotFound) {
		t.Fatalf("unknown account: %v", err)
	}
	if err := s.ClearRecoveryKeyHash(acct); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.RecoveryKeyAccount(h2); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cleared key still resolves: %v", err)
	}
	if m, _ := s.AccountSignInMethods(acct); m.RecoveryKey {
		t.Fatal("sign-in methods still report a recovery key")
	}
	// The column goes with the row.
	if err := s.SetRecoveryKeyHash(other, h1); err != nil {
		t.Fatal(err)
	}
	if err := s.DeleteAccount(other); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.RecoveryKeyAccount(h1); !errors.Is(err, ErrNotFound) {
		t.Fatalf("deleted account's key still resolves: %v", err)
	}
}

func TestProvisionReplacementDevice(t *testing.T) {
	s := openTestStore(t)
	// The registration lock doesn't apply: the caller verified a stand-in.
	acct, oldDevice, err := s.CreateAccount(uniqueName("replace"), nil, "", "device-pw-1", LegacyPassword("account-pw-1"))
	if err != nil {
		t.Fatal(err)
	}
	dev, err := s.ProvisionReplacementDevice(acct, "new-device-pw")
	if err != nil {
		t.Fatal(err)
	}
	if dev.AccountID != acct || dev.Username == "" || dev.MailboxID == "" || dev.DeviceID == oldDevice || dev.DeviceListVersion == 0 {
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
	if _, err := s.ProvisionReplacementDevice("no-such-account", "new-device-pw"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown account: %v", err)
	}
}
