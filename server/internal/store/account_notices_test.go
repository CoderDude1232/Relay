package store

import "testing"

func TestAccountNotices(t *testing.T) {
	s := openTestStore(t)
	acct, _, err := s.CreateAccount(uniqueName("notice"), nil, "", "device-pw-1", AccountPassword{})
	if err != nil {
		t.Fatal(err)
	}
	second, _, err := s.AddDevice(acct, "device-pw-2", 0)
	if err != nil {
		t.Fatal(err)
	}

	// Device 1 adds a passkey: only device 2 is told, once.
	if err := s.AddAccountNotice(acct, 1, NoticePasskeyAdded); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.TakeAccountNotices(acct, 1); len(got) != 0 {
		t.Fatalf("acting device got notices: %+v", got)
	}
	got, err := s.TakeAccountNotices(acct, second)
	if err != nil || len(got) != 1 || got[0].Kind != NoticePasskeyAdded {
		t.Fatalf("second device notices = %+v, %v", got, err)
	}
	if again, _ := s.TakeAccountNotices(acct, second); len(again) != 0 {
		t.Fatalf("notice delivered twice: %+v", again)
	}

	// Removing a device drops its pending notices.
	if err := s.AddAccountNotice(acct, 1, NoticeRecoveryKeySet); err != nil {
		t.Fatal(err)
	}
	version, err := s.DeviceListVersion(acct)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.RemoveDevice(acct, second, version); err != nil {
		t.Fatal(err)
	}
	if left, _ := s.TakeAccountNotices(acct, second); len(left) != 0 {
		t.Fatalf("removed device still has notices: %+v", left)
	}
}
