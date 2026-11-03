package store

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"testing"
	"time"

	"github.com/relayapp/relay-server/internal/kt"
)

// A published epoch survives a restart: the restored directory matches the
// stored head and still proves the account's keys.
func TestKTSaveAndRestore(t *testing.T) {
	s := openTestStore(t)
	account, _, err := s.CreateAccount(uniqueName("kt"), nil, "", "device-pw", AccountPassword{})
	if err != nil {
		t.Fatal(err)
	}
	identity := []byte("identity-key-" + account)
	if err := s.SetKeys(account, 1, 7, identity,
		SignedPreKey{KeyID: 1, PublicKey: []byte("spk"), Signature: []byte("sig")},
		SignedPreKey{KeyID: 1, PublicKey: []byte("kyber"), Signature: []byte("ksig")}, nil, false); err != nil {
		t.Fatal(err)
	}
	current, err := s.KTCurrentKeys()
	if err != nil || len(current[account]) != 1 || string(current[account][0]) != string(identity) {
		t.Fatalf("current keys: %v %v", err, current[account])
	}

	vrfKey, _ := rsa.GenerateKey(rand.Reader, 2048)
	_, signKey, _ := ed25519.GenerateKey(rand.Reader)
	// Earlier tests may have stored epochs under other keys; start from a clean slate.
	if _, err := s.db.Exec(t.Context(), `DELETE FROM kt_versions`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(t.Context(), `DELETE FROM kt_heads`); err != nil {
		t.Fatal(err)
	}
	d := kt.NewDirectory(vrfKey, signKey)
	if _, err := d.Sync(current); err != nil {
		t.Fatal(err)
	}
	head, isNew, err := d.Publish(time.Now(), s.KTSaveEpoch)
	if err != nil || !isNew {
		t.Fatalf("publish: %v", err)
	}

	histories, heads, err := s.KTLoad()
	if err != nil || len(heads) != 1 || heads[0].SMTRoot != head.SMTRoot {
		t.Fatalf("load: %v", err)
	}
	restored := kt.NewDirectory(vrfKey, signKey)
	for a, v := range histories {
		restored.Restore(a, v)
	}
	restored.RestoreLog(heads)
	if err := restored.CheckRestored(); err != nil {
		t.Fatalf("restored tree doesn't match: %v", err)
	}
	r, err := restored.Lookup(account)
	if err != nil {
		t.Fatal(err)
	}
	vrfPub, signPub := restored.PublicKeys()
	if err := kt.VerifyLookup(vrfPub, signPub, account, identity, r); err != nil {
		t.Fatalf("lookup after restore: %v", err)
	}
	// Nothing changed: no new epoch.
	if _, isNew, _ := restored.Publish(time.Now(), s.KTSaveEpoch); isNew {
		t.Fatal("idle epoch after restore")
	}
}
