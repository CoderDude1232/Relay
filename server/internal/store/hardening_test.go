package store

import (
	"context"
	"errors"
	"fmt"
	"testing"
)

func mustExec(t *testing.T, s *Store, sql string, args ...any) {
	t.Helper()
	if _, err := s.db.Exec(context.Background(), sql, args...); err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
}

func testKeys(t *testing.T, s *Store, account string, device uint32) {
	t.Helper()
	if err := s.SetKeys(account, device, 7, []byte("ik"),
		SignedPreKey{KeyID: 1, PublicKey: []byte("spk"), Signature: []byte("sig")},
		SignedPreKey{KeyID: 1, PublicKey: []byte("kyber"), Signature: []byte("ksig")},
		[]OneTimePreKey{{KeyID: 1, PublicKey: []byte("otk1")}, {KeyID: 2, PublicKey: []byte("otk2")}}, false); err != nil {
		t.Fatal(err)
	}
}

// Removing a device that has published prekeys used to fail on the prekey
// foreign keys; it must now remove the device's prekeys and queue with it, and
// its id must never be handed out again.
func TestRemoveDeviceWithPrekeysAndNoIDReuse(t *testing.T) {
	s := openTestStore(t)
	acct, _, err := s.CreateAccount(uniqueName("rm"), nil, "", "device-pw-1", "")
	if err != nil {
		t.Fatal(err)
	}
	dev2, v, err := s.AddDevice(acct, "device-pw-2", 0)
	if err != nil || dev2 != 2 {
		t.Fatalf("AddDevice = %d, %v", dev2, err)
	}
	testKeys(t, s, acct, dev2)
	if err := s.Enqueue("env-"+uniqueName("q"), acct, dev2, []byte("ct")); err != nil {
		t.Fatal(err)
	}
	if v, err = s.RemoveDevice(acct, dev2, v); err != nil {
		t.Fatalf("RemoveDevice: %v", err)
	}
	for _, q := range []string{
		`SELECT COUNT(*) FROM devices WHERE account_id = $1 AND device_id = 2`,
		`SELECT COUNT(*) FROM signed_prekeys WHERE account_id = $1 AND device_id = 2`,
		`SELECT COUNT(*) FROM kyber_prekeys WHERE account_id = $1 AND device_id = 2`,
		`SELECT COUNT(*) FROM one_time_prekeys WHERE account_id = $1 AND device_id = 2`,
		`SELECT COUNT(*) FROM message_queue WHERE account_id = $1 AND device_id = 2`,
	} {
		if n := s.countRows(t, q, acct); n != 0 {
			t.Errorf("%s: %d rows remain", q, n)
		}
	}
	dev3, _, err := s.AddDevice(acct, "device-pw-3", v)
	if err != nil {
		t.Fatal(err)
	}
	if dev3 != 3 {
		t.Fatalf("new device got id %d; removed id 2 must not be reused", dev3)
	}
}

func TestDeviceCapOnEveryAddPath(t *testing.T) {
	s := openTestStore(t)
	acct, _, err := s.CreateAccount(uniqueName("cap"), nil, "", "device-pw-1", "")
	if err != nil {
		t.Fatal(err)
	}
	var v int64
	for i := 2; i <= maxDevicesPerAccount; i++ {
		if _, v, err = s.AddDevice(acct, fmt.Sprintf("device-pw-%d", i), v); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := s.AddDevice(acct, "one-too-many", v); !errors.Is(err, ErrDeviceLimit) {
		t.Fatalf("AddDevice over cap: %v", err)
	}
	if _, err := s.AllocateLinkedDevice(acct, "one-too-many", "x", v); !errors.Is(err, ErrDeviceLimit) {
		t.Fatalf("AllocateLinkedDevice over cap: %v", err)
	}
	token, code, _, err := s.CreateDeviceLinkToken(acct, v)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.ClaimDeviceLinkToken(token, code); !errors.Is(err, ErrDeviceLimit) {
		t.Fatalf("ClaimDeviceLinkToken over cap: %v", err)
	}
}

func TestLinkTokenStoresNoPassword(t *testing.T) {
	s := openTestStore(t)
	acct, _, err := s.CreateAccount(uniqueName("link"), nil, "", "device-pw-1", "")
	if err != nil {
		t.Fatal(err)
	}
	token, code, _, err := s.CreateDeviceLinkToken(acct, 0)
	if err != nil {
		t.Fatal(err)
	}
	if n := s.countRows(t, `SELECT COUNT(*) FROM device_link_tokens WHERE account_id = $1 AND password <> ''`, acct); n != 0 {
		t.Fatal("link token row holds a password")
	}
	claim, err := s.ClaimDeviceLinkToken(token, code)
	if err != nil {
		t.Fatal(err)
	}
	if claim.Password == "" {
		t.Fatal("claim returned no password")
	}
	if _, err := s.Authenticate(acct, claim.DeviceID, claim.Password); err != nil {
		t.Fatalf("claimed credentials don't authenticate: %v", err)
	}
}

func TestQueuePaging(t *testing.T) {
	s := openTestStore(t)
	acct, _, err := s.CreateAccount(uniqueName("page"), nil, "", "device-pw-1", "")
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		if err := s.Enqueue(fmt.Sprintf("env-%s-%d", acct, i), acct, 1, []byte(fmt.Sprintf("ct-%d", i))); err != nil {
			t.Fatal(err)
		}
	}
	var seen []string
	var cur QueueCursor
	for pages := 0; ; pages++ {
		if pages > 5 {
			t.Fatal("paging did not terminate")
		}
		page, more, err := s.QueuedEnvelopesPage(acct, 1, cur, 2, 1<<20)
		if err != nil {
			t.Fatal(err)
		}
		if len(page) > 2 {
			t.Fatalf("page of %d > limit 2", len(page))
		}
		for _, q := range page {
			seen = append(seen, string(q.Envelope))
			cur = QueueCursor{CreatedAt: q.CreatedAt, EnvelopeID: q.ID}
		}
		if !more {
			break
		}
	}
	if len(seen) != 5 {
		t.Fatalf("paged %d envelopes, want 5: %v", len(seen), seen)
	}
	// The byte cap still returns at least one envelope per page.
	page, more, err := s.QueuedEnvelopesPage(acct, 1, QueueCursor{}, 100, 1)
	if err != nil || len(page) != 1 || !more {
		t.Fatalf("byte-capped page: %d envelopes, more=%v, err=%v", len(page), more, err)
	}
}

