package limitkey

import (
	"testing"
	"time"
)

func TestIPBucket(t *testing.T) {
	cases := map[string]string{
		"203.0.113.7:4431":                       "203.0.113.7",
		"[2001:db8:1:2:aaaa:bbbb:cccc:dddd]:443": "2001:db8:1:2::/64",
		"[2001:db8:1:2::1]:443":                  "2001:db8:1:2::/64",
		"[::ffff:203.0.113.9]:80":                "203.0.113.9",
		"2001:db8:1:3::5":                        "2001:db8:1:3::/64",
		"[fe80::1%en0]:1":                        "fe80::/64",
		"not-an-ip":                              "not-an-ip",
	}
	for in, want := range cases {
		if got := IPBucket(in); got != want {
			t.Errorf("IPBucket(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestHashIsSaltedAndRotates(t *testing.T) {
	base := time.Unix(1_700_000_000, 0)
	now = func() time.Time { return base }
	defer func() { now = time.Now }()
	mu.Lock()
	salt, prevSalt = nil, nil
	mu.Unlock()

	a := Hash("acct-1", "acct-2")
	if a == "acct-1acct-2" || len(a) != 16 {
		t.Fatalf("hash looks raw: %q", a)
	}
	if Hash("acct-1", "acct-2") != a {
		t.Fatal("hash not stable within a salt period")
	}
	if Hash("acct-1a", "cct-2") == a {
		t.Fatal("parts are not length-delimited")
	}
	if _, prev := HashCurrentAndPrevious("acct-1", "acct-2"); prev != "" {
		t.Fatal("previous-salt hash before any rotation")
	}
	now = func() time.Time { return base.Add(RotationInterval) }
	if Hash("acct-1", "acct-2") == a {
		t.Fatal("salt did not rotate")
	}
	// The pre-rotation digest stays recognisable through the previous salt.
	if cur, prev := HashCurrentAndPrevious("acct-1", "acct-2"); prev != a || cur == a {
		t.Fatalf("after rotation: cur=%x prev=%x, want prev=%x", cur, prev, a)
	}
}
