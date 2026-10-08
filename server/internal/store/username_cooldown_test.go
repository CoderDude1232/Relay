package store

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestUsernameReuseCooldown(t *testing.T) {
	s := openTestStore(t)
	s.SetUsernameReleaseKey([]byte("test-release-key-0123456789abcdef"))
	ctx := context.Background()

	old := uniqueName("cool")
	alice, _, err := s.CreateAccount(old, nil, "", "device-pw-1", "")
	if err != nil {
		t.Fatal(err)
	}
	bob, _, err := s.CreateAccount(uniqueName("cool-bob"), nil, "", "device-pw-2", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.UpdateUsername(alice, uniqueName("cool-new")); err != nil {
		t.Fatal(err)
	}

	// Only keyed hashes are stored — never the name.
	var nameHash, ownerHash []byte
	if err := s.db.QueryRow(ctx, `SELECT name_hash, owner_hash FROM released_usernames WHERE name_hash = $1`,
		s.releasedNameHash(old)).Scan(&nameHash, &ownerHash); err != nil {
		t.Fatalf("release not recorded: %v", err)
	}
	if bytes.Contains(nameHash, []byte(old)) || bytes.Contains(ownerHash, []byte(alice)) {
		t.Fatal("released_usernames holds a raw identifier")
	}

	// Blocked for others (case-insensitively), on every claim path.
	if taken, err := s.UsernameTaken(strings.ToUpper(old)); err != nil || !taken {
		t.Fatalf("UsernameTaken during cooldown = %v, %v", taken, err)
	}
	if err := s.UpdateUsername(bob, old); !errors.Is(err, ErrUsernameTaken) {
		t.Fatalf("other account renaming into the cooldown: %v", err)
	}
	if _, _, err := s.CreateAccount(strings.ToUpper(old), nil, "", "device-pw-3", ""); !errors.Is(err, ErrUsernameTaken) {
		t.Fatalf("registering a cooling name: %v", err)
	}
	if _, _, err := s.ProvisionOAuthAccount(uniqueName("sb"), nil, old, "device-pw-4", "", nil); !errors.Is(err, ErrUsernameTaken) {
		t.Fatalf("oauth sign-up with a cooling name: %v", err)
	}

	// The original owner may take it back (and the row is cleared).
	if err := s.UpdateUsername(alice, old); err != nil {
		t.Fatalf("owner reclaiming its old name: %v", err)
	}
	if n := s.countRows(t, `SELECT COUNT(*) FROM released_usernames WHERE name_hash = $1`, s.releasedNameHash(old)); n != 0 {
		t.Fatal("reclaimed name still has a cooldown row")
	}

	// Deletion blocks the name for everyone.
	if err := s.DeleteAccount(alice); err != nil {
		t.Fatal(err)
	}
	if taken, _ := s.UsernameTaken(old); !taken {
		t.Fatal("deleted account's name available during the cooldown")
	}

	// Once the cooldown has passed the name is free, and the sweep drops the row.
	if _, err := s.db.Exec(ctx, `UPDATE released_usernames SET released_at = $1 WHERE name_hash = $2`,
		time.Now().Add(-UsernameReuseCooldown-time.Minute).UnixMilli(), s.releasedNameHash(old)); err != nil {
		t.Fatal(err)
	}
	if taken, _ := s.UsernameTaken(old); taken {
		t.Fatal("name still blocked after the cooldown")
	}
	if err := s.PurgeExpired(); err != nil {
		t.Fatal(err)
	}
	if n := s.countRows(t, `SELECT COUNT(*) FROM released_usernames WHERE name_hash = $1`, s.releasedNameHash(old)); n != 0 {
		t.Fatal("expired cooldown row not purged")
	}
	if err := s.UpdateUsername(bob, old); err != nil {
		t.Fatalf("taking the name after the cooldown: %v", err)
	}
}