func TestPurgeExpiredAndCoarseTimestamps(t *testing.T) {
	s := openTestStore(t)
	acct, _, err := s.CreateAccount(uniqueName("purge"), nil, "", "device-pw-1", "")
	if err != nil {
		t.Fatal(err)
	}
	testKeys(t, s, acct, 1)
	if n := s.countRows(t, `SELECT COUNT(*) FROM signed_prekeys WHERE account_id = $1 AND created_at <> 0`, acct); n != 0 {
		t.Fatal("signed prekey upload time recorded")
	}
	if n := s.countRows(t, `SELECT COUNT(*) FROM accounts WHERE id = $1 AND created_at % 86400000 <> 0`, acct); n != 0 {
		t.Fatal("account created_at is not day-granular")
	}
	tok, _, err := s.CreateContactInvite(acct)
	if err != nil {
		t.Fatal(err)
	}
	mustExec(t, s, `UPDATE contact_invites SET expires_at = 1 WHERE token = $1`, tok)
	mustExec(t, s, `INSERT INTO message_queue (envelope_id, account_id, device_id, envelope, created_at) VALUES ($1, $2, 1, 'x', 1)`, "old-"+acct, acct)
	if err := s.PurgeExpired(); err != nil {
		t.Fatal(err)
	}
	if n := s.countRows(t, `SELECT COUNT(*) FROM contact_invites WHERE token = $1`, tok); n != 0 {
		t.Fatal("expired contact invite not purged")
	}
	if n := s.countRows(t, `SELECT COUNT(*) FROM message_queue WHERE account_id = $1`, acct); n != 0 {
		t.Fatal("expired envelope not purged")
	}
}

// A device that never published keys (e.g. an unfinished link) must not make
// the whole account unreachable: an all-devices fetch skips it. Asking for that
// device specifically, or an account with no keyed device at all, is still 404.
func TestBundlesSkipKeylessDevice(t *testing.T) {
	s := openTestStore(t)
	acct, _, err := s.CreateAccount(uniqueName("keyless"), nil, "", "device-pw-1", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.TakePreKeyBundles(acct, nil, nil); !errors.Is(err, ErrNotFound) {
		t.Fatalf("no keyed device: err = %v, want ErrNotFound", err)
	}
	testKeys(t, s, acct, 1)
	dev2, _, err := s.AddDevice(acct, "device-pw-2", 0)
	if err != nil {
		t.Fatal(err)
	}
	bundles, err := s.TakePreKeyBundles(acct, nil, nil)
	if err != nil {
		t.Fatalf("all devices with a keyless one: %v", err)
	}
	if len(bundles) != 1 || bundles[0].DeviceID != 1 {
		t.Fatalf("bundles = %+v, want only device 1", bundles)
	}
	if _, err := s.TakePreKeyBundles(acct, []uint32{dev2}, nil); !errors.Is(err, ErrNotFound) {
		t.Fatalf("keyless device by id: err = %v, want ErrNotFound", err)
	}
}
