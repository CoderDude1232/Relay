package store

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"testing"
)

// openTestStore connects to the Postgres named by RELAY_TEST_DSN (same switch
// as the API integration tests) and skips otherwise.
func openTestStore(t *testing.T) *Store {
	t.Helper()
	dsn := os.Getenv("RELAY_TEST_DSN")
	if dsn == "" {
		t.Skip("set RELAY_TEST_DSN to run Postgres-backed store tests")
	}
	s, err := Open(dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func uniqueName(prefix string) string {
	var b [4]byte
	rand.Read(b[:])
	return prefix + "-" + hex.EncodeToString(b[:])
}

func (s *Store) countRows(t *testing.T, query string, args ...any) int {
	t.Helper()
	var n int
	if err := s.db.QueryRow(context.Background(), query, args...).Scan(&n); err != nil {
		t.Fatalf("%s: %v", query, err)
	}
	return n
}

func TestDeleteAccountRemovesEverything(t *testing.T) {
	s := openTestStore(t)

	victimName := uniqueName("victim")
	victim, _, err := s.CreateAccount(victimName, []byte(uniqueName("emailtok")), "", "device-pw-1", LegacyPassword("recovery-pw-1"))
	if err != nil {
		t.Fatal(err)
	}
	other, _, err := s.CreateAccount(uniqueName("other"), nil, "", "device-pw-2", AccountPassword{})
	if err != nil {
		t.Fatal(err)
	}

	// Populate every table keyed to the victim.
	if err := s.SetKeys(victim, 1, 42, []byte("ik"),
		SignedPreKey{KeyID: 1, PublicKey: []byte("spk"), Signature: []byte("sig")},
		SignedPreKey{KeyID: 1, PublicKey: []byte("kyber"), Signature: []byte("ksig")},
		[]OneTimePreKey{{KeyID: 1, PublicKey: []byte("otk1")}, {KeyID: 2, PublicKey: []byte("otk2")}}, false); err != nil {
		t.Fatal(err)
	}
	if err := s.SetAPNSToken(victim, 1, "apns"); err != nil {
		t.Fatal(err)
	}
	if err := s.SetVoIPToken(victim, 1, "voip"); err != nil {
		t.Fatal(err)
	}
	if err := s.SetAccessKey(victim, make([]byte, 32)); err != nil {
		t.Fatal(err)
	}
	if err := s.Enqueue("env-"+uniqueName("q"), victim, 1, []byte("ciphertext")); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.CreateContactInvite(victim); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := s.CreateDeviceLinkToken(victim, 0); err != nil {
		t.Fatal(err)
	}
	if err := s.StoreNuke(NukeRecord{AccountID: victim, CommandID: uniqueName("nuke"), CreationTimeMs: 1, InitiatingDeviceID: 1, Signature: []byte("s")}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetDirectoryForAccount(victim, []DirectoryEntry{{Token: []byte(uniqueName("dirtok")), AccountID: victim, Kind: DirectoryKindUsername}}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.CreateReport(victim, other, "spam", "filed by victim", `["hi"]`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.CreateReport(other, victim, "harassment", "filed against victim", ""); err != nil {
		t.Fatal(err)
	}

	if err := s.DeleteAccount(victim); err != nil {
		t.Fatal(err)
	}

	for _, q := range []string{
		`SELECT COUNT(*) FROM accounts WHERE id = $1`,
		`SELECT COUNT(*) FROM devices WHERE account_id = $1`,
		`SELECT COUNT(*) FROM signed_prekeys WHERE account_id = $1`,
		`SELECT COUNT(*) FROM kyber_prekeys WHERE account_id = $1`,
		`SELECT COUNT(*) FROM one_time_prekeys WHERE account_id = $1`,
		`SELECT COUNT(*) FROM message_queue WHERE account_id = $1`,
		`SELECT COUNT(*) FROM device_link_tokens WHERE account_id = $1`,
		`SELECT COUNT(*) FROM contact_invites WHERE account_id = $1`,
		`SELECT COUNT(*) FROM directory WHERE account_id = $1`,
		`SELECT COUNT(*) FROM nuke_commands WHERE account_id = $1`,
		`SELECT COUNT(*) FROM reports WHERE reporter_account = $1`,
	} {
		if n := s.countRows(t, q, victim); n != 0 {
			t.Errorf("%s: %d rows remain", q, n)
		}
	}
	// Reports AGAINST the deleted account are moderation records and survive.
	against, err := s.ReportsAgainst(victim)
	if err != nil {
		t.Fatal(err)
	}
	if len(against) != 1 || against[0].ReporterAccount != other || against[0].Messages != "[]" {
		t.Fatalf("reports against deleted account: %+v", against)
	}
	// The other account is untouched.
	if n := s.countRows(t, `SELECT COUNT(*) FROM accounts WHERE id = $1`, other); n != 1 {
		t.Fatal("unrelated account was deleted")
	}
	// Username is free again (this store has no release key, so no reuse
	// cooldown; see TestUsernameReuseCooldown).
	if _, err := s.LookupAccountID(victimName); !errors.Is(err, ErrNotFound) {
		t.Fatalf("username still resolves after delete: %v", err)
	}
	if _, _, err := s.CreateAccount(victimName, nil, "", "device-pw-3", AccountPassword{}); err != nil {
		t.Fatalf("re-register freed username: %v", err)
	}
	// Deleting again is a clean not-found.
	if err := s.DeleteAccount(victim); !errors.Is(err, ErrNotFound) {
		t.Fatalf("second delete: %v, want ErrNotFound", err)
	}
}
